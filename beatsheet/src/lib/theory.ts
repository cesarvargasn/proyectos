import type { DiatonicDegree, Mode, NoteName } from '../types'

// ------------------------------------------------------------------ básicos

const LETTERS = ['C', 'D', 'E', 'F', 'G', 'A', 'B'] as const
const LETTER_PC: Record<string, number> = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 }

export const MAJOR_STEPS = [0, 2, 4, 5, 7, 9, 11]
export const MINOR_STEPS = [0, 2, 3, 5, 7, 8, 10]

/** 'F#' -> 6, 'Cb' -> 11 */
export function parseNote(name: NoteName): number {
  const letter = name[0].toUpperCase()
  let acc = 0
  for (const ch of name.slice(1)) {
    if (ch === '#') acc += 1
    else if (ch === 'b' || ch === '♭') acc -= 1
  }
  return (((LETTER_PC[letter] ?? 0) + acc) % 12 + 12) % 12
}

function accidentalString(diff: number): string {
  return diff > 0 ? '#'.repeat(diff) : 'b'.repeat(-diff)
}

/**
 * Deletrea la escala respetando el alfabeto musical: una letra por grado.
 * Ebm -> Eb F Gb Ab Bb Cb Db (y no Eb F F# G# A# B C#).
 */
export function spellScale(tonic: NoteName, mode: Mode): NoteName[] {
  const steps = mode === 'major' ? MAJOR_STEPS : MINOR_STEPS
  const tonicPc = parseNote(tonic)
  const startIdx = LETTERS.indexOf(tonic[0].toUpperCase() as (typeof LETTERS)[number])
  return steps.map((semis, i) => {
    const letter = LETTERS[(startIdx + i) % 7]
    const target = (tonicPc + semis) % 12
    let diff = (((target - LETTER_PC[letter]) % 12) + 12) % 12
    if (diff > 6) diff -= 12
    return letter + accidentalString(diff)
  })
}

/** Pitch classes (0-11) de la escala, en orden de grados. */
export function scalePitchClasses(tonic: NoteName, mode: Mode): number[] {
  const steps = mode === 'major' ? MAJOR_STEPS : MINOR_STEPS
  const tonicPc = parseNote(tonic)
  return steps.map((s) => (tonicPc + s) % 12)
}

// ------------------------------------------------------------------ armadura

const SHARP_ORDER = ['F#', 'C#', 'G#', 'D#', 'A#', 'E#', 'B#']
const FLAT_ORDER = ['Bb', 'Eb', 'Ab', 'Db', 'Gb', 'Cb', 'Fb']

export interface KeySignature {
  count: number
  kind: '#' | 'b' | ''
  /** Las alteraciones concretas, en orden canónico */
  notes: NoteName[]
  /** 'Fm = 4 bemoles (Bb Eb Ab Db)' */
  text: string
}

/**
 * La armadura se deduce de la propia escala deletreada: para menor natural
 * coincide con la de su relativa mayor, que es exactamente lo que queremos.
 */
export function keySignature(tonic: NoteName, mode: Mode): KeySignature {
  const scale = spellScale(tonic, mode)
  const sharps = scale.filter((n) => n.includes('#'))
  const flats = scale.filter((n) => n.includes('b'))
  if (sharps.length === 0 && flats.length === 0) {
    return { count: 0, kind: '', notes: [], text: 'sin alteraciones (todas teclas blancas)' }
  }
  const kind: '#' | 'b' = sharps.length >= flats.length ? '#' : 'b'
  const order = kind === '#' ? SHARP_ORDER : FLAT_ORDER
  const present = new Set(kind === '#' ? sharps : flats)
  const notes = order.filter((n) => present.has(n))
  const word = kind === '#' ? 'sostenido' : 'bemol'
  const plural = notes.length === 1 ? word : word + 'es'
  return {
    count: notes.length,
    kind,
    notes,
    text: `${notes.length} ${plural} (${notes.join(' ')})`,
  }
}

