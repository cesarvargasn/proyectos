import type { DiatonicDegree } from '../types'
import { buildChord, midiToName } from './theory'

/**
 * Construcción de acordes sobre un grado diatónico.
 *
 * La séptima y la novena que se añaden son las *diatónicas*: no hay que elegir
 * entre maj7/m7/dom7 a mano, la tonalidad ya decide cuál toca. Es lo que hace
 * que esto funcione como chuleta y no como calculadora.
 */
export interface ChordOptions {
  seventh: boolean
  ninth: boolean
  sixth: boolean
  sus: 'none' | 'sus2' | 'sus4'
  shell: boolean
  inversion: 0 | 1 | 2
  octave: number
  /**
   * Cómo escribir el bajo de las inversiones. Lo decide la armadura de la
   * tonalidad, no el acorde: el 3er grado de Cm es Eb, nunca D#.
   */
  preferFlats?: boolean
}

export const DEFAULT_OPTIONS: ChordOptions = {
  seventh: false,
  ninth: false,
  sixth: false,
  sus: 'none',
  shell: false,
  inversion: 0,
  octave: 4,
}

export interface BuiltNote {
  /** Semitonos desde la fundamental, antes de invertir (0, 3, 7, 10, 14…) */
  interval: number
  midi: number
}

export interface BuiltChord {
  /** Semitonos desde la root, ascendente y sin repetidos */
  intervals: number[]
  /** Cifrado completo, con bajo si hay inversión: 'Am9/C' */
  symbol: string
  /** Cifrado sin el bajo de la inversión */
  baseSymbol: string
  /** Notas MIDI ya invertidas, ascendentes */
  midi: number[]
  /** Igual que `midi` pero conservando qué intervalo es cada nota */
  notes: BuiltNote[]
}

function thirdOf(d: DiatonicDegree, o: ChordOptions): number {
  if (o.sus === 'sus2') return 2
  if (o.sus === 'sus4') return 5
  return d.intervals[1]
}

function buildIntervals(d: DiatonicDegree, o: ChordOptions): number[] {
  const third = thirdOf(d, o)
  const fifth = d.intervals[2] // ojo: en los grados disminuidos esto es 6, y debe seguir siéndolo
  const seventh = d.seventhIntervals[3]

  // Shell = solo lo que define el acorde: fundamental, tercera y séptima.
  if (o.shell) return [0, third, seventh]

  const out = new Set<number>([0, third, fifth])
  if (o.seventh) out.add(seventh)
  // La 6 y la 7 se pelean: si hay séptima, la sexta se ignora.
  if (o.sixth && !o.seventh) out.add(9)
  if (o.ninth) out.add(14)

  return [...out].sort((a, b) => a - b)
}

function buildSymbol(d: DiatonicDegree, o: ChordOptions): string {
  const triadSuffix = d.symbol.slice(d.root.length) // '', 'm', 'dim'
  const seventhSuffix = d.seventhSymbol.slice(d.root.length) // 'maj7', 'm7', '7', 'm7b5', 'dim7'

  const withShell = (s: string) => (o.shell ? `${s} shell` : s)

  if (o.sus !== 'none') {
    const sev = o.seventh ? (seventhSuffix.includes('maj') ? 'maj7' : '7') : ''
    return withShell(`${d.root}${sev}${o.sus}`)
  }

  if (o.seventh || o.shell) {
    // maj7 -> maj9 · m7 -> m9 · 7 -> 9 · m7b5 -> m9b5
    const s = o.ninth ? seventhSuffix.replace('7', '9') : seventhSuffix
    return withShell(`${d.root}${s}`)
  }

  let s = triadSuffix
  if (o.sixth) s += '6'
  if (o.ninth) s += '(add9)'
  return `${d.root}${s}`
}

export function buildDegreeChord(d: DiatonicDegree, o: ChordOptions): BuiltChord {
  const intervals = buildIntervals(d, o)
  const raw = buildChord(d.root, intervals, o.octave)

  // Invertir = subir las notas graves una octava, manteniendo la etiqueta
  // de intervalo pegada a cada nota (si no, el piano roll miente).
  const notes: BuiltNote[] = intervals.map((interval, i) => ({ interval, midi: raw[i] }))
  const inversion = Math.min(o.inversion, notes.length - 1)
  for (let i = 0; i < inversion; i++) {
    const low = notes.shift()
    if (!low) break
    notes.push({ interval: low.interval, midi: low.midi + 12 })
  }
  notes.sort((a, b) => a.midi - b.midi)

  const midi = notes.map((n) => n.midi)
  const baseSymbol = buildSymbol(d, o)

  const preferFlats = o.preferFlats ?? d.root.includes('b')
  const bass = midiToName(midi[0], preferFlats).replace(/-?\d+$/, '')
  const rootName = midiToName(raw[0], preferFlats).replace(/-?\d+$/, '')
  const symbol = inversion > 0 && bass !== rootName ? `${baseSymbol}/${bass}` : baseSymbol

  return { intervals, symbol, baseSymbol, midi, notes }
}

/** Etiqueta corta del intervalo, para los bloques del piano roll. */
export function intervalLabel(semis: number): string {
  const map: Record<number, string> = {
    0: '1',
    2: '2',
    3: 'b3',
    4: '3',
    5: '4',
    6: 'b5',
    7: '5',
    8: '#5',
    9: '6',
    10: 'b7',
    11: '7',
    14: '9',
  }
  return map[semis] ?? `${semis}st`
}
