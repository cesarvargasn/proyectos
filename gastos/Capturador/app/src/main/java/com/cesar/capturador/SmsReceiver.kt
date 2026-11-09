package com.cesar.capturador

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Recibe SMS en tiempo real (incluso con la app cerrada) y los guarda. */
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val msgs = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return

        val cuerpo = StringBuilder()
        var remitente = ""
        for (m in msgs) {
            cuerpo.append(m.messageBody ?: "")
            if (!m.originatingAddress.isNullOrEmpty()) remitente = m.originatingAddress!!
        }
        if (cuerpo.isBlank()) return

        val fecha = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
        val tx = Parser.parsear(fecha, remitente, cuerpo.toString(), "SMS")

        // Guardamos solo lo que parece bancario o luce como transaccion
        if (tx.banco == "Desconocido" && !tx.esTransaccion) return
        if (Db(context).guardar(tx)) Sync.intentarAsync(context)
    }
}
