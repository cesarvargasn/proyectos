import type { Progression } from '../types'

/**
 * ------------------------------------------------------------------
 * PROGRESIONES
 * ------------------------------------------------------------------
 * Un acorde por compás. Los grados van en cifrado romano y se resuelven
 * contra la tonalidad global, así que se escriben una sola vez.
 *
 * Convención: mayúscula = acorde mayor, minúscula = menor, ° = disminuido.
 * `mode` dice en qué modo está pensada (los grados se leen sobre esa escala).
 *
 * Para agregar una: copia un objeto, cambia id/name/degrees. Nada más.
 */
export const PROGRESSIONS: Progression[] = [
  {
    id: 'i-VI-III-VII',
    name: 'i – VI – III – VII',
    mode: 'minor',
    degrees: ['i', 'VI', 'III', 'VII'],
    genres: ['trap', 'emo rap', 'pop urbano'],
    note: 'La de trap/emo: funciona para todo. Si no sabes por dónde empezar, empieza aquí.',
  },
  {
    id: 'i-VII-VI-V',
    name: 'i – VII – VI – V (andaluza)',
    mode: 'minor',
    degrees: ['i', 'VII', 'VI', 'V'],
    genres: ['flamenco', 'trap latino', 'Rels B'],
    note: 'Cadencia andaluza: baja por grados y el V mayor la deja pidiendo repetir. Oscura y española.',
  },
  {
    id: 'i-iv-VI-V',
    name: 'i – iv – VI – V',
    mode: 'minor',
    degrees: ['i', 'iv', 'VI', 'V'],
    genres: ['reggaetón', 'trap latino'],
    note: 'Reggaetón menor con dramatismo: el iv la pone triste y el V la empuja de vuelta al i.',
  },
  {
    id: 'i-VI-VII-i',
    name: 'i – VI – VII – i',
    mode: 'minor',
    degrees: ['i', 'VI', 'VII', 'i'],
    genres: ['reggaetón', 'dancehall'],
    note: 'Circular: nunca sale del menor. Ideal para loops de 4 compases que no cansan.',
  },
  {
    id: 'I-V-vi-IV',
    name: 'I – V – vi – IV',
    mode: 'major',
    degrees: ['I', 'V', 'vi', 'IV'],
    genres: ['pop', 'pop urbano'],
    note: 'La progresión de pop más usada de la historia. Suena a hit porque ya lo fue mil veces.',
  },
  {
    id: 'vi-IV-I-V',
    name: 'vi – IV – I – V',
    mode: 'major',
    degrees: ['vi', 'IV', 'I', 'V'],
    genres: ['pop', 'baladas'],
    note: 'La misma de arriba empezando en el vi: mismos acordes, sensación melancólica.',
  },
  {
    id: 'ii-V-I',
    name: 'ii7 – V7 – Imaj7',
    mode: 'major',
    degrees: ['ii', 'V', 'I'],
    genres: ['jazz', 'neo-soul', 'bossa'],
    sevenths: true,
    note: 'El saludo del jazz. Va con séptimas siempre: sin ellas no es un ii–V–I, son tres triadas sueltas.',
  },
  {
    id: 'I-vi-IV-V',
    name: 'I – vi – IV – V',
    mode: 'major',
    degrees: ['I', 'vi', 'IV', 'V'],
    genres: ['doo-wop', 'balada', 'oldies'],
    note: 'Doo-wop de los 50. Con un beat de trap encima suena a sample viejo.',
  },
]

export const PROGRESSION_BY_ID: Record<string, Progression> = Object.fromEntries(
  PROGRESSIONS.map((p) => [p.id, p]),
)
