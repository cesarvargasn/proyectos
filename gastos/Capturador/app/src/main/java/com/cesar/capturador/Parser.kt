package com.cesar.capturador

import java.security.MessageDigest

/** Resultado de parsear un mensaje (SMS o notificación). */
data class Tx(
    val fecha: String,
    val remitente: String,
    val banco: String,
    val monto: Double?,
    val montoTxt: String?,
    val comercio: String?,
    val contraparte: String?,   // a quién se le pagó/transfirió (cuenta/llave/comercio)
    val esTransaccion: Boolean,
    val parseoOk: Boolean,
    val texto: String,
    val fuente: String,   // "SMS" o "PUSH"
    val tipo: String,     // "ingreso", "egreso" o ""
    val hash: String
)

/**
 * Motor de parseo. Mismo enfoque que el MVP de Python:
 *  - captura cruda primero (aunque el regex falle, el texto se guarda),
 *  - detecta transaccion = monto + keyword de tx + NO ser OTP,
 *  - extrae banco / monto / comercio best-effort.
 *
 * NOTA: las regex usan strings normales de Kotlin con escaping doble.
 * Patrones canonicos (PCRE) por si hay que reajustar el escaping:
 *   monto         -> \$\s*([0-9][0-9.,]*)
 *   monto alterno -> valor de\s*\$?\s*([0-9][0-9.,]*)
 *   comercio "en" -> \ben\s+([A-Za-z0-9][A-Za-z0-9 *.\-&]{1,34}?)(?=\s+(?:el|con|desde|por|tarjeta|cuenta|\d{1,2}[/:])|[.,]|$)
 *   comercio "a"  -> \ba\s+([A-ZÁÉÍÓÚÑ][A-Za-zÁÉÍÓÚÑáéíóúñ ]{2,30})
 */
object Parser {

    private val KW_TRANSACCION = listOf(
        "compra", "compraste", "pago", "pagaste", "pagado",
        "retiro", "retiraste", "avance", "transferencia", "transferiste",
        "envio", "envío", "enviaste", "recibiste", "consignacion", "consignación",
        "consignaste", "debito", "débito", "cargo", "aprobada", "aprobado",
        "realizaste", "abono", "por valor de", "por compra", "compra por", "movimiento"
    )

    private val KW_EXCLUIR = listOf(
        "clave dinamica", "clave dinámica", "codigo de seguridad", "código de seguridad",
        "tu codigo", "tu código", "token", "no la comparta", "no compartas",
        "no lo compartas", "otp", "codigo es", "código es", "clave es"
    )

    /** Eventos que NO son un movimiento real de plata (intentos fallidos o verificaciones). */
    private val KW_RECHAZO = listOf(
        "rechaz", "no fue aprobada", "no fue aprobado", "declinada", "declinado",
        "fue negada", "no se pudo", "saldo insuficiente", "transaccion fallida",
        "transacción fallida", "intento de compra",
        // Nubank: "Faltan fondos para pagar en UBER RIDES" = pago que NO salio.
        "faltan fondos",
        // Nubank envia este mensaje ANTES de que el usuario confirme la compra.
        // La transaccion real llega en un mensaje separado si el usuario aprueba.
        // Sin este filtro se captura la verificacion Y la compra real = duplicado.
        "intentando hacer esta compra",
        "verificacion de compra en linea", "verificación de compra en línea"
    )

    /**
     * Publicidad y ofertas de los propios bancos: mencionan banco + monto + verbos
     * de transaccion pero NO mueven plata. Keywords sacadas de casos reales de la BD
     * (Tabot "credito A la mano listo/preaprobado" $2.8M, DaviPlata "recarga BetPlay
     * y recibe apuesta gratis", Nequi "PayPal en modo promo").
     */
    private val KW_MARKETING = listOf(
        "cupo", "preaprobado", "pre-aprobado", "aprovecha", "credito a la mano",
        "crédito a la mano", "soy tabot", "oferta", "promo", "descuento",
        "apuesta", "gana ", "¡gana", "felicidades", "solicitalo", "solicítalo",
        "tienda virtual", "tasa de interes", "tasa de interés", "instagram",
        "listo para tus ideas",
        // "Te ofrecemos un credito de $X" (ofertas de prestamo con monto).
        "te ofrecemos"
    )

