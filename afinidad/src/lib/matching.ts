import { supabase } from './supabase'

interface Vec { id: string; vector: number[] }

function cosineSim(a: number[], b: number[], weights: number[]): number {
  let dot = 0, magA = 0, magB = 0
  for (let i = 0; i < a.length; i++) {
    const w = weights[i]
    dot  += a[i] * b[i] * w * w
    magA += (a[i] * w) ** 2
    magB += (b[i] * w) ** 2
  }
  if (magA === 0 || magB === 0) return 0
  return dot / (Math.sqrt(magA) * Math.sqrt(magB))
}

async function loadQuestionsAndWeights(eventId: string) {
  const { data: eqs, error } = await supabase
    .from('event_questions')
    .select('question_id, questions(weight)')
    .eq('active', true)
    .eq('event_id', eventId)
    .order('display_order')
  if (error || !eqs?.length) throw new Error('No hay preguntas activas.')
  return {
    questionIds: eqs.map(eq => eq.question_id),
    weights: eqs.map(eq => (eq.questions as unknown as { weight: number }).weight),
  }
}

async function buildVecs(pids: string[], questionIds: string[], weights: number[]): Promise<{ vecs: Vec[]; weights: number[] }> {
  const { data: answers, error } = await supabase
    .from('answers')
    .select('participant_id, question_id, value')
    .in('participant_id', pids)
    .in('question_id', questionIds)
  if (error) throw new Error('Error cargando respuestas.')

  const ansMap = new Map<string, Map<string, number>>()
  for (const ans of answers ?? []) {
    if (!ansMap.has(ans.participant_id)) ansMap.set(ans.participant_id, new Map())
    ansMap.get(ans.participant_id)!.set(ans.question_id, ans.value)
  }

  // Include ALL participants. Missing answers default to neutral (3) so
  // someone who joined without answering still gets matched.
  const vecs = pids.map(id => {
    const a = ansMap.get(id)
    return { id, vector: questionIds.map(qid => a?.get(qid) ?? 3) }
  })

  return { vecs, weights }
}

// ── Affinity map (read-only; does NOT touch matching/realtime) ──
// Returns the full pairwise cosine-similarity matrix over participants who
// completed the questionnaire. Reuses the exact same vectors/weights the
// matching algorithm uses, so the map reflects what the algorithm "sees".
export interface AffinityData {
  ids: string[]
  sim: number[][] // sim[i][j] = weighted cosine similarity, 0..1
}

export async function computeAffinity(eventId: string): Promise<AffinityData> {
  const { questionIds, weights } = await loadQuestionsAndWeights(eventId)

  const { data: parts, error } = await supabase
    .from('participants')
    .select('id')
    .eq('event_id', eventId)
    .not('completed_at', 'is', null)
    .order('created_at')

  if (error || !parts || parts.length < 2) {
    throw new Error('Necesitas al menos 2 participantes que hayan completado el cuestionario.')
  }

  const ids = parts.map(p => p.id)
  const { vecs } = await buildVecs(ids, questionIds, weights)

  const n = vecs.length
  const sim: number[][] = Array.from({ length: n }, () => new Array(n).fill(0))
  for (let i = 0; i < n; i++) {
    sim[i][i] = 1
    for (let j = i + 1; j < n; j++) {
      const s = cosineSim(vecs[i].vector, vecs[j].vector, weights)
      sim[i][j] = s
      sim[j][i] = s
    }
  }

  return { ids, sim }
}

// ── Rondas embudo ──
// 2 grupos → 4 grupos → grupos de ~4 → duplas, todo ANIDADO: cada ronda
// parte los grupos de la anterior, y las duplas finales se arman dentro
// de cada grupo de la ronda 3. Objetivo de cada partición: maximizar la
// afinidad dentro de los grupos (misma similitud coseno que el matching).
// Tamaños parejos; quien sobre sin dupla en su grupo (grupos impares) se
// empareja con otro sobrante. Si el total es impar, el último que sobra
// se une a la dupla más afín y forma un TRÍO (nunca a la dupla del admin).
// Es el ÚNICO cálculo de la app: las rondas son opcionales — se puede
// saltar directo a revelar duplas.

export interface FunnelResult {
  rounds: { round: number; groups: { ids: string[]; score: number }[] }[]
  matchCount: number
  trios: string[][]
  unmatchedIds: string[]
}

