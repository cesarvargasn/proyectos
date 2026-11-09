#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Visualizador de transacciones del Capturador — v2
- Corre local: http://localhost:8000
- Lee transacciones.csv (el que exporta la app del telefono).
- Etiquetas por CONTRAPARTE (labels.json): se auto-aplican a todas las
  transacciones de esa contraparte, incluidas las futuras.
- NUEVO: overrides por TRANSACCION individual (transaction_overrides.json):
  categoria propia + nota libre, sin tocar las demas del mismo comercio.
- NUEVO: presupuestos mensuales por categoria + fecha de ultima actualizacion
  (viven en config.json).
- Boton "Actualizar desde telefono": jala la base por adb (via extraer.py) y
  la FUSIONA con el historico local _phone.db (dedup por hash — cambiar de
  celular no borra nada); luego regenera el CSV. Los .json NO se tocan al
  actualizar: etiquetas, overrides, notas y presupuestos sobreviven.

Archivos de datos (todos junto a app.py):
  transacciones.csv          <- export del historico local (se REGENERA)
  _phone.db                  <- HISTORICO ACUMULADO (master, NO borrar)
  labels.json                <- {contraparte: etiqueta}            (persistente)
  transaction_overrides.json <- {tx_id: {"categoria": "...", "nota": "...",
                                "transferencia": true}} cualquier llave puede
                                faltar; transferencia=true marca ESA sola
                                transaccion como plata entre mis cuentas
                                                                    (persistente)
  config.json                <- {"categorias_transferencia": [...],
                                 "presupuestos": {"Comida": 250000},
                                 "ultima_actualizacion": "YYYY-MM-DD HH:MM"}
                                                                    (persistente)
  parse_feedback.json        <- {tx_id: {"motivo": "...", "tx": {...mensaje
                                completo...}}} reportes de parseo malo, para
                                mejorar el Parser del capturador (persistente)

ID de transaccion (acordado entre backend y frontend; solo lo calcula el
backend y viaja en /api/data):
  sha1( fecha[:16] + "|" + banco + "|" + str(round(monto)) + "|" +
        (contraparte o comercio).lower() )[:16]
Es el mismo tuple del dedup, asi que es estable entre refresh mientras la
fila exista en el CSV.

Solo libreria estandar de Python. No instala nada.
    py app.py            -> arranca el servidor
    py app.py refresh    -> solo jala el CSV del telefono y termina
"""
import csv
import hashlib
import json
import os
import sqlite3

import sys
import threading
import webbrowser
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))
CSV_PATH = os.path.join(BASE, "transacciones.csv")
LABELS_PATH = os.path.join(BASE, "labels.json")
CONFIG_PATH = os.path.join(BASE, "config.json")
OVERRIDES_PATH = os.path.join(BASE, "transaction_overrides.json")
DELETED_PATH = os.path.join(BASE, "deleted_transactions.json")
FEEDBACK_PATH = os.path.join(BASE, "parse_feedback.json")
PHONE_DB = os.path.join(BASE, "_phone.db")
INDEX = os.path.join(BASE, "index.html")

PORT = 8000

# Hosts y origenes aceptados: SOLO el propio visualizador. Aunque el servidor
# escucha en 127.0.0.1, una pagina web maliciosa abierta en el navegador puede
# mandar requests a http://localhost:8000 (CSRF: borrar/alterar datos, disparar
# adb) o leer /api/data via DNS rebinding (un dominio del atacante que resuelve
# a 127.0.0.1 y pasa el mismo-origen del navegador). Validar Host y Origin
# cierra los dos caminos sin afectar el uso normal.
ALLOWED_HOSTS = {
    "localhost:%d" % PORT, "127.0.0.1:%d" % PORT,
    "localhost", "127.0.0.1",
}
ALLOWED_ORIGINS = {
    "http://localhost:%d" % PORT, "http://127.0.0.1:%d" % PORT,
}


def find_index():
    """Devuelve la ruta de index.html. Lo busca primero junto a app.py y, si
    no esta ahi, en la carpeta desde donde se ejecuto el comando. Asi no
    importa desde donde lances `py app.py`."""
    for cand in (INDEX, os.path.join(os.getcwd(), "index.html")):
        if os.path.exists(cand):
            return cand
    return None

# Protege las escrituras a los .json (el servidor es multihilo).
LOCK = threading.Lock()


# ---------------------------------------------------------------- json helpers
def _load_json(path, default):
    """Lee un json del disco; si no existe, esta corrupto o no es del tipo
    esperado, devuelve el default sin reventar nada."""
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, type(default)):
                return data
        except Exception:
            pass
    return default


def _save_json(path, data):
    """Escritura atomica (tmp + replace): si algo se cae a mitad de camino,
    el archivo original queda intacto. Importa para no perder etiquetas/notas."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


