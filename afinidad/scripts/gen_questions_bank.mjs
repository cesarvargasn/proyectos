// One-shot generator: parses preguntas_bilingue.md and emits seed_questions_bank.sql
// Classification is a keyword heuristic (first pass) — the host can re-categorize
// any question inline in the admin editor. Inserts are dedup-guarded by text.
import { readFileSync, writeFileSync } from 'node:fs'

const MD = 'C:/Users/cesar/Downloads/preguntas_bilingue.md'
const OUT = 'C:/Users/cesar/OneDrive/Documents/PERSONALE_UTILIDADES/Matching_app/seed_questions_bank.sql'

// Per-category default weight (mirrors the existing weighting scheme)
const WEIGHT = {
  valores: 2, relacion: 3, personalidad: 1, lifestyle: 1.5, humor: 1,
  suenos: 1.5, sexualidad: 2, familia: 2, espiritualidad: 2, social: 1,
  trabajo: 1, fisico: 1, general: 1,
}

// Ordered rules: first match wins. Match against lowercased Spanish text.
const RULES = [
  ['sexualidad',     /queer|drag|género|genero|sexual|pride|heterosexual|gay\b|gei\b/],
  ['espiritualidad', /\bfe\b|religi|poder superior|destino|shabbat|kosher|supersticios|\balma|sagrad|dios\b|creo en/],
  ['relacion',       /pareja|enamora|romántic|romantic|amor\b|amar|te amo|almas gemelas|soltero|soltera|relación|relacion|matrimonio|fugánd|incondicional/],
  ['familia',        /familia|hijo|padres|mayores|tradicion|asilo|abuel|crí|cri[aá]|elegida/],
  ['humor',          /broma|chiste|gracios|sarcasm|humor|cómic|comic|me burlo|alivio/],
  ['trabajo',        /trabaj|carrera|colega|profesional|networking|contactos|puntualidad|adicto al|metas profesion/],
  ['social',         /amig|amistad|vecino|gente nueva|fiesta|conocer gente|redes sociales|comunidad|caer bien|caerle bien|networking|haters|bullying/],
  ['suenos',         /sueño|sueno|cambiar el mundo|visión|vision|futuro|plan a 5|metas\b|pasión|pasion|esperanza|gobernar|gobernaría/],
  ['lifestyle',      /lujo|rutina|viaj|explorar|salud|comida|tatuaje|estilo|comodidad|placer|indulg|darse gust|aire libre|libros|bailar|foto|kosher|dieta|mudar/],
  ['valores',        /honest|verdad|responsab|confianza|moral|altruism|empat|vengan|regla|soborno|polític|politic|multimillonario|planeta|ahorr|disciplina|ambición|ambicion|justific|promesa|voto|votar|billonario|inconformis|autoridad|nadie es mejor|correcto/],
  // fallback
  ['personalidad',   /.*/],
]

function classify(es) {
  const t = es.toLowerCase()
  for (const [cat, re] of RULES) if (re.test(t)) return cat
  return 'personalidad'
}

const md = readFileSync(MD, 'utf8')
const rows = []
for (const line of md.split(/\r?\n/)) {
  const m = line.match(/^\|\s*(\d+)\s*\|(.+?)\|(.+?)\|\s*$/)
  if (!m) continue
  const en = m[2].trim()
  const es = m[3].trim()
  if (!es || /\[cortado\]/i.test(es) || /\[cortado\]/i.test(en)) { rows.push({ skipped: m[1], es }); continue }
  rows.push({ num: m[1], en, es })
}

const valid = rows.filter(r => !r.skipped)
const skipped = rows.filter(r => r.skipped)

const sqlEsc = s => s.replace(/'/g, "''")
const counts = {}
const lines = []
for (const r of valid) {
  const cat = classify(r.es)
  counts[cat] = (counts[cat] ?? 0) + 1
  const w = WEIGHT[cat] ?? 1
  lines.push(
    `INSERT INTO questions (text, text_en, category, weight)\n` +
    `SELECT '${sqlEsc(r.es)}', '${sqlEsc(r.en)}', '${cat}', ${w}\n` +
    `WHERE NOT EXISTS (SELECT 1 FROM questions q WHERE q.text = '${sqlEsc(r.es)}');`
  )
}

const header =
`-- ============================================================
-- Match Night — Question bank import (${valid.length} questions)
-- Generated from preguntas_bilingue.md. Run AFTER migration_feedback_qbank.sql
-- (needs the text_en column). Safe to re-run: each INSERT is dedup-guarded by text.
-- These go to the BANK only — NOT auto-activated in any event.
-- Category is a heuristic first pass; re-categorize freely in the admin editor.
-- ============================================================

`

writeFileSync(OUT, header + lines.join('\n\n') + '\n')

console.log('TOTAL parsed:', rows.length)
console.log('INSERTED:', valid.length)
console.log('SKIPPED (cortado):', skipped.map(s => s.skipped).join(', '))
console.log('BY CATEGORY:')
for (const [c, n] of Object.entries(counts).sort((a, b) => b[1] - a[1])) console.log(`  ${c}: ${n}`)
