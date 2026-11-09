package com.cesar.capturador

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Captura notificaciones push de apps de banco (Nequi, Nubank, etc).
 * Requiere que el usuario active "Acceso a notificaciones" para esta app.
 */
class NotiListener : NotificationListenerService() {

    // Nombres tentativos. Confirmar los reales con:
    //   adb shell pm list packages | findstr /I "nequi nu bancolombia daviv"
    // Evidencia real de la BD: com.nequi.MobileApp y com.nu.production confirmados.
    private val paquetesBanco = listOf(
        "nequi", "nu.production", "nubank", "bancolombia", "davivienda", "daviplata"
    )

    // Apps de mensajeria (SMS/RCS): sus notificaciones espejan los SMS que el SmsReceiver
    // YA captura. Ignorarlas evita el doble conteo (la misma transaccion entraba 2 veces:
    // una por el SMS y otra por la notificacion del SMS). Los SMS = SmsReceiver; el push
    // de apps bancarias (Nubank) = este listener.
    //
    // "messaging" cubre Google Messages (com.google.android.apps.messaging) y Samsung
    // Messages (com.samsung.android.messaging); "com.android.mms"/".mms" cubren el app de
    // mensajes legacy/AOSP. Evitamos tokens demasiado cortos ("sms", "messages") que
    // podrian llegar a colar con el paquete de algun banco. Esto NO toca la lectura de
    // SMS (eso lo hace SmsReceiver aparte); solo decide que notificaciones se ignoran.
    private val paquetesIgnorar = listOf(
        "messaging", "com.android.mms", ".mms"
    )

    override fun onNotificationPosted(sbn: StatusBarNotification) = procesar(sbn)

    /**
     * Al conectar el servicio (encender el telefono, re-activar el acceso o reinstalar),
     * barremos las notificaciones que YA estan en la bandeja. Asi las compras de Nubank
     * que siguen visibles se capturan sin esperar a que llegue una nueva. El dedup por
     * hash evita duplicados si la misma notificacion se reprocesa.
     */
    override fun onListenerConnected() {
        activeNotifications?.forEach { procesar(it) }
    }

    private fun procesar(sbn: StatusBarNotification) {
        val pkg = sbn.packageName ?: ""
        // WHITELIST estricta: SOLO apps bancarias. Antes habia un fallback que
        // aceptaba cualquier app si el texto "parecia transaccion"; por ahi entraron
        // 105 notificaciones de WhatsApp (publicidad Tabot de Bancolombia) contadas
        // como egresos de $2.8M cada una = $294M falsos, 93% del gasto total.
        // WhatsApp ademas re-postea la misma notificacion con otra hora -> otro hash
        // -> el dedup no la frena. La unica defensa segura es no leer esas apps.
        if (!paquetesBanco.any { pkg.contains(it, ignoreCase = true) }) return
        // El SMS ya lo captura SmsReceiver: no recapturar la notificacion espejo del SMS.
        if (paquetesIgnorar.any { pkg.contains(it, ignoreCase = true) }) return
        val extras = sbn.notification?.extras ?: return

        val titulo = extras.getCharSequence("android.title")?.toString().orEmpty()
        val texto = extras.getCharSequence("android.text")?.toString().orEmpty()
        val big = extras.getCharSequence("android.bigText")?.toString().orEmpty()

        val cuerpo = listOf(titulo, big.ifEmpty { texto })
            .filter { it.isNotBlank() }
            .joinToString(" — ")
        if (cuerpo.isBlank()) return

        // Usamos la hora REAL de la notificacion (postTime), no "ahora": asi reprocesar
        // la misma noti (al reconectar el servicio / barrer activas) da el mismo hash y
        // el dedup la ignora en vez de duplicarla.
        val cuando = if (sbn.postTime > 0) sbn.postTime else System.currentTimeMillis()
        val fecha = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(cuando))
        val tx = Parser.parsear(fecha, pkg, cuerpo, "PUSH")
        if (Db(applicationContext).guardar(tx)) Sync.intentarAsync(applicationContext)
    }
}
