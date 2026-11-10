/**
 * Pipeline de contenido: CSV → SQL para content_cards.
 *
 * Uso:   npm run content        (o: node scripts/content-to-sql.mjs)
 *
 * Lee cada content/<game_type>.csv (el nombre del archivo ES el game_type),
 * valida las filas y escribe supabase/content/<game_type>.sql, idempotente:
 * borra las cartas de ese juego y las reinserta. Pegar el .sql en el editor
 * SQL de Supabase cada vez que cambie el CSV.
 *
 * Columnas del CSV (cabecera obligatoria):
 *   text_es    (obligatoria) — texto de la carta; tokens {p1} {p2} {drink:N}
 *   intensity  (opcional, 1-5, default 2)
 *   card_type  (opcional, default 'default') — p.ej. verdad|reto, directa|duelo…
 *   text_en    (opcional)
 *   tags       (opcional) — separadas por ; p.ej. "picante;grupo"
 *   meta       (opcional) — JSON, p.ej. {"regla_dura":true}
 *
 * Archivos que empiezan con _ se ignoran (plantillas).
 */
import { readdirSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const CONTENT_DIR = join(ROOT, 'content')
const OUT_DIR = join(ROOT, 'supabase', 'content')

// Mantener en sync con src/games/registry.ts
const GAME_TYPES = [
  'prueba', 'yo-nunca', 'verdad-o-reto', 'el-senalado', 'la-ruleta', 'el-rey',
  'ocurrencias', 'mentiras', 'la-manada', 'sin-filtro', 'impostor', 'paranoia',
  'tres-rondas', 'parejas-a-gritos', 'lobos', 'mision-secreta', 'dos-cuartos',
]

const COLUMNS = ['text_es', 'intensity', 'card_type', 'text_en', 'tags', 'meta']

/** Parser CSV mínimo: comillas, comas y saltos de línea dentro de comillas. */
function parseCsv(raw) {
  const rows = []
  let row = []
  let field = ''
  let inQuotes = false
  const src = raw.replace(/^﻿/, '') // BOM de Excel
  for (let i = 0; i < src.length; i++) {
    const c = src[i]
    if (inQuotes) {
      if (c === '"') {
        if (src[i + 1] === '"') { field += '"'; i++ }
        else inQuotes = false
      } else field += c
    } else if (c === '"') {
      inQuotes = true
    } else if (c === ',') {
      row.push(field); field = ''
    } else if (c === '\n' || c === '\r') {
      if (c === '\r' && src[i + 1] === '\n') i++
      row.push(field); field = ''
      rows.push(row); row = []
    } else {
      field += c
    }
  }
  if (field !== '' || row.length) { row.push(field); rows.push(row) }
  return rows.filter((r) => r.some((f) => f.trim() !== ''))
}

const sqlStr = (s) => `'${s.replace(/'/g, "''")}'`
const sqlTextArray = (tags) =>
  tags.length ? `array[${tags.map(sqlStr).join(', ')}]` : `'{}'::text[]`

/** Tokens permitidos en text_es: {p1}..{p9} y {drink:N}. Avisa sobre el resto. */
function checkTokens(text, where, warnings) {
  for (const m of text.matchAll(/\{[^}]*\}/g)) {
    if (!/^\{(p[1-9]|drink:[1-9])\}$/.test(m[0])) {
      warnings.push(`${where}: token raro ${m[0]} (válidos: {p1}..{p9}, {drink:1}..{drink:9})`)
    }
  }
}

function processFile(file) {
  const gameType = file.replace(/\.csv$/i, '')
  const errors = []
  const warnings = []
  if (!GAME_TYPES.includes(gameType)) {
    errors.push(`nombre de archivo "${gameType}" no es un game_type conocido`)
  }

  const rows = parseCsv(readFileSync(join(CONTENT_DIR, file), 'utf8'))
  if (rows.length < 2) return { gameType, errors: [...errors, 'CSV vacío (solo cabecera o nada)'], warnings, sql: null, count: 0 }

  const header = rows[0].map((h) => h.trim().toLowerCase())
  if (!header.includes('text_es')) errors.push('falta columna text_es en la cabecera')
  for (const h of header) if (!COLUMNS.includes(h)) warnings.push(`columna desconocida "${h}" (se ignora)`)

  const col = (r, name) => {
    const i = header.indexOf(name)
    return i === -1 ? '' : (r[i] ?? '').trim()
  }

  const values = []
  const seen = new Set()
  rows.slice(1).forEach((r, idx) => {
    const line = `fila ${idx + 2}`
    const textEs = col(r, 'text_es')
    if (!textEs) { errors.push(`${line}: text_es vacío`); return }
    if (seen.has(textEs)) warnings.push(`${line}: carta duplicada ("${textEs.slice(0, 40)}…")`)
    seen.add(textEs)
    checkTokens(textEs, line, warnings)

    let intensity = 2
    const rawInt = col(r, 'intensity')
    if (rawInt) {
      intensity = Number(rawInt)
      if (!Number.isInteger(intensity) || intensity < 1 || intensity > 5) {
        errors.push(`${line}: intensity "${rawInt}" inválida (1-5)`); return
      }
    }

    const cardType = col(r, 'card_type') || 'default'
    const textEn = col(r, 'text_en')
    const tags = col(r, 'tags').split(';').map((t) => t.trim()).filter(Boolean)

    let meta = '{}'
    const rawMeta = col(r, 'meta')
    if (rawMeta) {
      try { meta = JSON.stringify(JSON.parse(rawMeta)) }
      catch { errors.push(`${line}: meta no es JSON válido: ${rawMeta}`); return }
    }

    values.push(
      `  (${sqlStr(gameType)}, ${sqlStr(cardType)}, ${sqlStr(textEs)}, ` +
      `${textEn ? sqlStr(textEn) : 'null'}, ${intensity}, ${sqlTextArray(tags)}, ${sqlStr(meta)}::jsonb)`
    )
  })

  if (errors.length) return { gameType, errors, warnings, sql: null, count: 0 }

  const sql = [
    `-- Generado por scripts/content-to-sql.mjs desde content/${file} — NO editar a mano.`,
    `-- ${values.length} cartas. Idempotente: borra y reinserta las cartas de ${gameType}.`,
    `begin;`,
    `delete from content_cards where game_type = ${sqlStr(gameType)};`,
    `insert into content_cards (game_type, card_type, text_es, text_en, intensity, tags, meta) values`,
    values.join(',\n') + ';',
    `commit;`,
    '',
  ].join('\n')
  return { gameType, errors, warnings, sql, count: values.length }
}

// --- main ---
let files
try {
  files = readdirSync(CONTENT_DIR).filter((f) => f.endsWith('.csv') && !f.startsWith('_'))
} catch {
  console.error(`No existe ${CONTENT_DIR} — crea content/<game_type>.csv primero.`)
  process.exit(1)
}
if (!files.length) {
  console.error('No hay CSVs en content/ (los que empiezan con _ se ignoran).')
  process.exit(1)
}

mkdirSync(OUT_DIR, { recursive: true })
let failed = false
for (const file of files) {
  const { gameType, errors, warnings, sql, count } = processFile(file)
  for (const w of warnings) console.warn(`⚠ ${file} — ${w}`)
  if (errors.length) {
    failed = true
    for (const e of errors) console.error(`✖ ${file} — ${e}`)
    continue
  }
  const out = join(OUT_DIR, `${gameType}.sql`)
  writeFileSync(out, sql, 'utf8')
  console.log(`✔ ${file} → supabase/content/${gameType}.sql (${count} cartas)`)
}
process.exit(failed ? 1 : 0)