    /**
     * Movimientos entre cuentas propias que el banco reporta como si fueran
     * ingresos: "Pagaste tu tarjeta de credito Nu — Recibimos tu pago por $X".
     * La plata sale de otra cuenta propia (ese egreso si se captura); contar
     * tambien el lado Nu inflaria los ingresos.
     */
    private val KW_ESPEJO = listOf(
        "pagaste tu tarjeta"
    )

    /** Entrada de dinero (lo demas se asume egreso). */
    private val KW_INGRESO = listOf(
        "recibiste", "recibimos", "recibió", "te consignaron", "pago de nomi",
        "pago de nomina", "pago de nómina", "transferencia desde", "transf de",
        "consignacion", "consignación", "consignaste",
        // Reversiones: el banco devuelve plata a la cuenta (ej: cargo de Uber
        // que no se hizo efectivo). Se clasifican como ingreso para que cancelen
        // el egreso original en los totales.
        "devolucion", "devolución", "devolvimos", "reversamos", "reverso de", "reintegro"
    )

    private val BANCOS = linkedMapOf(
        "Bancolombia" to listOf("bancolombia"),
        "Davivienda" to listOf("davivienda", "daviplata"),
        "Nequi" to listOf("nequi"),
        // "nu.production" = packageName real de la app (com.nu.production). El push de
        // Nubank nunca dice "Nubank" en el texto, solo se identifica por el paquete.
        "Nubank" to listOf("nubank", "nu colombia", "nu.production"),
        "BBVA" to listOf("bbva"),
        "Banco de Bogota" to listOf("banco de bogota", "banco de bogotá"),
        "Scotiabank" to listOf("scotiabank", "colpatria"),
        "AV Villas" to listOf("av villas", "avvillas"),
        "Banco Popular" to listOf("banco popular"),
        "Itau" to listOf("itau", "itaú")
    )

    private val reMonto = Regex("\\\$\\s*([0-9][0-9.,]*)")
    private val reMontoValor = Regex("valor de\\s*\\\$?\\s*([0-9][0-9.,]*)", RegexOption.IGNORE_CASE)
    // El "_" en la clase permite codigos de cajero tipo "MF_BANLABB2" (retiros).
    private val reComercioEn = Regex(
        "\\ben\\s+([A-Za-z0-9][A-Za-z0-9_ *.\\-&]{1,34}?)(?=\\s+(?:el|con|desde|por|tarjeta|cuenta|de tu|\\d{1,2}[/:])|[.,]|\$)",
        RegexOption.IGNORE_CASE
    )
    private val reComercioA = Regex("\\ba\\s+([A-ZÁÉÍÓÚÑ][A-Za-zÁÉÍÓÚÑáéíóúñ ]{2,30})")

    // Destino de una transferencia: "a la cuenta *1234567890" / "a la llave 3001234567".
    // Captura el numero (con o sin '*'). Es la clave estable para identificar recurrentes.
    private val reDestinoNum = Regex(
        "a la (?:cuenta|llave)\\s*\\*?\\s*([0-9][0-9*]{2,})",
        RegexOption.IGNORE_CASE
    )

    // Origen de un ingreso: "recibiste una transferencia de ADRIANA MARIA NIETO en tu
    // cuenta" / "pago de Nomina de PANTEHON VENT O por $...". Nombre arranca en mayuscula;
    // se toma el ULTIMO match para saltar prefijos tipo "pago de Nomina de FULANO".
    private val reOrigenDe = Regex(
        "\\bde\\s+([A-ZÁÉÍÓÚÑ][A-Za-zÁÉÍÓÚÑáéíóúñ .]{2,40}?)\\s+(?:por|en tu)"
    )

    fun detectarBanco(remitente: String, cuerpo: String): String {
        val t = (remitente + " " + cuerpo).lowercase()
        for ((banco, claves) in BANCOS) for (c in claves) if (t.contains(c)) return banco
        return "Desconocido"
    }

    private fun esOtp(low: String) = KW_EXCLUIR.any { low.contains(it) }
    private fun esRechazo(low: String) = KW_RECHAZO.any { low.contains(it) }
    private fun esMarketing(low: String) = KW_MARKETING.any { low.contains(it) }
    private fun esEspejo(low: String) = KW_ESPEJO.any { low.contains(it) }
    private fun tieneKwTx(low: String) = KW_TRANSACCION.any { low.contains(it) }
    private fun esIngreso(low: String) = KW_INGRESO.any { low.contains(it) }