// k grupos con tamaños lo más parejos posible (diferencia máx. 1).
function groupSizes(n: number, k: number): number[] {
  const kk = Math.max(1, Math.min(k, Math.floor(n / 2)))
  const base = Math.floor(n / kk)
  const rem = n % kk
  return Array.from({ length: kk }, (_, i) => base + (i < rem ? 1 : 0))
}

// Ronda 3: grupos de 3-4
function smallGroupCount(n: number): number {
  return Math.max(1, Math.round(n / 3.5))
}

function avgIntra(ids: number[], S: number[][]): number {
  if (ids.length < 2) return 1
  let sum = 0, cnt = 0
  for (let i = 0; i < ids.length; i++)
    for (let j = i + 1; j < ids.length; j++) { sum += S[ids[i]][ids[j]]; cnt++ }
  return sum / cnt
}

// Parte `nodes` (índices en S) en grupos de `sizes`. `locked` = nodos que
// deben quedar juntos (la dupla del admin) — van al grupo 0 y no se mueven.
function partition(nodes: number[], sizes: number[], S: number[][], locked: number[]): number[][] {
  if (sizes.length === 1) return [[...nodes]]
  const groups: number[][] = sizes.map(() => [])
  const free = new Set(nodes)
  const lockedIn = locked.filter(x => free.has(x))
  if (lockedIn.length === 2) {
    groups[0].push(...lockedIn)
    lockedIn.forEach(x => free.delete(x))
  }

  const avgTo = (u: number, g: number[]) =>
    g.length ? g.reduce((s, x) => s + S[u][x], 0) / g.length : 0

  // Semillas: grupos vacíos reciben el nodo menos parecido a lo ya sembrado
  for (let gi = 0; gi < groups.length; gi++) {
    if (groups[gi].length) continue
    const seeded = groups.flat()
    let best = -1, bestVal = Infinity
    for (const u of free) {
      const v = seeded.length ? avgTo(u, seeded) : avgTo(u, nodes.filter(x => x !== u))
      if (v < bestVal) { bestVal = v; best = u }
    }
    if (best >= 0) { groups[gi].push(best); free.delete(best) }
  }

  // Greedy: siempre la asignación (nodo, grupo con cupo) más afín
  while (free.size) {
    let bu = -1, bg = -1, bv = -Infinity
    for (const u of free) {
      for (let gi = 0; gi < groups.length; gi++) {
        if (groups[gi].length >= sizes[gi]) continue
        const v = avgTo(u, groups[gi])
        if (v > bv) { bv = v; bu = u; bg = gi }
      }
    }
    groups[bg].push(bu); free.delete(bu)
  }

  // Mejora local: intercambios entre grupos mientras suban la afinidad interna
  const isLocked = (x: number) => lockedIn.length === 2 && lockedIn.includes(x)
  const sumTo = (u: number, g: number[]) => g.reduce((s, x) => (x === u ? s : s + S[u][x]), 0)
  for (let iter = 0; iter < 100; iter++) {
    let improved = false
    for (let a = 0; a < groups.length; a++) {
      for (let b = a + 1; b < groups.length; b++) {
        for (let i = 0; i < groups[a].length; i++) {
          for (let j = 0; j < groups[b].length; j++) {
            const u = groups[a][i], v = groups[b][j]
            if (isLocked(u) || isLocked(v)) continue
            const gain = (sumTo(u, groups[b]) - S[u][v]) + (sumTo(v, groups[a]) - S[u][v])
                       - sumTo(u, groups[a]) - sumTo(v, groups[b])
            if (gain > 1e-9) { groups[a][i] = v; groups[b][j] = u; improved = true }
          }
        }
      }
    }
    if (!improved) break
  }
  return groups
}

