/**
 * Contratos de datos de BEATSHEET.
 * Todo el contenido de src/data/ tipa contra estas interfaces.
 * Si agregas contenido y TypeScript no se queja, el contenido es válido.
 */

export type Mode = 'major' | 'minor'

/** Nombre de nota con alteración: 'C', 'F#', 'Bb', 'Cb'... */
export type NoteName = string

// ---------------------------------------------------------------- Acordes

export type ChordFamily = 'triada' | 'septima' | 'novena' | 'sus' | 'color'

/** Definición de una calidad de acorde: intervalos en semitonos desde la fundamental. */
export interface ChordQuality {
  id: string
  /** Sufijo de cifrado que se pega a la root: Am7 -> 'm7' */
  symbol: string
  /** Nombre legible en español */
  name: string
  /** Semitonos desde la root, incluyendo el 0 */
  intervals: number[]
  /** Una línea de sabor, la que se muestra junto al toggle */
  flavor: string
  family: ChordFamily
  /** Si aplica solo sobre base mayor, solo menor, o ambas */
  base: 'major' | 'minor' | 'both'
}

/** Un acorde ya resuelto a notas concretas. */
export interface ResolvedChord {
  /** Nombre completo de cifrado, p.ej. 'F#m9' */
  symbol: string
  root: NoteName
  /** MIDI notes ordenadas de grave a agudo */
  midi: number[]
}

// ---------------------------------------------------------------- Grados

export interface DiatonicDegree {
  /** Índice 0-6 dentro de la escala */
  index: number
  /** Cifrado romano: 'I', 'ii', 'vii°', 'V'... */
  roman: string
  /** Cifrado real en la tonalidad activa: 'Bbmaj7' */
  symbol: string
  root: NoteName
  quality: 'major' | 'minor' | 'dim' | 'aug'
  /** Semitonos desde la root del acorde (triada) */
  intervals: number[]
  /** Semitonos de la versión con séptima diatónica */
  seventhIntervals: number[]
  /** Cifrado de la versión con séptima: 'Bbmaj7' */
  seventhSymbol: string
}

// ---------------------------------------------------------------- Progresiones

export interface Progression {
  id: string
  name: string
  /** Modo en el que están escritos los grados */
  mode: Mode
  /** Cifrado romano, un acorde por compás: ['i','VI','III','VII'] */
  degrees: string[]
  genres: string[]
  /** Una línea de contexto */
  note: string
  /** Si la progresión pide séptimas por definición (ii–V–I), arranca jazzificada */
  sevenths?: boolean
}

// ---------------------------------------------------------------- Ritmos

export type DrumVoice = 'kick' | 'snare' | 'clap' | 'hatClosed' | 'hatOpen' | 'sub808'

/** 0 = off, 1 = suave, 2 = medio, 3 = fuerte */
export type Velocity = 0 | 1 | 2 | 3

export type StepCount = 16 | 32

export interface RhythmPattern {
  id: string
  name: string
  genre: string
  /** 16 = un compás de 1/16. 32 = dos compases de 1/16. */
  steps: StepCount
  /** BPM sugerido al cargar el preset */
  bpm: number
  /** Rango típico del género */
  bpmRange: [number, number]
  /** Dos líneas de contexto máximo */
  note: string
  /** De dónde sale el patrón — trazabilidad, se muestra en la UI */
  source: string
  /** Cada voz: array de velocities de longitud `steps` */
  tracks: Record<DrumVoice, Velocity[]>
}

// ---------------------------------------------------------------- Tips

export type TipModule = 'rhythms' | 'chords' | 'progressions' | 'circle' | 'general'

export interface Tip {
  id: string
  module: TipModule
  title: string
  body: string
  tags: string[]
}