    fun normalizarMonto(raw0: String): Double? {
        val raw = raw0.trim().trimEnd('.', ',')
        if (raw.isEmpty()) return null
        // En COP los montos son enteros y "." o "," son separadores de miles
        // (grupos de 3). Solo tratamos el ultimo separador como coma decimal si
        // va seguido de 1 o 2 digitos (centavos), caso raro pero por seguridad.
        val lastSep = maxOf(raw.lastIndexOf('.'), raw.lastIndexOf(','))
        val tail = if (lastSep >= 0) raw.length - lastSep - 1 else -1
        return try {
            if (lastSep >= 0 && (tail == 1 || tail == 2)) {
                val ent = raw.substring(0, lastSep).replace(".", "").replace(",", "")
                val dec = raw.substring(lastSep + 1)
                "$ent.$dec".toDouble()
            } else {
                raw.replace(".", "").replace(",", "").toDouble()
            }
        } catch (e: NumberFormatException) {
            null
        }
    }

    fun extraerMonto(cuerpo: String): Pair<Double?, String?> {
        val m = reMonto.find(cuerpo) ?: reMontoValor.find(cuerpo) ?: return null to null
        val crudo = m.groupValues[1].trimEnd('.', ',')
        return normalizarMonto(crudo) to crudo
    }

    fun extraerComercio(cuerpo: String): String? {
        reComercioEn.find(cuerpo)?.let {
            val c = it.groupValues[1].trim(' ', '.', '-')
            if (c.length >= 2 && c.lowercase() !in listOf("tu", "el", "la", "su")) return c
        }
        reComercioA.find(cuerpo)?.let {
            // "a Fulano de Tal el 03/05..." -> quitar conectores colgados al final
            val stop = setOf("el", "la", "con", "desde", "por", "de", "del", "y", "a")
            val toks = it.groupValues[1].trim().split(" ").toMutableList()
            while (toks.isNotEmpty() && toks.last().lowercase() in stop) toks.removeAt(toks.size - 1)
            val c = toks.joinToString(" ").trim()
            if (c.length >= 2) return c
        }
        return null
    }

    /**
     * "Para quién": identificador estable de la contraparte para la app de visualizacion.
     *  - Transferencia -> numero de cuenta/llave de destino (lo mas estable: el numero no
     *    cambia aunque el nombre venga con distinto formato).
     *  - Compra/pago    -> el comercio ya extraido.
     * Con ese numero + monto basta para etiquetar una vez y reconocer recurrentes
     * (la psicologa, la señora del aseo, etc.).
     */
    fun extraerContraparte(cuerpo: String, comercio: String?, ingreso: Boolean = false): String? {
        reDestinoNum.find(cuerpo)?.let { return it.groupValues[1].trim() }
        if (ingreso) {
            reOrigenDe.findAll(cuerpo).lastOrNull()?.let {
                val c = it.groupValues[1].trim(' ', '.')
                if (c.length >= 3) return c
            }
        }
        return comercio
    }

    private fun sha1(s: String): String =
        MessageDigest.getInstance("SHA-1").digest(s.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    fun parsear(fecha: String, remitente: String, cuerpo: String, fuente: String): Tx {
        val low = cuerpo.lowercase()
        val banco = detectarBanco(remitente, cuerpo)
        val (monto, montoTxt) = extraerMonto(cuerpo)
        val comercio = extraerComercio(cuerpo)
        val contraparte = extraerContraparte(cuerpo, comercio, esIngreso(low))
        // Transaccion real = banco conocido + monto + verbo de accion + no OTP + no rechazo.
        // El requisito de banco conocido descarta publicidad/cobros (Addi, TUYA, Claro,
        // Movistar, Falabella, etc.), que nunca nombran un banco propio.
        val esTx = monto != null && banco != "Desconocido" &&
            tieneKwTx(low) && !esOtp(low) && !esRechazo(low) &&
            !esMarketing(low) && !esEspejo(low)
        val ok = esTx && comercio != null
        val tipo = if (esTx) (if (esIngreso(low)) "ingreso" else "egreso") else ""
        return Tx(
            fecha, remitente, banco, monto, montoTxt, comercio, contraparte,
            esTx, ok, cuerpo, fuente, tipo, sha1("$fecha|$remitente|$cuerpo")
        )
    }
}
