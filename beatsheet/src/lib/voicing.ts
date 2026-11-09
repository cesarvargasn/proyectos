/**
 * Voice leading barato: elige la inversión/octava de cada acorde que menos
 * se mueva respecto al anterior. Es lo que hace que una progresión suene a
 * canción y no a alguien pulsando bloques sueltos.
 */
function rotations(midi: number[]): number[][] {
  const out: number[][] = []
  for (let inv = 0; inv < midi.length; inv++) {
    const c = [...midi]
    for (let i = 0; i < inv; i++) {
      const low = c.shift()
      if (low === undefined) break
      c.push(low + 12)
    }
    for (const shift of [-12, 0, 12]) {
      out.push(c.map((n) => n + shift).sort((a, b) => a - b))
    }
  }
  return out
}

function center(midi: number[]): number {
  return midi.reduce((a, b) => a + b, 0) / midi.length
}

/** Distancia entre dos voicings: media de las alturas + nota más grave. */
function distance(a: number[], b: number[]): number {
  return Math.abs(center(a) - center(b)) + Math.abs(a[0] - b[0]) * 0.35
}

/** Rango cómodo para acordes: ni retumbando ni en el registro de la melodía. */
const LOW = 52 // E3
const HIGH = 79 // G5

export function smoothVoicings(chords: number[][]): number[][] {
  if (chords.length === 0) return []
  const out: number[][] = [chords[0]]
  for (let i = 1; i < chords.length; i++) {
    const prev = out[i - 1]
    const candidates = rotations(chords[i]).filter(
      (c) => c[0] >= LOW && c[c.length - 1] <= HIGH,
    )
    const pool = candidates.length > 0 ? candidates : rotations(chords[i])
    let best = pool[0]
    let bestD = distance(prev, best)
    for (const c of pool.slice(1)) {
      const d = distance(prev, c)
      if (d < bestD) {
        best = c
        bestD = d
      }
    }
    out.push(best)
  }
  return out
}
