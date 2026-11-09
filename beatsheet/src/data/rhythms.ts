import type { DrumVoice, RhythmPattern, StepCount, Velocity } from '../types'

/**
 * ------------------------------------------------------------------
 * RITMOS
 * ------------------------------------------------------------------
 * Los patrones se escriben como texto para poder leerlos de un vistazo:
 *   '.' = step apagado
 *   '1' = velocity suave · '2' = media · '3' = fuerte
 *   '|' = separador visual de negras (se ignora)
 *
 * Un compás de 4/4 en 1/16 = 16 steps = 4 grupos de 4.
 *
 * Para agregar un ritmo: copia un objeto, cambia las cadenas. La longitud
 * de cada cadena debe coincidir con `steps` (16 o 32) o salta un error al cargar.
 */

/** Convierte '3...|..2.' en [3,0,0,0,0,0,2,0] */
export function P(pattern: string): Velocity[] {
  return pattern
    .replace(/[\s|]/g, '')
    .split('')
    .map((c) => (c === '.' ? 0 : (Number(c) as Velocity)))
}

const EMPTY16 = '....|....|....|....'
const EMPTY32 = EMPTY16 + EMPTY16

/** Rellena las voces que un preset no usa. */
function tracks(
  steps: StepCount,
  partial: Partial<Record<DrumVoice, string>>,
): Record<DrumVoice, Velocity[]> {
  const empty = steps === 16 ? EMPTY16 : EMPTY32
  const voices: DrumVoice[] = ['kick', 'snare', 'clap', 'hatClosed', 'hatOpen', 'sub808']
  const out = {} as Record<DrumVoice, Velocity[]>
  for (const v of voices) out[v] = P(partial[v] ?? empty)
  return out
}