# ---------------------------------------------------------------- labels
def load_labels():
    return _load_json(LABELS_PATH, {})


def save_labels(d):
    _save_json(LABELS_PATH, d)


# ---------------------------------------------------------------- overrides
# Overrides por transaccion individual. Llave = tx_id (ver tx_id() abajo).
# Valor = {"categoria": "...", "nota": "...", "transferencia": true};
# cualquiera puede faltar. "transferencia" marca ESA transaccion como plata
# entre mis propias cuentas sin depender de etiquetas (util cuando no hay
# contraparte ni comercio y el panel de recurrentes no la muestra).
# Si todo queda vacio, la entrada se borra. Nunca se podan entradas
# huerfanas automaticamente: si el CSV se regenera raro un dia, las notas
# no se pierden.
def load_overrides():
    return _load_json(OVERRIDES_PATH, {})


def save_overrides(d):
    _save_json(OVERRIDES_PATH, d)


# ------------------------------------------------------ transacciones borradas
# Lista de tx_id que el usuario marco como "no son transacciones reales"
# (notificaciones de verificacion, duplicados, devoluciones mal clasificadas).
# Se filtran al construir los datos y SOBREVIVEN a "Actualizar desde telefono"
# (que regenera el CSV). Borrar aqui no toca el CSV ni la base del telefono:
# solo las oculta, asi que siempre se pueden restaurar.
def load_deleted():
    d = _load_json(DELETED_PATH, [])
    return set(d) if isinstance(d, list) else set()


def save_deleted(s):
    _save_json(DELETED_PATH, sorted(s))


# ------------------------------------------------------- reportes de parseo
# Transacciones que el usuario marco como MAL PARSEADAS (promos que entraron
# como transaccion, monto/comercio/tipo mal extraidos). Se guarda el mensaje
# COMPLETO + motivo, asi despues se puede mejorar el Parser del capturador
# con casos reales. {tx_id: {"motivo": "...", "fecha_reporte": "...",
# "tx": {fecha, banco, tipo, monto, comercio, contraparte, fuente,
#        remitente, mensaje, parseo_ok}}}
def load_feedback():
    return _load_json(FEEDBACK_PATH, {})


def save_feedback(d):
    _save_json(FEEDBACK_PATH, d)


# ---------------------------------------------------------------- config
# - categorias_transferencia: etiquetas que representan movimientos entre mis
#   propias cuentas (pasarme plata de Bancolombia a Nubank, etc.). Eso NO es
#   egreso ni ingreso: es la misma plata cambiando de bolsillo. Se reclasifica
#   como "transferencia".
# - presupuestos: tope mensual por categoria, en COP. {"Comida": 250000}
# - ultima_actualizacion: cuando se jalo el telefono por ultima vez.
DEFAULT_CONFIG = {
    "categorias_transferencia": ["Yo mismo"],
    "presupuestos": {},
    "ultima_actualizacion": "",
}