// ------------------------------------------------------------------ acordes

export type TriadQuality = 'major' | 'minor' | 'dim' | 'aug'

export const TRIAD_INTERVALS: Record<TriadQuality, number[]> = {
  major: [0, 4, 7],
  minor: [0, 3, 7],
  dim: [0, 3, 6],
  aug: [0, 4, 8],
}

const TRIAD_SUFFIX: Record<TriadQuality, string> = {
  major: '',
  minor: 'm',
  dim: 'dim',
  aug: 'aug',
}

function triadQuality(third: number, fifth: number): TriadQuality {
  if (third === 4 && fifth === 8) return 'aug'
  if (third === 4) return 'major'
  if (third === 3 && fifth === 6) return 'dim'
  return 'minor'
}

const ROMAN = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII']

function romanFor(index: number, quality: TriadQuality): string {
  const base = ROMAN[index]
  switch (quality) {
    case 'major':
      return base
    case 'aug':
      return base + '+'
    case 'dim':
      return base.toLowerCase() + '°'
    default:
      return base.toLowerCase()
  }
}

/** Sufijo del acorde de séptima según triada + intervalo de séptima. */
function seventhSuffix(quality: TriadQuality, seventh: number): string {
  if (quality === 'major') return seventh === 11 ? 'maj7' : '7'
  if (quality === 'minor') return seventh === 11 ? 'm(maj7)' : 'm7'
  if (quality === 'dim') return seventh === 9 ? 'dim7' : 'm7b5'
  return seventh === 11 ? 'maj7#5' : '7#5'
}

/**
 * Los 7 grados diatónicos de la tonalidad.
 * `harmonicV` sube la sensible en el grado v (menor) para convertirlo en V mayor.
 */
export function diatonicDegrees(
  tonic: NoteName,
  mode: Mode,
  harmonicV = false,
): DiatonicDegree[] {
  const scale = spellScale(tonic, mode)
  const pcs = scalePitchClasses(tonic, mode)
  const raiseSeventh = harmonicV && mode === 'minor'

  return pcs.map((_pc, i) => {
    const pcAt = (deg: number) => {
      const pc = pcs[deg % 7]
      // en menor armónica la sensible (grado 7, índice 6) sube un semitono
      return raiseSeventh && deg % 7 === 6 ? (pc + 1) % 12 : pc
    }
    const nameAt = (deg: number) => {
      const n = scale[deg % 7]
      if (raiseSeventh && deg % 7 === 6) {
        // reescribe la sensible subida: Eb -> E, F -> F#
        const letter = n[0]
        const acc = n.slice(1)
        if (acc.startsWith('b')) return letter + acc.slice(1)
        return letter + acc + '#'
      }
      return n
    }

    // Ojo: en menor armónica el propio grado VII sube, así que la fundamental
    // del acorde tiene que salir de pcAt(i), no del pitch class natural.
    const rootPc = pcAt(i)
    const third = (pcAt(i + 2) - rootPc + 12) % 12
    const fifth = (pcAt(i + 4) - rootPc + 12) % 12
    const seventh = (pcAt(i + 6) - rootPc + 12) % 12
    const quality = triadQuality(third, fifth)
    const root = nameAt(i)

    return {
      index: i,
      roman: romanFor(i, quality),
      symbol: root + TRIAD_SUFFIX[quality],
      root,
      quality,
      intervals: [0, third, fifth],
      seventhIntervals: [0, third, fifth, seventh],
      seventhSymbol: root + seventhSuffix(quality, seventh),
    } satisfies DiatonicDegree
  })
}

// ------------------------------------------------------------------ MIDI

/** Nombre + octava -> nota MIDI. C4 = 60. */
export function noteToMidi(name: NoteName, octave: number): number {
  return 12 * (octave + 1) + parseNote(name)
}

const SHARP_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
const FLAT_NAMES = ['C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B']