export const RHYTHMS: RhythmPattern[] = [
  {
    id: 'dembow',
    name: 'Dembow',
    genre: 'Reggaetón',
    steps: 16,
    bpm: 95,
    bpmRange: [92, 97],
    note: 'El patrón que sostiene todo el reggaetón: bombo en cada negra y la caja/rim marcando el 3+3+2 encima. Si el bombo y la caja están bien, el resto es decoración.',
    source: 'Dembow clásico: bombo 1-5-9-13, caja 4-7-12-15 (numeración 1-16 del brief).',
    tracks: tracks(16, {
      kick: '3...|3...|3...|3...',
      snare: '...3|..3.|...3|..3.',
      hatClosed: '2.1.|2.1.|2.1.|2.1.',
      sub808: '3...|....|3...|....',
    }),
  },
  {
    id: 'trap-halftime',
    name: 'Trap halftime',
    genre: 'Trap',
    steps: 16,
    bpm: 140,
    bpmRange: [130, 150],
    note: 'Halftime = la caja cae en el 3, no en el 2 y el 4. El tempo dice 140 pero el cuerpo lo siente a 70. Los hats en 1/16 con velocities alternadas son lo que lo hace respirar.',
    source: 'Convención de trap: kick en 1 + variación, caja/clap en el step 9, hats en 1/16.',
    tracks: tracks(16, {
      kick: '3...|....|..3.|....',
      snare: '....|....|3...|....',
      clap: '....|....|2...|....',
      hatClosed: '3121|3121|3121|3121',
      hatOpen: '....|....|....|..2.',
      sub808: '3...|....|..2.|....',
    }),
  },
  {
    id: 'drill',
    name: 'Drill',
    genre: 'UK / NY Drill',
    steps: 16,
    bpm: 140,
    bpmRange: [138, 145],
    note: 'Cajas desplazadas (una en el 3, otra tarde al final del compás) y hats agrupados 3-3-2, que es lo más cerca del tresillo que se puede dibujar en una grid de 1/16.',
    source: 'Convención de drill. Ojo: los tresillos reales de hats necesitan grid de 1/12 o 1/24; aquí van aproximados como 3+3+2.',
    tracks: tracks(16, {
      kick: '3...|..3.|...3|....',
      snare: '....|....|3...|..2.',
      hatClosed: '3..2|..1.|3..2|..1.',
      sub808: '3...|....|...2|....',
    }),
  },
  {
    id: 'house-4x4',
    name: 'House 4x4',
    genre: 'House',
    steps: 16,
    bpm: 124,
    bpmRange: [120, 128],
    note: 'Bombo en las cuatro negras y hat abierto en los contratiempos: ese "tss" a destiempo es literalmente lo que hace que suene a house y no a pop.',
    source: 'Estándar four-on-the-floor: kick 1-5-9-13, open hat 3-7-11-15, clap en 2 y 4.',
    tracks: tracks(16, {
      kick: '3...|3...|3...|3...',
      clap: '....|3...|....|3...',
      hatOpen: '..2.|..2.|..2.|..2.',
    }),
  },
  {
    id: 'boom-bap',
    name: 'Boom bap',
    genre: 'Hip hop clásico',
    steps: 16,
    bpm: 90,
    bpmRange: [85, 95],
    note: 'Bombo sincopado (no cae en las negras) y caja seca en el 2 y el 4. La gracia está en que el bombo llegue tarde a propósito.',
    source: 'Convención boom bap: caja en steps 5 y 13, bombo sincopado alrededor.',
    tracks: tracks(16, {
      kick: '3...|..2.|..3.|....',
      snare: '....|3...|....|3...',
      hatClosed: '2.1.|2.1.|2.1.|2.1.',
    }),
  },
  {
    id: 'tresillo',
    name: 'Tresillo (3+3+2)',
    genre: 'Latino — base',
    steps: 16,
    bpm: 95,
    bpmRange: [88, 100],
    note: 'El ADN de todo lo latino. Tres golpes que dividen el compás en 3+3+2 corcheas. Reggaetón, dembow, bachata, afrobeat: todos son este patrón disfrazado.',
    source: 'Tresillo cubano / habanera: golpes en el 1, el "y" del 2 y el 4 (steps 1, 7 y 13 de 16).',
    tracks: tracks(16, {
      kick: '3...|..3.|....|3...',
      hatClosed: '1.1.|1.1.|1.1.|1.1.',
    }),
  },
  {
    id: 'clave-son-32',
    name: 'Clave de son 3-2',
    genre: 'Latino — base',
    steps: 32,
    bpm: 95,
    bpmRange: [88, 105],
    note: 'Dos compases, no uno: primero el lado de 3 (el tresillo), luego el lado de 2. Toda la música afrocubana se orienta respecto a esta clave.',
    source: 'Clave de son 3-2: compás 1 en 1, "y" del 2 y 4; compás 2 en 2 y 3.',
    tracks: tracks(32, {
      clap: '3...|..3.|....|3...' + '....|3...|3...|....',
      kick: '3...|....|....|....' + '3...|....|....|....',
      hatClosed: '1.1.|1.1.|1.1.|1.1.' + '1.1.|1.1.|1.1.|1.1.',
    }),
  },
]

export const RHYTHM_BY_ID: Record<string, RhythmPattern> = Object.fromEntries(
  RHYTHMS.map((r) => [r.id, r]),
)

/** Nombres visibles de cada voz, en el orden en que se dibujan las filas. */
export const VOICE_ORDER: DrumVoice[] = ['kick', 'snare', 'clap', 'hatClosed', 'hatOpen', 'sub808']

export const VOICE_LABEL: Record<DrumVoice, string> = {
  kick: 'Kick',
  snare: 'Snare',
  clap: 'Clap',
  hatClosed: 'Hat cerrado',
  hatOpen: 'Hat abierto',
  sub808: '808',
}

/** Valida en dev que cada cadena tenga la longitud declarada. */
export function validateRhythms(): string[] {
  const errors: string[] = []
  for (const r of RHYTHMS) {
    for (const [voice, arr] of Object.entries(r.tracks)) {
      if (arr.length !== r.steps) {
        errors.push(`${r.id}/${voice}: ${arr.length} steps, se esperaban ${r.steps}`)
      }
    }
  }
  return errors
}