def load_config():
    cfg = {
        "categorias_transferencia": list(DEFAULT_CONFIG["categorias_transferencia"]),
        "presupuestos": {},
        "ultima_actualizacion": "",
    }
    disco = _load_json(CONFIG_PATH, {})
    if isinstance(disco.get("categorias_transferencia"), list):
        cfg["categorias_transferencia"] = [str(c) for c in disco["categorias_transferencia"]]
    if isinstance(disco.get("presupuestos"), dict):
        for k, v in disco["presupuestos"].items():
            try:
                v = float(v)
            except (TypeError, ValueError):
                continue
            if v > 0:
                cfg["presupuestos"][str(k)] = v
    if isinstance(disco.get("ultima_actualizacion"), str):
        cfg["ultima_actualizacion"] = disco["ultima_actualizacion"]
    return cfg


def save_config(cfg):
    _save_json(CONFIG_PATH, cfg)


def stamp_update(cfg=None):
    """Anota en config.json la hora en que se jalaron los datos del telefono."""
    with LOCK:
        cfg = cfg or load_config()
        cfg["ultima_actualizacion"] = datetime.now().strftime("%Y-%m-%d %H:%M")
        save_config(cfg)
    return cfg["ultima_actualizacion"]


# ---------------------------------------------------------------- csv / db
def read_csv():
    rows = []
    if not os.path.exists(CSV_PATH):
        return rows
    with open(CSV_PATH, encoding="utf-8", newline="") as f:
        for r in csv.DictReader(f):
            rows.append(r)
    return rows


def _extraer():
    sys.path.insert(0, os.path.dirname(BASE))
    import extraer
    return extraer


def db_to_csv():
    """Actualiza los datos y regenera transacciones.csv. Toda la logica vive
    en extraer.py (aqui solo se reusa):
    - Si hay service key en supabase_config.json: baja de la NUBE (lo que el
      capturador subio solo) y lo fusiona al historico local. Sin cable.
    - Si no: cable/adb como siempre.
    En ambos casos la fusion es por hash sobre _phone.db (historico master):
    nada se borra nunca. Devuelve (n_transacciones_csv, modo)."""
    extraer = _extraer()
    if extraer.config_nube():
        extraer.pull_from_cloud()
        return extraer.generar_csv(), "nube"
    if not extraer.pull_phone_db():
        # pull_phone_db ya imprimio la causa detallada en la consola.
        raise RuntimeError(
            "no se pudo leer la base del celular "
            "(revisa cable/depuracion USB y que la APK debug este instalada)")
    try:
        extraer.merge_into_master()
    finally:
        if os.path.exists(extraer.PULL_DB):
            os.remove(extraer.PULL_DB)
    return extraer.generar_csv(), "cable"


def _score(it):
    # al deduplicar preferimos la fila con comercio y, si empata, la de SMS
    # (el texto del SMS es el mensaje canonico completo).
    return (1 if it["comercio"] else 0, 1 if it["fuente"] == "SMS" else 0)


def tx_id(fecha16, banco, monto_r, quien, occ=0):
    """ID estable de una transaccion (mismo tuple del dedup).
    occ desempata dos movimientos identicos en minuto+monto+quien (p.ej. dos
    compras seguidas sin comercio). occ=0 no se anade al hash para no cambiar
    los IDs de overrides ya guardados."""
    base = "|".join([fecha16, banco, str(monto_r), quien])
    if occ:
        base += "|" + str(occ)
    return hashlib.sha1(base.encode("utf-8")).hexdigest()[:16]


def _fuente_clase(f):
    # normalizamos la fuente a dos clases: 'sms' o 'push'. Solo fusionamos
    # cuando una transaccion la captaron DOS fuentes distintas (SMS + push).
    return "sms" if (f or "").strip().upper() == "SMS" else "push"


