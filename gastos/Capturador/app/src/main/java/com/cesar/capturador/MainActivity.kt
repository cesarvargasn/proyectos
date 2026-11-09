package com.cesar.capturador

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.os.Bundle
import android.provider.Settings
import android.provider.Telephony
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** UI mínima: app de paso. Ver que captura + exportar CSV. */
class MainActivity : Activity() {

    private lateinit var status: TextView
    private lateinit var resultados: TextView
    private val reqSms = 100

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(40, 56, 40, 56)
        }
        setContentView(ScrollView(this).apply { addView(root) })

        val titulo = TextView(this).apply {
            text = "Capturador de transacciones"
            textSize = 22f
            setPadding(0, 0, 0, 24)
        }
        status = TextView(this).apply { textSize = 14f; setPadding(0, 0, 0, 24) }
        resultados = TextView(this).apply {
            textSize = 12f
            typeface = Typeface.MONOSPACE
        }

        fun boton(t: String, f: () -> Unit) = Button(this).apply {
            text = t
            setOnClickListener { f() }
        }

        root.addView(titulo)
        root.addView(status)
        root.addView(boton("1. Permitir leer SMS") { pedirSms() })
        root.addView(boton("2. Activar acceso a notificaciones") { abrirAccesoNotis() })
        root.addView(boton("3. Escanear SMS existentes") { escanearInbox() })
        root.addView(boton("Subir a la nube ahora") { subirNube() })
        root.addView(boton("Exportar CSV") { exportarCsv() })
        root.addView(boton("Refrescar") { refrescar() })
        root.addView(TextView(this).apply {
            text = "\nÚltimas capturas:\n"; textSize = 15f
        })
        root.addView(resultados)

        refrescar()
        // Al abrir la app se intenta subir lo pendiente (silencioso, sin bloquear).
        Sync.intentarAsync(this)
    }

    /** Subida manual con resultado visible. */
    private fun subirNube() {
        if (!Sync.configurada) {
            Toast.makeText(this, "Falta la ANON_KEY en Sync.kt (recompilar)", Toast.LENGTH_LONG).show()
            return
        }
        Toast.makeText(this, "Subiendo...", Toast.LENGTH_SHORT).show()
        Thread {
            val msg = try {
                val (subidas, quedan) = Sync.subirPendientes(this)
                if (quedan == 0) "Nube al dia: $subidas subidas"
                else "Subidas $subidas, quedan $quedan pendientes"
            } catch (e: Exception) {
                "No se pudo subir (¿hay internet?): ${e.message?.take(120)}"
            }
            runOnUiThread {
                Toast.makeText(this, msg, Toast.LENGTH_LONG).show()
                refrescar()
            }
        }.start()
    }

    private fun tieneSms() =
        checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED &&
            checkSelfPermission(Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED

    private fun pedirSms() =
        requestPermissions(
            arrayOf(Manifest.permission.READ_SMS, Manifest.permission.RECEIVE_SMS), reqSms
        )

    override fun onRequestPermissionsResult(
        rc: Int, p: Array<out String>, r: IntArray
    ) {
        super.onRequestPermissionsResult(rc, p, r)
        if (rc == reqSms) {
            refrescar()
            if (tieneSms()) escanearInbox()
        }
    }

    private fun abrirAccesoNotis() {
        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        Toast.makeText(this, "Activa 'Capturador' en la lista", Toast.LENGTH_LONG).show()
    }

    private fun escanearInbox() {
        if (!tieneSms()) {
            Toast.makeText(this, "Primero da permiso de SMS (botón 1)", Toast.LENGTH_LONG).show()
            return
        }
        var nuevos = 0
        val cols = arrayOf(Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE)
        contentResolver.query(
            Telephony.Sms.Inbox.CONTENT_URI, cols, null, null,
            Telephony.Sms.DATE + " DESC"
        )?.use { c ->
            val iA = c.getColumnIndex(Telephony.Sms.ADDRESS)
            val iB = c.getColumnIndex(Telephony.Sms.BODY)
            val iD = c.getColumnIndex(Telephony.Sms.DATE)
            val db = Db(this)
            var leidos = 0
            while (c.moveToNext() && leidos < 500) {
                leidos++
                val addr = c.getString(iA) ?: ""
                val body = c.getString(iB) ?: ""
                val fecha = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
                    .format(Date(c.getLong(iD)))
                val tx = Parser.parsear(fecha, addr, body, "SMS")
                if (tx.banco == "Desconocido" && !tx.esTransaccion) continue
                if (db.guardar(tx)) nuevos++
            }
        }
        Toast.makeText(this, "Escaneo listo: $nuevos nuevos", Toast.LENGTH_LONG).show()
        refrescar()
    }

    /** Escapa un campo para CSV: comillas dobles y comas/saltos seguros. */
    private fun csv(s: String): String {
        val t = s.replace("\"", "\"\"").replace("\r", " ").replace("\n", " ")
        return "\"$t\""
    }

    private fun exportarCsv() {
        val db = Db(this)
        val f = File(getExternalFilesDir(null), "transacciones.csv")
        f.printWriter().use { w ->
            // Incluimos monto_txt (lo crudo que capturo el regex), remitente y el
            // mensaje COMPLETO: asi el visualizador puede auditar/recategorizar.
            w.println("fecha,banco,tipo,monto,monto_txt,comercio,contraparte,parseo_ok,fuente,remitente,mensaje")
            for (r in db.todasParaCsv()) {
                w.println(
                    listOf(
                        r.fecha, r.banco, r.tipo, r.monto.toString(), r.montoTxt ?: "",
                        r.comercio ?: "", r.contraparte ?: "", r.ok.toString(),
                        r.fuente, r.remitente, r.texto
                    ).joinToString(",") { csv(it) }
                )
            }
        }
        Toast.makeText(this, "CSV en:\n${f.absolutePath}", Toast.LENGTH_LONG).show()
    }

    private fun fmtMonto(m: Double): String =
        "$" + String.format(Locale.US, "%,.0f", m).replace(",", ".")

    private fun notiActivo(): Boolean {
        val flat = Settings.Secure.getString(
            contentResolver, "enabled_notification_listeners"
        ) ?: return false
        return flat.contains(packageName)
    }

    private fun refrescar() {
        val db = Db(this)
        val r = db.resumen()
        status.text = buildString {
            append("Permiso SMS: ").append(if (tieneSms()) "✓ concedido" else "· falta").append("\n")
            append("Acceso notificaciones: ").append(if (notiActivo()) "✓ activo" else "· inactivo").append("\n\n")
            append("Transacciones capturadas: ").append(r.tx).append("\n")
            append("· completas (✓): ").append(r.ok).append("\n")
            append("· parciales (·): ").append(r.pend).append("\n\n")
            append("Ingresos: ").append(fmtMonto(r.ingresos)).append("\n")
            append("Egresos: ").append(fmtMonto(r.egresos)).append("\n")
            append("Balance: ").append(fmtMonto(r.ingresos - r.egresos)).append("\n\n")
            append("Pendientes de subir a la nube: ").append(db.contarPendientes())
        }

        val sb = StringBuilder()
        for (row in db.ultimas(15)) {
            val marca = if (row.ok == 1) "✓" else "·"
            val signo = if (row.tipo == "ingreso") "+" else "-"
            val com = row.comercio ?: "[sin comercio]"
            sb.append(marca).append(" ").append(row.fecha.take(16)).append("  ")
                .append(row.banco).append("  ").append(signo).append(fmtMonto(row.monto)).append("  ")
                .append(com).append("  (").append(row.fuente).append(")\n")
        }
        resultados.text = if (sb.isEmpty()) "(nada todavía — abre tus SMS o usa el botón 3)" else sb.toString()
    }
}
