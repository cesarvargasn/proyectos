package com.cesar.capturador

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/** SQLite crudo (sin Room) para mantener el build liviano y sin dependencias. */
class Db(ctx: Context) : SQLiteOpenHelper(ctx.applicationContext, "capturador.db", null, 5) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE transacciones (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                hash TEXT UNIQUE,
                fecha TEXT, remitente TEXT, banco TEXT,
                monto REAL, monto_txt TEXT, comercio TEXT, contraparte TEXT,
                es_transaccion INTEGER, parseo_ok INTEGER,
                texto TEXT, fuente TEXT, tipo TEXT,
                capturado_en TEXT, sync_state TEXT DEFAULT 'pending'
            )
            """.trimIndent()
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, old: Int, new: Int) {
        // Migracion aditiva: el historico del telefono NUNCA se borra.
        // Columnas nuevas se agregan con ALTER; las filas existentes quedan.
        val cols = mutableSetOf<String>()
        db.rawQuery("PRAGMA table_info(transacciones)", null).use { c ->
            while (c.moveToNext()) cols.add(c.getString(1))
        }
        if (cols.isEmpty()) { onCreate(db); return }
        if ("sync_state" !in cols)
            db.execSQL("ALTER TABLE transacciones ADD COLUMN sync_state TEXT DEFAULT 'pending'")
    }

    /** Inserta si es nuevo (dedup por hash). Devuelve true si fue nuevo. */
    fun guardar(tx: Tx): Boolean {
        val cv = ContentValues().apply {
            put("hash", tx.hash)
            put("fecha", tx.fecha)
            put("remitente", tx.remitente)
            put("banco", tx.banco)
            if (tx.monto != null) put("monto", tx.monto) else putNull("monto")
            put("monto_txt", tx.montoTxt)
            put("comercio", tx.comercio)
            put("contraparte", tx.contraparte)
            put("es_transaccion", if (tx.esTransaccion) 1 else 0)
            put("parseo_ok", if (tx.parseoOk) 1 else 0)
            put("texto", tx.texto)
            put("fuente", tx.fuente)
            put("tipo", tx.tipo)
            put("capturado_en", System.currentTimeMillis().toString())
            put("sync_state", "pending")
        }
        val id = writableDatabase.insertWithOnConflict(
            "transacciones", null, cv, SQLiteDatabase.CONFLICT_IGNORE
        )
        return id != -1L
    }

    data class Resumen(
        val total: Int, val tx: Int, val ok: Int, val pend: Int,
        val ingresos: Double, val egresos: Double
    )

    fun resumen(): Resumen {
        val db = readableDatabase
        fun count(w: String): Int =
            db.rawQuery("SELECT COUNT(*) FROM transacciones WHERE $w", null).use {
                it.moveToFirst(); it.getInt(0)
            }
        fun suma(w: String): Double =
            db.rawQuery("SELECT COALESCE(SUM(monto),0) FROM transacciones WHERE $w", null).use {
                it.moveToFirst(); it.getDouble(0)
            }
        return Resumen(
            count("1=1"),
            count("es_transaccion=1"),
            count("parseo_ok=1"),
            count("es_transaccion=1 AND parseo_ok=0"),
            suma("es_transaccion=1 AND tipo='ingreso'"),
            suma("es_transaccion=1 AND tipo='egreso'")
        )
    }

    data class Row(
        val fecha: String, val banco: String, val monto: Double,
        val comercio: String?, val ok: Int, val fuente: String,
        val remitente: String, val montoTxt: String?, val texto: String,
        val tipo: String, val contraparte: String?
    )

    private fun consultar(limit: Int?): List<Row> {
        val out = ArrayList<Row>()
        val lim = if (limit != null) " LIMIT $limit" else ""
        readableDatabase.rawQuery(
            "SELECT fecha,banco,monto,comercio,parseo_ok,fuente,remitente,monto_txt,texto,tipo,contraparte " +
                "FROM transacciones WHERE es_transaccion=1 ORDER BY id DESC$lim", null
        ).use { c ->
            while (c.moveToNext()) out.add(
                Row(
                    c.getString(0) ?: "", c.getString(1) ?: "", c.getDouble(2),
                    c.getString(3), c.getInt(4), c.getString(5) ?: "",
                    c.getString(6) ?: "", c.getString(7), c.getString(8) ?: "",
                    c.getString(9) ?: "", c.getString(10)
                )
            )
        }
        return out
    }

    fun ultimas(n: Int) = consultar(n)
    fun todasParaCsv() = consultar(null)

    // ------------------------------------------------------------- sync nube
    data class FilaSync(
        val hash: String, val fecha: String, val remitente: String,
        val banco: String, val monto: Double?, val montoTxt: String?,
        val comercio: String?, val contraparte: String?,
        val esTransaccion: Int, val parseoOk: Int, val texto: String,
        val fuente: String, val tipo: String, val capturadoEn: String?
    )

    /** Filas aun no subidas a Supabase (se suben TODAS, tambien las no-tx:
     *  la nube es backup crudo; los filtros los aplica el visualizador). */
    fun pendientes(limit: Int): List<FilaSync> {
        val out = ArrayList<FilaSync>()
        readableDatabase.rawQuery(
            "SELECT hash,fecha,remitente,banco,monto,monto_txt,comercio,contraparte," +
                "es_transaccion,parseo_ok,texto,fuente,tipo,capturado_en " +
                "FROM transacciones WHERE sync_state IS NULL OR sync_state='pending' " +
                "ORDER BY id LIMIT $limit", null
        ).use { c ->
            while (c.moveToNext()) out.add(
                FilaSync(
                    c.getString(0) ?: continue, c.getString(1) ?: "", c.getString(2) ?: "",
                    c.getString(3) ?: "", if (c.isNull(4)) null else c.getDouble(4),
                    c.getString(5), c.getString(6), c.getString(7),
                    c.getInt(8), c.getInt(9), c.getString(10) ?: "",
                    c.getString(11) ?: "", c.getString(12) ?: "", c.getString(13)
                )
            )
        }
        return out
    }

    fun marcarSynced(hashes: List<String>) {
        if (hashes.isEmpty()) return
        val db = writableDatabase
        db.beginTransaction()
        try {
            for (h in hashes)
                db.execSQL("UPDATE transacciones SET sync_state='synced' WHERE hash=?", arrayOf(h))
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    fun contarPendientes(): Int =
        readableDatabase.rawQuery(
            "SELECT COUNT(*) FROM transacciones WHERE sync_state IS NULL OR sync_state='pending'",
            null
        ).use { it.moveToFirst(); it.getInt(0) }
}