export function midiToName(midi: number, preferFlats = false): string {
  const pc = ((midi % 12) + 12) % 12
  const names = preferFlats ? FLAT_NAMES : SHARP_NAMES
  return names[pc] + (Math.floor(midi / 12) - 1)
}

export function isBlackKey(midi: number): boolean {
  const pc = ((midi % 12) + 12) % 12
  return [1, 3, 6, 8, 10].includes(pc)
}

/** Construye las notas MIDI de un acorde a partir de intervalos. */
export function buildChord(root: NoteName, intervals: number[], octave = 4): number[] {
  const base = noteToMidi(root, octave)
  return intervals.map((i) => base + i)
}

/**
 * Invierte un acorde subiendo `n` notas graves una octava.
 * Mantiene el orden ascendente para dibujar el piano roll.
 */
export function invertChord(midi: number[], inversion: number): number[] {
  const out = [...midi]
  for (let i = 0; i < inversion; i++) {
    const low = out.shift()
    if (low === undefined) break
    out.push(low + 12)
  }
  return out.sort((a, b) => a - b)
}

// ------------------------------------------------------------------ círculo

export interface CircleKey {
  major: NoteName
  minor: NoteName
  /** Nombre alternativo enarmónico si existe (F# / Gb) */
  majorAlt?: NoteName
  minorAlt?: NoteName
}

/** Orden horario desde C, 12 posiciones. */
export const CIRCLE: CircleKey[] = [
  { major: 'C', minor: 'A' },
  { major: 'G', minor: 'E' },
  { major: 'D', minor: 'B' },
  { major: 'A', minor: 'F#' },
  { major: 'E', minor: 'C#' },
  { major: 'B', minor: 'G#' },
  { major: 'F#', minor: 'Eb', majorAlt: 'Gb', minorAlt: 'D#' },
  { major: 'Db', minor: 'Bb' },
  { major: 'Ab', minor: 'F' },
  { major: 'Eb', minor: 'C' },
  { major: 'Bb', minor: 'G' },
  { major: 'F', minor: 'D' },
]

/** Índice en el círculo de una tonalidad (por pitch class + modo). */
export function circleIndexOf(tonic: NoteName, mode: Mode): number {
  const pc = parseNote(tonic)
  return CIRCLE.findIndex((k) => parseNote(mode === 'major' ? k.major : k.minor) === pc)
}

export interface KeyNeighbors {
  relative: { tonic: NoteName; mode: Mode }
  fifthUp: { tonic: NoteName; mode: Mode }
  fifthDown: { tonic: NoteName; mode: Mode }
}

export function keyNeighbors(tonic: NoteName, mode: Mode): KeyNeighbors {
  const idx = circleIndexOf(tonic, mode)
  const at = (i: number) => CIRCLE[((i % 12) + 12) % 12]
  const pick = (k: CircleKey, m: Mode) => ({ tonic: m === 'major' ? k.major : k.minor, mode: m })
  const relMode: Mode = mode === 'major' ? 'minor' : 'major'
  return {
    relative: pick(at(idx), relMode),
    fifthUp: pick(at(idx + 1), mode),
    fifthDown: pick(at(idx - 1), mode),
  }
}

/** Nombre corto para mostrar: 'F#m' / 'Bb'. */
export function keyLabel(tonic: NoteName, mode: Mode): string {
  return mode === 'minor' ? `${tonic}m` : tonic
}

// ------------------------------------------------------------------ romanos

const ROMAN_TO_INDEX: Record<string, number> = {
  I: 0, II: 1, III: 2, IV: 3, V: 4, VI: 5, VII: 6,
}

/** Parsea 'bVII', 'vii°', 'V7' -> índice de grado 0-6 (ignora sufijos). */
export function romanToIndex(roman: string): number {
  const core = roman.replace(/[^ivxIVX]/g, '').toUpperCase()
  return ROMAN_TO_INDEX[core] ?? 0
}
