import { useEffect, useState } from 'react'
import { computeAffinity } from '../lib/matching'
import type { Participant } from '../lib/types'

interface MatchEdge {
  participant_a: string
  participant_b: string
}

interface Props {
  eventId: string
  participants: Participant[]
  matchPairs: MatchEdge[]
}

// ── Classical MDS (Torgerson) — distance = 1 - similarity ──
// Double-centre the squared-distance matrix, then take its top-2
// eigenvectors via power iteration + deflation. N is tiny (≤ ~60), so
// this is cheap and needs no external library (no d3 dependency).
function classicalMDS(sim: number[][]): { x: number; y: number }[] {
  const n = sim.length
  if (n === 0) return []
  if (n === 1) return [{ x: 0, y: 0 }]

  // Squared distances d²ij = (1 - sim)²
  const d2: number[][] = Array.from({ length: n }, (_, i) =>
    Array.from({ length: n }, (_, j) => {
      const d = 1 - sim[i][j]
      return d * d
    })
  )

  // Double centering: B = -1/2 · J · D² · J,  J = I - (1/n)·11ᵀ
  const rowMean = d2.map(r => r.reduce((s, v) => s + v, 0) / n)
  const grand = rowMean.reduce((s, v) => s + v, 0) / n
  const B: number[][] = Array.from({ length: n }, (_, i) =>
    Array.from({ length: n }, (_, j) => -0.5 * (d2[i][j] - rowMean[i] - rowMean[j] + grand))
  )

  const matVec = (M: number[][], v: number[]) =>
    M.map(row => row.reduce((s, val, k) => s + val * v[k], 0))
  const norm = (v: number[]) => Math.sqrt(v.reduce((s, x) => s + x * x, 0))

  function powerIteration(M: number[][]): { val: number; vec: number[] } {
    let v = Array.from({ length: n }, (_, i) => Math.sin(i + 1) + 0.5) // deterministic seed
    let nv = norm(v) || 1
    v = v.map(x => x / nv)
    let val = 0
    for (let it = 0; it < 200; it++) {
      const w = matVec(M, v)
      const wn = norm(w)
      if (wn < 1e-9) break
      const next = w.map(x => x / wn)
      val = v.reduce((s, x, k) => s + x * matVec(M, v)[k], 0) // Rayleigh quotient
      v = next
    }
    return { val, vec: v }
  }

  const e1 = powerIteration(B)
  // Deflate: B' = B - λ₁·v₁v₁ᵀ
  const B2 = B.map((row, i) => row.map((val, j) => val - e1.val * e1.vec[i] * e1.vec[j]))
  const e2 = powerIteration(B2)

  const s1 = Math.sqrt(Math.max(e1.val, 0))
  const s2 = Math.sqrt(Math.max(e2.val, 0))
  return e1.vec.map((_, i) => ({ x: e1.vec[i] * s1, y: e2.vec[i] * s2 }))
}

const W = 640
const H = 480
const PAD = 56

export default function AffinityGraph({ eventId, participants, matchPairs }: Props) {
  const [ids, setIds] = useState<string[]>([])
  const [coords, setCoords] = useState<{ x: number; y: number }[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')

  const nameOf = (id: string) =>
    participants.find(p => p.id === id)?.first_name ?? '—'

  async function build() {
    setLoading(true)
    setError('')
    try {
      const { ids, sim } = await computeAffinity(eventId)
      const raw = classicalMDS(sim)

      // Normalise raw MDS coords into the padded SVG viewport
      const xs = raw.map(c => c.x)
      const ys = raw.map(c => c.y)
      const minX = Math.min(...xs), maxX = Math.max(...xs)
      const minY = Math.min(...ys), maxY = Math.max(...ys)
      const spanX = maxX - minX || 1
      const spanY = maxY - minY || 1
      const scaled = raw.map(c => ({
        x: PAD + ((c.x - minX) / spanX) * (W - 2 * PAD),
        y: PAD + ((c.y - minY) / spanY) * (H - 2 * PAD),
      }))

      setIds(ids)
      setCoords(scaled)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'No se pudo construir el mapa.')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { build() }, [eventId, participants.length, matchPairs.length])

  const idx = (id: string) => ids.indexOf(id)

  return (
    <div className="admin-section">
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: '12px' }}>
        <p className="muted" style={{ maxWidth: '440px' }}>
          Cada nodo es una persona. La cercanía = afinidad (más cerca, más parecidos).
          Las líneas son las duplas que armó el algoritmo.
        </p>
        <button className="btn-ghost" onClick={build} disabled={loading}
          style={{ width: 'auto', padding: '8px 16px', fontSize: '0.72rem' }}>
          {loading ? 'Calculando...' : 'Recalcular'}
        </button>
      </div>

      {error && <p className="error">{error}</p>}

      {!error && ids.length >= 2 && (
        <div className="affinity-map-wrap">
          <svg viewBox={`0 0 ${W} ${H}`} className="affinity-svg" preserveAspectRatio="xMidYMid meet">
            {/* assigned-match edges */}
            {matchPairs.map((m, k) => {
              const a = idx(m.participant_a)
              const b = idx(m.participant_b)
              if (a < 0 || b < 0 || !coords[a] || !coords[b]) return null
              return (
                <line
                  key={`e${k}`}
                  x1={coords[a].x} y1={coords[a].y}
                  x2={coords[b].x} y2={coords[b].y}
                  className="affinity-edge"
                />
              )
            })}

            {/* nodes */}
            {ids.map((id, i) => coords[i] && (
              <g key={id}>
                <circle cx={coords[i].x} cy={coords[i].y} r={4} className="affinity-node-dot" />
                <text
                  x={coords[i].x}
                  y={coords[i].y - 10}
                  textAnchor="middle"
                  className="affinity-node-label"
                >
                  {nameOf(id)}
                </text>
              </g>
            ))}
          </svg>
        </div>
      )}

      {!error && !loading && ids.length < 2 && (
        <p className="muted">Necesitas al menos 2 participantes que hayan completado el cuestionario.</p>
      )}
    </div>
  )
}
