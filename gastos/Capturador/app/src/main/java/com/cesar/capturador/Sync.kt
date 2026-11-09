package com.cesar.capturador

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Sube las filas pendientes (sync_state='pending') a Supabase por REST.
 * Sin dependencias: HttpURLConnection + org.json (ambos vienen en Android).
 *
 * La ANON_KEY es la key PUBLICA del proyecto: por RLS solo puede INSERTAR en
 * gastos_transacciones (no puede leer, modificar ni tocar otras tablas), asi
 * que no pasa nada si alguien descompila el APK. Leer los datos solo se puede
 * con la service key, que vive unicamente en el PC (visualizador).
 *
 * Dedup: la tabla tiene PRIMARY KEY (hash). No se usa ON CONFLICT (upsert):
 * RLS lo rechaza porque resolver el conflicto exige LEER la fila existente y
 * esta key no puede leer (verificado contra Supabase real: 42501). En cambio,
 * el POST plano de un duplicado devuelve 409 (23505), y ese 409 se trata como
 * "ya estaba subida" -> reintentos, reinstalar la app o cambiar de celular
 * nunca duplican ni fallan.
 */
object Sync {

    private const val SUPABASE_URL = "https://TU-PROYECTO.supabase.co"
    private const val ANON_KEY = "PEGA_TU_PUBLISHABLE_KEY"
    private const val TABLA = "gastos_transacciones"
    private const val LOTE = 100

    @Volatile private var corriendo = false

    val configurada: Boolean get() = !ANON_KEY.startsWith("PEGA_")

    /**
     * Dispara la subida en background y se traga los errores (sin red, timeout):
     * lo que no suba queda 'pending' y se reintenta en la proxima captura o al
     * abrir la app. Para llamar desde SmsReceiver/NotiListener/onCreate.
     */
    fun intentarAsync(ctx: Context) {
        if (!configurada || corriendo) return
        val app = ctx.applicationContext
        Thread {
            try {
                subirPendientes(app)
            } catch (_: Exception) {
                // sin red o servidor caido: las filas siguen 'pending'
            }
        }.start()
    }

    /**
     * Sube TODO lo pendiente en lotes. Devuelve (subidas, quedanPendientes).
     * Lanza excepcion si falla la red o Supabase responde error.
     */
    fun subirPendientes(ctx: Context): Pair<Int, Int> {
        if (!configurada) return 0 to Db(ctx).contarPendientes()
        if (corriendo) return 0 to Db(ctx).contarPendientes()
        corriendo = true
        try {
            val db = Db(ctx)
            var subidas = 0
            while (true) {
                val lote = db.pendientes(LOTE)
                if (lote.isEmpty()) break
                postLote(lote)
                db.marcarSynced(lote.map { it.hash })
                subidas += lote.size
            }
            return subidas to db.contarPendientes()
        } finally {
            corriendo = false
        }
    }

    /**
     * Sube un lote. Camino feliz: un solo POST con todas las filas (201).
     * Si alguna ya existe, el lote entero da 409 (el POST es atomico) ->
     * se reenvia fila por fila y el 409 individual cuenta como subida.
     */
    private fun postLote(filas: List<Db.FilaSync>) {
        val code = post(aJson(filas))
        if (code in 200..299) return
        // post() solo devuelve 2xx o 409; cualquier otro codigo lanza excepcion.
        for (f in filas) {
            val c = post(aJson(listOf(f)))
            if (c !in 200..299 && c != 409)
                throw RuntimeException("Supabase respondio $c subiendo ${f.hash}")
        }
    }

    private fun aJson(filas: List<Db.FilaSync>): String {
        val body = JSONArray()
        for (f in filas) {
            body.put(JSONObject().apply {
                put("hash", f.hash)
                put("fecha", f.fecha)
                put("remitente", f.remitente)
                put("banco", f.banco)
                if (f.monto != null) put("monto", f.monto) else put("monto", JSONObject.NULL)
                put("monto_txt", f.montoTxt ?: JSONObject.NULL)
                put("comercio", f.comercio ?: JSONObject.NULL)
                put("contraparte", f.contraparte ?: JSONObject.NULL)
                put("es_transaccion", f.esTransaccion)
                put("parseo_ok", f.parseoOk)
                put("texto", f.texto)
                put("fuente", f.fuente)
                put("tipo", f.tipo)
                put("capturado_en", f.capturadoEn ?: JSONObject.NULL)
            })
        }
        return body.toString()
    }

    /** POST crudo. Devuelve el codigo HTTP; 409 (duplicado) se devuelve tal
     *  cual para que el caller lo trate como dedup. Otros errores lanzan. */
    private fun post(json: String): Int {
        val con = URL("$SUPABASE_URL/rest/v1/$TABLA")
            .openConnection() as HttpURLConnection
        try {
            con.requestMethod = "POST"
            con.connectTimeout = 15000
            con.readTimeout = 15000
            con.doOutput = true
            con.setRequestProperty("apikey", ANON_KEY)
            con.setRequestProperty("Authorization", "Bearer $ANON_KEY")
            con.setRequestProperty("Content-Type", "application/json")
            con.setRequestProperty("Prefer", "return=minimal")
            con.outputStream.use { it.write(json.toByteArray(Charsets.UTF_8)) }

            val code = con.responseCode
            if (code !in 200..299 && code != 409) {
                val err = con.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
                throw RuntimeException("Supabase respondio $code: ${err.take(200)}")
            }
            return code
        } finally {
            con.disconnect()
        }
    }
}