def build_data():
    labels = load_labels()
    cfg = load_config()
    overrides = load_overrides()
    deleted = load_deleted()
    feedback = load_feedback()
    transfer = {l.strip().lower() for l in cfg["categorias_transferencia"] if l.strip()}
    slots = {}        # (base, occ) -> item ganador
    srcs = {}         # (base, occ) -> set de fuentes ya absorbidas en ese slot
    activo = {}       # base -> occ del slot que todavia puede recibir el par cruzado
    order = []        # orden de aparicion de los slots finales
    for r in read_csv():
        cp = (r.get("contraparte") or "").strip()
        comercio = (r.get("comercio") or "").strip()
        # "quien" = a quien le pague / quien me pago. Si no hay contraparte
        # (compra con tarjeta, notificacion de Nubank), usamos el comercio.
        # Asi una etiqueta sobre el comercio cobija TODAS sus transacciones.
        quien_raw = cp or comercio
        try:
            monto = float(r.get("monto") or 0)
        except ValueError:
            monto = 0.0
        fecha = r.get("fecha", "") or ""
        try:
            parseo = int(r.get("parseo_ok") or 0)
        except ValueError:
            parseo = 0
        fuente = r.get("fuente", "") or ""
        item = {
            "fecha": fecha,
            "mes": fecha[:7],
            "banco": r.get("banco", "") or "",
            "tipo_base": r.get("tipo", "") or "",
            "monto": monto,
            "comercio": comercio,
            "contraparte": cp,
            "quien": quien_raw,                 # clave de etiquetado / agrupacion
            "label": labels.get(quien_raw, ""), # hereda etiqueta de contraparte O comercio
            "fuente": fuente,
            "remitente": r.get("remitente", "") or "",
            "parseo_ok": parseo,
            "mensaje": r.get("mensaje", "") or "",
        }
        base = (fecha[:16], item["banco"], round(monto), quien_raw.lower())
        clase = _fuente_clase(fuente)
        # Solo colapsamos cuando la MISMA transaccion la captaron dos fuentes
        # distintas (un SMS y una notificacion). Dos filas de la misma fuente
        # = dos movimientos reales aunque coincidan en minuto y monto: NO se
        # fusionan (antes se perdia uno, sobre todo notificaciones sin comercio).
        if base in activo:
            occ = activo[base]
            key = (base, occ)
            if clase not in srcs[key]:
                srcs[key].add(clase)
                if _score(item) > _score(slots[key]):
                    slots[key] = item        # nos quedamos con la fila mas completa
            else:
                occ += 1                      # misma fuente otra vez = otro movimiento
                activo[base] = occ
                key = (base, occ)
                slots[key] = item
                srcs[key] = {clase}
                order.append(key)
        else:
            occ = 0
            activo[base] = 0
            key = (base, occ)
            slots[key] = item
            srcs[key] = {clase}
            order.append(key)

    txs = []
    for key in order:
        base, occ = key
        it = slots[key]
        tid = tx_id(base[0], base[1], base[2], base[3], occ)
        ov = overrides.get(tid) or {}
        it["id"] = tid
        it["override_cat"] = (ov.get("categoria") or "").strip()
        it["nota"] = (ov.get("nota") or "").strip()
        it["override_tra"] = bool(ov.get("transferencia"))
        # Categoria efectiva: el override por transaccion manda; si no hay,
        # hereda la etiqueta de la contraparte/comercio.
        cat = it["override_cat"] or it["label"]
        it["categoria"] = cat
        # Plata que me paso entre mis propias cuentas: ni ingreso ni egreso.
        # Dos caminos: el override individual (checkbox del modal) o la
        # categoria efectiva marcada como transferencia (p.ej. "Yo mismo").
        es_tra = it["override_tra"] or (cat and cat.lower() in transfer)
        it["tipo"] = "transferencia" if es_tra else it["tipo_base"]
        it["deleted"] = tid in deleted
        it["flag"] = (feedback.get(tid) or {}).get("motivo", "")
        txs.append(it)
    return {
        "transactions": txs,
        "labels": labels,
        "config": cfg,
    }