export async function runFunnel(eventId: string): Promise<FunnelResult> {
  const { ids, sim } = await computeAffinity(eventId)
  const n = ids.length
  if (n < 4) throw new Error('El embudo necesita al menos 4 participantes que hayan completado el cuestionario.')

  // Dupla del admin (si participa y la eligió): siempre juntos
  const { data: es } = await supabase
    .from('event_state')
    .select('admin_participates, admin_participant_id, admin_partner_id')
    .eq('event_id', eventId)
    .order('id').limit(1)
  const st = es?.[0]
  let locked: number[] = []
  if (st?.admin_participates && st.admin_participant_id && st.admin_partner_id) {
    const a = ids.indexOf(st.admin_participant_id), b = ids.indexOf(st.admin_partner_id)
    if (a >= 0 && b >= 0) locked = [a, b]
  }

  const all = ids.map((_, i) => i)
  const r1 = partition(all, groupSizes(n, 2), sim, locked)
  const r2 = r1.flatMap(g => partition(g, groupSizes(g.length, 2), sim, locked))
  const r3 = r2.flatMap(g => partition(g, groupSizes(g.length, smallGroupCount(g.length)), sim, locked))

  // Duplas dentro de cada grupo de la ronda 3
  const duplas: { a: number; b: number; score: number; locked?: boolean }[] = []
  const greedyPairs = (pool: number[]): number[] => {
    const pairs: { a: number; b: number; score: number }[] = []
    for (let i = 0; i < pool.length; i++)
      for (let j = i + 1; j < pool.length; j++)
        pairs.push({ a: pool[i], b: pool[j], score: sim[pool[i]][pool[j]] })
    pairs.sort((x, y) => y.score - x.score)
    const used = new Set<number>()
    for (const p of pairs) {
      if (used.has(p.a) || used.has(p.b)) continue
      used.add(p.a); used.add(p.b)
      duplas.push({ a: p.a, b: p.b, score: p.score })
    }
    return pool.filter(x => !used.has(x))
  }
  const leftovers: number[] = []
  for (const g of r3) {
    let pool = g
    if (locked.length === 2 && g.includes(locked[0])) {
      duplas.push({ a: locked[0], b: locked[1], score: 0.95 + Math.random() * 0.04, locked: true })
      pool = g.filter(x => !locked.includes(x))
    }
    leftovers.push(...greedyPairs(pool))
  }
  // Sobrantes de grupos impares: se emparejan entre ellos
  const alone = greedyPairs(leftovers)

  // Total impar: el que queda se une a la dupla más afín → trío.
  // Primero busca en su grupo de la ronda 3; nunca entra a la dupla del admin.
  const rows: { a: string; b: string; score: number }[] =
    duplas.map(d => ({ a: ids[d.a], b: ids[d.b], score: d.score }))
  const trios: string[][] = []
  for (const x of alone) {
    const myGroup = r3.find(g => g.includes(x)) ?? []
    const open = duplas.filter(d => !d.locked)
    const inGroup = open.filter(d => myGroup.includes(d.a) && myGroup.includes(d.b))
    const cands = inGroup.length ? inGroup : open
    if (!cands.length) continue
    const best = cands.reduce((bst, d) =>
      (sim[x][d.a] + sim[x][d.b]) > (sim[x][bst.a] + sim[x][bst.b]) ? d : bst)
    rows.push({ a: ids[x], b: ids[best.a], score: sim[x][best.a] })
    rows.push({ a: ids[x], b: ids[best.b], score: sim[x][best.b] })
    trios.push([ids[x], ids[best.a], ids[best.b]])
  }

  const rounds = [r1, r2, r3].map((gs, ri) => ({
    round: ri + 1,
    groups: gs.map(g => ({ ids: g.map(i => ids[i]), score: avgIntra(g, sim) })),
  }))

  // Guardar: grupos de las 3 rondas + duplas finales (reemplaza lo anterior)
  const { error: delErr } = await supabase.from('funnel_groups').delete().eq('event_id', eventId)
  if (delErr) throw new Error(`Error limpiando embudo: ${delErr.message} (¿corriste migration_embudo.sql?)`)
  const groupRows = rounds.flatMap(r => r.groups.flatMap((g, gi) =>
    g.ids.map(pid => ({ event_id: eventId, round: r.round, group_idx: gi, participant_id: pid, score: g.score }))))
  const { error: insErr } = await supabase.from('funnel_groups').insert(groupRows)
  if (insErr) throw new Error(`Error guardando embudo: ${insErr.message}`)

  await supabase.from('matches').delete().eq('event_id', eventId)
  if (rows.length) {
    const { error } = await supabase.from('matches').insert(
      rows.map(m => ({ event_id: eventId, participant_a: m.a, participant_b: m.b, score: m.score })))
    if (error) throw new Error('Error guardando duplas.')
  }

  const matched = new Set(rows.flatMap(d => [d.a, d.b]))
  return { rounds, matchCount: duplas.length, trios, unmatchedIds: ids.filter(id => !matched.has(id)) }
}
