import type { Tip } from '../types'

/**
 * ------------------------------------------------------------------
 * TRUCOS
 * ------------------------------------------------------------------
 * Cada tip se muestra dentro del módulo que dice `module`.
 * Para agregar uno: copia un objeto y cambia id/module/title/body.
 */
export const TIPS: Tip[] = [
  // ------------------------------------------------------------ hats / ritmo
  {
    id: 'hats-velocity',
    module: 'rhythms',
    title: 'Velocities alternadas en los hats',
    body: 'Hats en 1/16 todos al mismo volumen = máquina. Alterna fuerte-suave-medio-suave y de golpe suena tocado por alguien. Es el truco más barato y el que más cambia el beat.',
    tags: ['hats', 'humanizar', 'trap'],
  },
  {
    id: 'hats-ramp',
    module: 'rhythms',
    title: 'Rampa antes del cambio de sección',
    body: 'En los últimos 2 compases antes del drop, sube la velocity de los hats progresivamente de suave a fuerte. El oído lee "algo va a pasar" sin que agregues nada nuevo.',
    tags: ['hats', 'transiciones', 'arreglo'],
  },
  {
    id: 'hats-rolls',
    module: 'rhythms',
    title: 'Rolls 1/16 → 1/32',
    body: 'Un roll no es "muchas notas": es una duplicación de velocidad. Ve de 1/16 a 1/32 (y si quieres 1/64 al final) en el último tiempo del compás 8 o 16. Bájale velocity al principio del roll y súbela al final.',
    tags: ['hats', 'fills', 'trap'],
  },
  {
    id: 'hats-triplets',
    module: 'rhythms',
    title: 'Tresillos sueltos, no constantes',
    body: 'Un compás normal en 1/16 y uno con tresillos suena a drill. Cuatro compases de tresillos seguidos suenan a error. En FL: cambia el snap a 1/6 o 1/12 solo para esos hats.',
    tags: ['hats', 'drill', 'FL'],
  },
  {
    id: 'tune-drums',
    module: 'rhythms',
    title: 'Afina el snare y el 808 a la tonalidad',
    body: 'El 808 es un instrumento melódico: tiene que tocar la fundamental de la tonalidad (y seguir la raíz de cada acorde). El snare también tiene tono — súbelo o bájalo hasta que deje de pelear con el beat. Un beat en F#m con un 808 en C suena mal y no vas a saber por qué.',
    tags: ['808', 'afinación', 'mezcla'],
  },
  {
    id: 'ghost-snares',
    module: 'rhythms',
    title: 'Ghost notes en la caja',
    body: 'Una caja a velocity muy baja (nivel suave) entre los golpes fuertes llena el hueco sin robar protagonismo. En boom bap es obligatorio; en trap, opcional pero se nota.',
    tags: ['snare', 'humanizar'],
  },
  {
    id: 'kick-808-clash',
    module: 'rhythms',
    title: 'El kick y el 808 no van juntos',
    body: 'Si el kick y el 808 caen en el mismo step y ambos son graves, se cancelan y pierdes pegada. O los separas en el tiempo, o le haces sidechain al 808 con el kick.',
    tags: ['808', 'mezcla'],
  },

  // ------------------------------------------------------------ acordes
  {
    id: 'voicing-space',
    module: 'chords',
    title: 'No apiles todo en la misma octava',
    body: 'Cuatro notas pegadas en el registro grave = barro. Sube la séptima y la novena una octava y deja la fundamental sola abajo. En el piano roll: separa los bloques verticalmente.',
    tags: ['voicing', 'mezcla'],
  },
  {
    id: 'shell-voicing',
    module: 'chords',
    title: 'Shell voicing cuando hay 808 y voz',
    body: 'Fundamental + tercera + séptima ya dicen qué acorde es. Todo lo demás compite con el bajo y con la voz. Si el beat suena lleno pero apagado, quítale notas a los acordes antes de tocar el EQ.',
    tags: ['voicing', 'arreglo'],
  },
  {
    id: 'inversions-movement',
    module: 'chords',
    title: 'Inversiones para que la mano no salte',
    body: 'Entre dos acordes seguidos, elige la inversión que deje más notas comunes en el mismo sitio. Menos salto = más suena a canción y menos a ejercicio.',
    tags: ['voicing', 'progresiones'],
  },

  // ------------------------------------------------------------ progresiones
  {
    id: 'loop-4-bars',
    module: 'progressions',
    title: 'Cuatro compases y ya',
    body: 'Casi todo el urbano vive en loops de 4 compases. Si tu progresión aburre, no la alargues: cámbiale el voicing, la inversión o el ritmo de los acordes.',
    tags: ['arreglo', 'loop'],
  },
  {
    id: 'jazzify-carefully',
    module: 'progressions',
    title: 'Jazzificar no es siempre mejor',
    body: 'Las séptimas añaden nostalgia y quitan pegada. En una progresión de reggaetón puro, las triadas secas suelen funcionar mejor. Compara A/B antes de dejarlo.',
    tags: ['armonía', 'género'],
  },
  {
    id: 'chord-rhythm',
    module: 'progressions',
    title: 'El ritmo del acorde importa más que el acorde',
    body: 'La misma progresión con acordes largos suena a balada y con stabs cortos en contratiempo suena a reggaetón. Antes de cambiar de acordes, cambia cuándo entran.',
    tags: ['arreglo', 'groove'],
  },

  // ------------------------------------------------------------ tonalidad
  {
    id: 'key-choice',
    module: 'circle',
    title: 'Elige la tonalidad por el 808, no por la teoría',
    body: 'Las tonalidades graves (F#m, Gm, Am) dejan el 808 en un registro que se oye en teléfono. Si eliges Ebm agudo o muy grave, revisa que la fundamental del 808 no se pierda.',
    tags: ['tonalidad', '808'],
  },
  {
    id: 'modulate-neighbors',
    module: 'circle',
    title: 'Modula a las vecinas',
    body: 'Las tonalidades pegadas en el círculo comparten seis de siete notas. Saltar a una vecina o a la relativa se oye natural; saltar al lado opuesto del círculo se oye a error.',
    tags: ['tonalidad', 'modulación'],
  },
  {
    id: 'borrow-V',
    module: 'circle',
    title: 'El V mayor en tonalidad menor',
    body: 'En menor natural el quinto grado es menor (v) y resuelve flojo. Súbele la tercera para convertirlo en V mayor: eso es la menor armónica y es lo que se usa el 90% del tiempo. Ojo: eso también convierte el VII en vii°.',
    tags: ['armonía', 'menor'],
  },

  // ------------------------------------------------------------ general
  {
    id: 'reference-track',
    module: 'general',
    title: 'Ten siempre una referencia sonando',
    body: 'Carga un track de Eladio o Rels B en un canal aparte, bájale el volumen al de tu beat y alterna. Diez segundos de comparación valen más que una hora de EQ a ciegas.',
    tags: ['mezcla', 'flujo'],
  },
  {
    id: 'finish-loops',
    module: 'general',
    title: 'Loop de 8 compases antes de tocar un plugin',
    body: 'Termina la idea musical primero: acordes, drums, bajo, melodía. La mezcla no arregla una idea floja, pero una idea buena aguanta una mezcla mediocre.',
    tags: ['flujo'],
  },
]

export function tipsFor(module: Tip['module']): Tip[] {
  return TIPS.filter((t) => t.module === module)
}