# ---------------------------------------------------------------- http
class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        # nada de cache: que el navegador siempre traiga el index.html y la
        # data frescos (evita ver una version vieja tras actualizar el codigo).
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):  # silencio el log ruidoso
        pass

    def _request_permitido(self):
        """Anti CSRF / DNS rebinding.
        - Host debe ser el propio servidor (un dominio del atacante que
          resuelva a 127.0.0.1 llega con SU Host y se rechaza).
        - Si el navegador manda Origin (los POST cross-site siempre lo
          traen, incluido "null" desde iframes sandbox), debe ser el propio
          servidor. El frontend legitimo es mismo-origen y pasa."""
        host = (self.headers.get("Host") or "").strip().lower()
        if host not in ALLOWED_HOSTS:
            return False
        origin = (self.headers.get("Origin") or "").strip().lower()
        if origin and origin not in ALLOWED_ORIGINS:
            return False
        return True

    def do_GET(self):
        if not self._request_permitido():
            self._send(403, json.dumps({"ok": False, "error": "origen no permitido"}))
            return
        if self.path == "/" or self.path.startswith("/index"):
            idx = find_index()
            if idx:
                with open(idx, "rb") as f:
                    self._send(200, f.read(), "text/html; charset=utf-8")
            else:
                msg = ("No encuentro index.html.\n\n"
                       "app.py lo busco en:\n  %s\ny en:\n  %s\n\n"
                       "Pon index.html en la MISMA carpeta que app.py y reinicia "
                       "el servidor (Ctrl+C y de nuevo: py app.py)."
                       % (INDEX, os.path.join(os.getcwd(), "index.html")))
                self._send(500, msg, "text/plain; charset=utf-8")
        elif self.path == "/api/data":
            self._send(200, json.dumps(build_data(), ensure_ascii=False))
        elif self.path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
        else:
            self._send(404, "{}")

    def do_POST(self):
        if not self._request_permitido():
            self._send(403, json.dumps({"ok": False, "error": "origen no permitido"}))
            return
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw or b"{}")
        except Exception:
            payload = {}

        if self.path == "/api/label":
            # Etiqueta por contraparte (se hereda en todas sus transacciones).
            key = (payload.get("key") or "").strip()
            label = (payload.get("label") or "").strip()
            if key:
                with LOCK:
                    labels = load_labels()
                    if label:
                        labels[key] = label
                    else:
                        labels.pop(key, None)
                    save_labels(labels)
            self._send(200, json.dumps({"ok": True}))

        elif self.path == "/api/override":
            # Categoria propia, nota y/o marca de transferencia de UNA
            # transaccion. Vacio/false = se quita esa llave; si todo queda
            # vacio, la entrada desaparece y la transaccion vuelve a heredar
            # la etiqueta de su contraparte.
            tid = (payload.get("id") or "").strip()
            cat = (payload.get("categoria") or "").strip()
            nota = (payload.get("nota") or "").strip()
            tra = bool(payload.get("transferencia"))
            if tid:
                with LOCK:
                    ov = load_overrides()
                    entry = {}
                    if cat:
                        entry["categoria"] = cat
                    if nota:
                        entry["nota"] = nota
                    if tra:
                        entry["transferencia"] = True
                    if entry:
                        ov[tid] = entry
                    else:
                        ov.pop(tid, None)
                    save_overrides(ov)
            self._send(200, json.dumps({"ok": True}))

        elif self.path == "/api/delete":
            # Borra (oculta) o restaura UNA transaccion por su tx_id. No toca el
            # CSV ni la base del telefono: solo la lista de ocultas, que aguanta
            # el "Actualizar desde telefono".
            tid = (payload.get("id") or "").strip()
            borrar = bool(payload.get("deleted", True))
            if tid:
                with LOCK:
                    s = load_deleted()
                    if borrar:
                        s.add(tid)
                    else:
                        s.discard(tid)
                    save_deleted(s)
            self._send(200, json.dumps({"ok": True}))

        elif self.path == "/api/feedback":
            # Reporta UNA transaccion como mal parseada. Guarda el mensaje
            # completo + motivo en parse_feedback.json (material para mejorar
            # el Parser del capturador). motivo vacio = quitar el reporte.
            # "no_es_transaccion" ademas la manda a la papelera: es basura
            # (promo, cupo preaprobado...) y no debe contar en estadisticas.
            tid = (payload.get("id") or "").strip()
            motivo = (payload.get("motivo") or "").strip()
            if tid:
                with LOCK:
                    fb = load_feedback()
                    if motivo:
                        fb[tid] = {
                            "motivo": motivo,
                            "fecha_reporte": datetime.now().strftime("%Y-%m-%d %H:%M"),
                            "tx": {k: payload.get(k, "") for k in
                                   ("fecha", "banco", "tipo", "monto",
                                    "comercio", "contraparte", "fuente",
                                    "remitente", "mensaje", "parseo_ok")},
                        }
                    else:
                        fb.pop(tid, None)
                    save_feedback(fb)
                    if motivo == "no_es_transaccion":
                        s = load_deleted()
                        s.add(tid)
                        save_deleted(s)
            self._send(200, json.dumps({"ok": True}))

        elif self.path == "/api/budget":
            # Presupuesto mensual por categoria. monto <= 0 o vacio = quitar.
            cat = (payload.get("categoria") or "").strip()
            try:
                monto = float(payload.get("monto") or 0)
            except (TypeError, ValueError):
                monto = 0.0
            if cat:
                with LOCK:
                    cfg = load_config()
                    pres = {k: v for k, v in cfg["presupuestos"].items()
                            if k.lower() != cat.lower()}
                    if monto > 0:
                        pres[cat] = monto
                    cfg["presupuestos"] = pres
                    save_config(cfg)
            self._send(200, json.dumps({"ok": True}))

        elif self.path == "/api/transfer_category":
            # Marca/desmarca una etiqueta como "transferencia entre mis cuentas".
            label = (payload.get("label") or "").strip()
            is_transfer = bool(payload.get("is_transfer"))
            if label:
                with LOCK:
                    cfg = load_config()
                    cats = cfg["categorias_transferencia"]
                    low = {c.lower() for c in cats}
                    if is_transfer and label.lower() not in low:
                        cats.append(label)
                    elif not is_transfer:
                        cats = [c for c in cats if c.lower() != label.lower()]
                    cfg["categorias_transferencia"] = cats
                    save_config(cfg)
            self._send(200, json.dumps({"ok": True}))

        elif self.path == "/api/refresh":
            try:
                n, modo = db_to_csv()
                ts = stamp_update()
                self._send(200, json.dumps({"ok": True, "n": n, "ts": ts, "modo": modo}))
            except Exception as e:
                self._send(200, json.dumps({"ok": False, "error": str(e)}))

        else:
            self._send(404, "{}")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "refresh":
        print("Actualizando datos...")
        try:
            n, modo = db_to_csv()
            stamp_update()
            print("CSV regenerado con %d transacciones (via %s)." % (n, modo))
        except Exception as e:
            print("Error actualizando:", e)
        return
    url = "http://localhost:%d" % PORT
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    except OSError:
        print("No pude abrir el puerto %d. Ya hay otro visualizador corriendo." % PORT)
        print("Cierra esa ventana/servidor (o reinicia el PC) y vuelve a intentar.")
        return
    # diagnostico claro: desde donde corre y si ve el index.html
    print("-" * 60)
    print("Carpeta de app.py : %s" % BASE)
    print("Carpeta actual    : %s" % os.getcwd())
    idx = find_index()
    if idx:
        print("index.html        : OK -> %s" % idx)
    else:
        print("index.html        : NO LO ENCUENTRO")
        print("  Ponlo en la misma carpeta que app.py:")
        print("  %s" % INDEX)
    print("-" * 60)
    print("Visualizador corriendo en %s  (Ctrl+C para parar)" % url)
    try:
        webbrowser.open(url)
    except Exception:
        pass
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nChao.")


if __name__ == "__main__":
    main()
