#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extraer.py  —  Jala la base del celular, la FUSIONA con el historico local
               y genera transacciones.csv
Uso normal:  py extraer.py

El historico vive en Visualizador\\_phone.db (master local). Lo que trae el
celular se agrega por hash (dedup); cambiar de celular o borrar la app ya NO
pierde lo acumulado. Antes de cada fusion se guarda un backup fechado en
Visualizador\\backups\\.
"""
import csv, json, os, shutil, sqlite3, subprocess, sys, time
import urllib.request

BASE      = os.path.dirname(os.path.abspath(__file__))
VIS       = os.path.join(BASE, "Visualizador")
MASTER_DB = os.path.join(VIS, "_phone.db")          # historico acumulado (master)
PULL_DB   = os.path.join(VIS, "_phone_pull.tmp.db") # copia cruda recien jalada
CSV_PATH  = os.path.join(VIS, "transacciones.csv")
BACKUPS   = os.path.join(VIS, "backups")
NUBE_CFG  = os.path.join(VIS, "supabase_config.json")
PKG       = "com.cesar.capturador"

SCHEMA_TRANSACCIONES = """CREATE TABLE IF NOT EXISTS transacciones (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hash TEXT UNIQUE,
    fecha TEXT, remitente TEXT, banco TEXT,
    monto REAL, monto_txt TEXT, comercio TEXT, contraparte TEXT,
    es_transaccion INTEGER, parseo_ok INTEGER,
    texto TEXT, fuente TEXT, tipo TEXT,
    capturado_en TEXT, sync_state TEXT DEFAULT 'pending'
)"""


# ──────────────────────────────────────────────────────────── buscar adb ──
def find_adb():
    for c in [
        os.path.join(BASE, "tools", "adb.exe"),
        os.path.expandvars(r"%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"),
    ]:
        if os.path.exists(c):
            return os.path.abspath(c)
    return "adb"   # ultimo recurso: PATH del sistema

ADB = find_adb()


# ──────────────────────────────────────────────────────── verificar cel ──
def check_device():
    """Devuelve True si hay exactamente un dispositivo listo.
    Si no, imprime la causa en español y devuelve False."""
    try:
        r = subprocess.run([ADB, "devices"], capture_output=True, text=True, timeout=8)
    except FileNotFoundError:
        print("ERROR: no se encontro adb.exe en tools\\ ni en el PATH.")
        return False
    except subprocess.TimeoutExpired:
        print("ERROR: adb no respondio (timeout). Reconecta el USB e intenta de nuevo.")
        return False

    # Filtrar encabezado
    lineas = [l for l in r.stdout.strip().splitlines()
              if l.strip() and not l.startswith("List")]

    if not lineas:
        print("PROBLEMA: No hay ningun dispositivo conectado.")
        print("   -> Conecta el celular por USB.")
        print("   -> Verifica que 'Depuracion USB' este activada en")
        print("      Ajustes > Opciones de desarrollador.")
        return False

    unauthorized = [l for l in lineas if "unauthorized" in l]
    offline      = [l for l in lineas if "offline"      in l]
    listos       = [l for l in lineas
                    if "device" in l
                    and "unauthorized" not in l
                    and "offline" not in l]

    if unauthorized:
        print("PROBLEMA: El celular esta conectado pero NO ha autorizado la conexion.")
        print()
        print("   QUE HACER:")
        print("   1) Mira la pantalla del celular ahora mismo.")
        print("      Debe aparecer un aviso: 'Permitir depuracion USB?'")
        print("   2) Toca ACEPTAR (o 'Permitir siempre' para no volver a pedirlo).")
        print("   3) Si no aparecio el aviso:")
        print("      - Desconecta el USB y vuelve a conectarlo.")
        print("      - Desbloquea la pantalla del celular antes de conectar.")
        print("   4) Vuelve a correr este script.")
        return False

    if offline:
        print("PROBLEMA: El celular aparece como 'offline' en ADB.")
        print("   -> Desconecta y vuelve a conectar el USB.")
        print("   -> Si sigue igual, reinicia el celular.")
        return False

    if not listos:
        print("PROBLEMA: No se detecto ningun celular listo.")
        print("   -> Verifica que Depuracion USB este activa.")
        print("   -> Desconecta y reconecta el USB.")
        return False

    serie = listos[0].split()[0]
    print("OK: Celular detectado ->", serie)
    return True


# ──────────────────────────────────────────────────────── jalar la DB ──
def pull_phone_db():
    """Copia la BD del celular a PULL_DB (archivo temporal, NO toca el master).
    Devuelve True si quedo un SQLite valido."""
    print("   Copiando base de datos del celular...")
    with open(PULL_DB, "wb") as out:
        r = subprocess.run(
            [ADB, "exec-out", "run-as", PKG, "cat",
             f"/data/data/{PKG}/databases/capturador.db"],
            stdout=out, stderr=subprocess.PIPE, timeout=30,
        )

    err = r.stderr.decode("utf-8", errors="replace").strip()

    if r.returncode != 0 or os.path.getsize(PULL_DB) < 200:
        if "not installed" in err or "Unknown package" in err:
            print("PROBLEMA: La app Capturador no esta instalada en el celular.")
            print("   -> Instala el APK que esta en  APK\\capturador-debug.apk")
            print("      (conecta el celular, abre una terminal en tools\\ y corre:")
            print("       adb install -r ..\\APK\\capturador-debug.apk )")
        elif "run-as" in err or "not debuggable" in err:
            print("PROBLEMA: No se pudo leer la base de datos.")
            print("   -> Solo funciona con el APK de depuracion (capturador-debug.apk).")
            print("   -> Reinstala desde  APK\\capturador-debug.apk")
        elif os.path.getsize(PULL_DB) < 200:
            print("PROBLEMA: La base descargada esta vacia.")
            print("   -> Abre la app Capturador en el celular.")
            print("   -> Toca el boton 3 (Escanear SMS existentes) para llenarla.")
            print("   -> Luego vuelve a correr este script.")
        else:
            print("PROBLEMA al descargar la base:", err or "(sin detalle)")
        return False

    # Validar que sea SQLite legible antes de fusionar
    try:
        con = sqlite3.connect(PULL_DB)
        con.execute("SELECT COUNT(*) FROM transacciones").fetchone()
        con.close()
    except sqlite3.DatabaseError as e:
        print("PROBLEMA: La base descargada esta corrupta:", e)
        print("   -> Desconecta y reconecta el USB e intenta de nuevo.")
        return False
    return True


# ─────────────────────────────────────────────── fusionar con historico ──
def merge_into_master():
    """Agrega al master las filas nuevas del pull (dedup por hash).
    NUNCA borra ni modifica lo que ya esta en el master: cambiar de celular
    (BD vacia o distinta) solo puede AGREGAR. Devuelve (nuevas, total)."""
    if not os.path.exists(MASTER_DB):
        # Primera vez: el pull ES el historico inicial.
        shutil.copyfile(PULL_DB, MASTER_DB)
        con = sqlite3.connect(MASTER_DB)
        total = con.execute("SELECT COUNT(*) FROM transacciones").fetchone()[0]
        con.close()
        print(f"   Historico local creado con {total} filas del celular.")
        return total, total

    # Backup fechado del master antes de tocarlo
    os.makedirs(BACKUPS, exist_ok=True)
    stamp = time.strftime("%Y%m%d_%H%M%S")
    shutil.copyfile(MASTER_DB, os.path.join(BACKUPS, f"capturador_{stamp}.db"))

    con = sqlite3.connect(MASTER_DB)
    try:
        antes = con.execute("SELECT COUNT(*) FROM transacciones").fetchone()[0]
        con.execute("ATTACH DATABASE ? AS pull", (PULL_DB,))
        # Todas las columnas menos id (autoincrement local); hash UNIQUE deduplica.
        con.execute(
            "INSERT OR IGNORE INTO transacciones "
            "(hash,fecha,remitente,banco,monto,monto_txt,comercio,contraparte,"
            " es_transaccion,parseo_ok,texto,fuente,tipo,capturado_en,sync_state) "
            "SELECT hash,fecha,remitente,banco,monto,monto_txt,comercio,contraparte,"
            " es_transaccion,parseo_ok,texto,fuente,tipo,capturado_en,sync_state "
            "FROM pull.transacciones"
        )
        con.commit()
        total = con.execute("SELECT COUNT(*) FROM transacciones").fetchone()[0]
    finally:
        con.close()

    nuevas = total - antes
    print(f"   Fusionado: {nuevas} filas nuevas del celular (historico: {total}).")
    return nuevas, total


# ──────────────────────────────────────────────── bajar de la nube ──
def config_nube():
    """Devuelve (url, service_key) o None si no esta configurado."""
    if not os.path.exists(NUBE_CFG):
        return None
    try:
        with open(NUBE_CFG, encoding="utf-8") as f:
            cfg = json.load(f)
        url, key = cfg.get("url", ""), cfg.get("service_key", "")
        if not url or not key or key.startswith("PEGA_"):
            return None
        return url.rstrip("/"), key
    except Exception:
        return None


def pull_from_cloud():
    """Baja TODO lo que el capturador subio a Supabase y lo fusiona al
    historico local (dedup por hash, nunca borra). Devuelve (nuevas, total).
    Lanza excepcion con mensaje claro si falla la red o la config."""
    cn = config_nube()
    if cn is None:
        raise RuntimeError(
            "falta la service key: pega la key en "
            "Visualizador\\supabase_config.json (Supabase > Settings > API)")
    url, key = cn

    # Paginado de a 1000 (limite por request de PostgREST)
    filas, offset = [], 0
    while True:
        req = urllib.request.Request(
            f"{url}/rest/v1/gastos_transacciones"
            f"?select=hash,fecha,remitente,banco,monto,monto_txt,comercio,"
            f"contraparte,es_transaccion,parseo_ok,texto,fuente,tipo,capturado_en"
            f"&order=hash&offset={offset}&limit=1000",
            headers={"apikey": key, "Authorization": f"Bearer {key}"},
        )
        with urllib.request.urlopen(req, timeout=30) as r:
            lote = json.load(r)
        filas.extend(lote)
        if len(lote) < 1000:
            break
        offset += 1000

    # Master: crear si no existe; backup fechado si existe
    if os.path.exists(MASTER_DB):
        os.makedirs(BACKUPS, exist_ok=True)
        stamp = time.strftime("%Y%m%d_%H%M%S")
        shutil.copyfile(MASTER_DB, os.path.join(BACKUPS, f"capturador_{stamp}.db"))

    con = sqlite3.connect(MASTER_DB)
    try:
        con.execute(SCHEMA_TRANSACCIONES)
        antes = con.execute("SELECT COUNT(*) FROM transacciones").fetchone()[0]
        con.executemany(
            "INSERT OR IGNORE INTO transacciones "
            "(hash,fecha,remitente,banco,monto,monto_txt,comercio,contraparte,"
            " es_transaccion,parseo_ok,texto,fuente,tipo,capturado_en,sync_state) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,'synced')",
            [(f["hash"], f["fecha"], f["remitente"], f["banco"], f["monto"],
              f["monto_txt"], f["comercio"], f["contraparte"], f["es_transaccion"],
              f["parseo_ok"], f["texto"], f["fuente"], f["tipo"], f["capturado_en"])
             for f in filas],
        )
        con.commit()
        total = con.execute("SELECT COUNT(*) FROM transacciones").fetchone()[0]
    finally:
        con.close()

    nuevas = total - antes
    print(f"   Nube: {len(filas)} filas bajadas, {nuevas} nuevas (historico: {total}).")
    return nuevas, total


# ──────────────────────────────────────────────────────── generar CSV ──
def generar_csv():
    """Regenera transacciones.csv desde el master con filtros de saneo."""
    print("   Convirtiendo a CSV...")
    cols = ["fecha", "banco", "tipo", "monto", "monto_txt", "comercio",
            "contraparte", "parseo_ok", "fuente", "remitente", "mensaje"]
    # Filtros de saneo sobre datos YA capturados por versiones viejas del APK
    # (el APK nuevo no deja entrar nada de esto, pero el historico local
    # lo conserva crudo):
    #  1. PUSH solo de apps bancarias — el listener viejo aceptaba cualquier
    #     app: entraron 105 publicidades de Tabot via WhatsApp como egresos
    #     de $2.8M c/u ($294M falsos, 93% del gasto total).
    #  2. Marketing de los bancos (credito preaprobado, ofertas, promos).
    #  3. Pagos fallidos ("faltan fondos") no son egresos.
    #  4. "Pagaste tu tarjeta de credito Nu" es movimiento entre cuentas
    #     propias, no un ingreso (marcado por Cesar en parse_feedback.json).
    PUSH_BANCARIO = ("nequi", "nu.production", "nubank", "bancolombia",
                     "davivienda", "daviplata")
    push_ok = " OR ".join(f"lower(remitente) LIKE '%{p}%'" for p in PUSH_BANCARIO)
    MARKETING = ("cupo", "preaprobado", "aprovecha", "soy tabot",
                 "apuesta", "promo", "tienda virtual", "instagram",
                 "credito a la mano", "crédito a la mano", "te ofrecemos")
    no_mkt = " AND ".join(f"lower(texto) NOT LIKE '%{k}%'" for k in MARKETING)
    con = sqlite3.connect(MASTER_DB)
    try:
        data = con.execute(
            "SELECT fecha,banco,tipo,monto,monto_txt,comercio,contraparte,"
            "parseo_ok,fuente,remitente,texto "
            "FROM transacciones WHERE es_transaccion=1 "
            f"AND (fuente != 'PUSH' OR ({push_ok})) "
            f"AND {no_mkt} "
            "AND lower(texto) NOT LIKE '%faltan fondos%' "
            "AND lower(texto) NOT LIKE '%pagaste tu tarjeta%' "
            "ORDER BY fecha DESC, id DESC"
        ).fetchall()
    finally:
        con.close()

    # Escritura atomica: que el visualizador nunca lea un CSV a medias.
    tmp = CSV_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        w.writerows(data)
    os.replace(tmp, CSV_PATH)

    print(f"OK: {len(data)} transacciones guardadas en Visualizador\\transacciones.csv")
    return len(data)


def extract():
    ok = pull_phone_db()
    try:
        if ok:
            merge_into_master()
    finally:
        if os.path.exists(PULL_DB):
            os.remove(PULL_DB)
    if not ok:
        # Sin celular no hay fusion, pero el historico local sigue intacto.
        if os.path.exists(MASTER_DB):
            print("   (El historico local NO se toco; el CSV se regenera igual.)")
            generar_csv()
        return False
    generar_csv()
    return True


# ──────────────────────────────────────────────────────────────── main ──
def main():
    sep = "-" * 52
    print(sep)
    print("  Extractor — Gastos y Transacciones")
    print(sep)

    # Modo: "nube" (Supabase, sin cable) o "cable" (adb, el de siempre).
    # Sin argumento: nube si hay service key configurada, cable si no.
    #   py extraer.py            -> automatico
    #   py extraer.py nube       -> forzar nube
    #   py extraer.py cable      -> forzar cable/adb
    modo = sys.argv[1].lower() if len(sys.argv) > 1 else None
    if modo not in ("nube", "cable", None):
        print(f"Modo desconocido: {modo}. Usa 'nube' o 'cable'.")
        return
    if modo is None:
        modo = "nube" if config_nube() else "cable"

    print(f"  Modo: {modo}")
    if modo == "nube":
        try:
            pull_from_cloud()
            generar_csv()
            ok = True
        except Exception as e:
            print("PROBLEMA bajando de la nube:", e)
            ok = False
    else:
        ok = check_device() and extract()

    print(sep)
    if ok:
        print("Listo. Ahora abre el Visualizador (doble clic en ABRIR.bat")
        print("o:  py Visualizador\\app.py ) para ver los datos actualizados.")
    else:
        print("No se pudo extraer. Lee el PROBLEMA de arriba, corrigelo")
        print("y vuelve a correr este script (o el archivo extraer.bat).")
    print(sep)


if __name__ == "__main__":
    main()
