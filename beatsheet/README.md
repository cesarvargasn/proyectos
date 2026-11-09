# BEATSHEET

Cheat sheet interactiva de producción musical para FL Studio. Teoría, ritmos y trucos,
todo dibujado como piano roll y grid — porque eso es lo que se replica en el DAW.
El audio está, pero es secundario: para oír de verdad está FL.

No es un curso. Es la chuleta que abres en el segundo monitor mientras produces.

---

## Correr el proyecto

```bash
npm install
npm run dev      # http://localhost:5173
npm run build    # bundle de producción en dist/
npm run preview  # sirve dist/ localmente
npm run typecheck
```

Requiere Node 18+. Chrome desktop es el navegador objetivo.

**El audio necesita un gesto del usuario:** el primer click en "Activar audio" (o en cualquier
botón de play) arranca el `AudioContext`. Es una restricción del navegador, no un bug.

---

## Cómo agregar contenido

Todo el contenido vive en `src/data/`. Agregar cosas es agregar objetos a arrays;
TypeScript valida la forma. No hay que tocar componentes.

### Una progresión → `src/data/progressions.ts`

```ts
{
  id: 'i-iv-v',                       // único
  name: 'i – iv – v',
  mode: 'minor',                      // en qué modo se leen los grados
  degrees: ['i', 'iv', 'v'],          // un grado = un compás
  genres: ['bolero', 'trap'],
  note: 'Una línea de contexto.',
  sevenths: true,                     // opcional: arranca jazzificada
}
```

Los grados se escriben en cifrado romano: **mayúscula = mayor, minúscula = menor, `°` = disminuido**.
Se resuelven contra la tonalidad global, así que se escriben una sola vez.

Detalle importante: si escribes `V` en una progresión menor, el módulo usa automáticamente
el V mayor de la menor armónica; si escribes `VII`, respeta el VII natural.

### Un ritmo → `src/data/rhythms.ts`

Los patrones se escriben como texto para poder leerlos de un vistazo:

```
'.' = off   '1' = suave   '2' = medio   '3' = fuerte   '|' = separador (se ignora)
```

```ts
{
  id: 'mi-ritmo',
  name: 'Mi ritmo',
  genre: 'Trap latino',
  steps: 16,                  // 16 = un compás de 1/16. 32 = dos compases.
  bpm: 95,
  bpmRange: [92, 100],
  note: 'Dos líneas máximo de contexto.',
  source: 'De dónde sale el patrón — se muestra en la UI.',
  tracks: tracks(16, {
    kick:      '3...|3...|3...|3...',
    snare:     '...3|..3.|...3|..3.',
    hatClosed: '2.1.|2.1.|2.1.|2.1.',
    // las voces que no pongas quedan vacías
  }),
}
```

Cada cadena debe tener tantos steps como diga `steps`. Si no cuadra, la consola lo grita en dev
(`validateRhythms()`).

Voces disponibles: `kick`, `snare`, `clap`, `hatClosed`, `hatOpen`, `sub808`.

### Un truco → `src/data/tips.ts`

```ts
{
  id: 'mi-truco',
  module: 'rhythms',    // rhythms | chords | progressions | circle | general
  title: 'Título corto',
  body: 'El truco, directo, sin párrafo académico.',
  tags: ['hats', 'mezcla'],
}
```

Aparece automáticamente en el módulo que diga `module`.

### Una calidad de acorde → `src/data/chords.ts`

```ts
{
  id: 'm11',
  symbol: 'm11',              // sufijo que se pega a la fundamental
  name: 'Oncena menor',
  intervals: [0, 3, 7, 10, 17],  // semitonos desde la fundamental
  flavor: 'Una línea de sabor.',
  family: 'novena',
  base: 'minor',
}
```

Esto la agrega a la tabla de referencia (el desplegable del módulo de tonalidad).
Si además quieres un **toggle** para construirla sobre los grados, hay que tocar
`src/lib/chordSpec.ts` (`ChordOptions` + `buildIntervals` + `buildSymbol`).

---

## Estructura

```
src/
  audio/engine.ts        Único punto de contacto con Tone.js. Synth, batería,
                         transport compartido, loops. Nadie más habla con Tone.
  data/                  TODO el contenido. Progresiones, ritmos, acordes, trucos.
  lib/
    theory.ts            Teoría: escalas deletreadas, armaduras, grados diatónicos,
                         círculo de quintas, MIDI. Fuente de verdad musical.
    chordSpec.ts         Extensiones sobre un grado diatónico (7/9/6/sus/shell/inversión).
    voicing.ts           Voice leading (elegir inversiones que no salten).
    useLocalStorage.ts   Persistencia de preferencias y notas.
    useTransport.ts      Hooks de "quién está sonando".
  state/MusicContext.tsx Estado global: tonalidad + BPM, persistidos.
  components/            PianoRoll, Header, NotesPanel, TipList.
  modules/
    registry.ts          La navegación por tabs. Agregar módulo = agregar entrada.
    CircleOfFifths.tsx   Círculo + grados + constructor de acordes + piano roll.
    Rhythms.tsx
    Progressions.tsx
```

### Por qué el constructor de acordes vive dentro del círculo

Elegir la tonalidad, ver sus siete grados y construir uno de ellos son el mismo gesto.
Al clicar un grado se selecciona, y los toggles de extensión operan sobre él: la séptima y
la novena que se añaden son las **diatónicas**, así que no hay que elegir entre maj7 y m7 —
el grado ya lo decide. El resultado se dibuja como piano roll, que es lo que se replica en FL.

### Agregar un módulo nuevo (Fase 2)

1. `src/modules/MiModulo.tsx` con `export default function MiModulo() { … }`
2. Una entrada en `src/modules/registry.ts`

Nada más. El lazy loading, el tab y el "parar el audio al cambiar de tab" ya están.

---

## Reglas de audio

El audio es **secundario**: sirve para una comprobación rápida de oído, no es el producto.
Lo que importa es lo que se ve — el piano roll y las grids —, porque el sonido de verdad
sale de FL. Por eso los botones de play son pequeños y están fuera del camino.

- Un solo `Tone.Transport`. **Solo un módulo suena a la vez**: darle play a algo detiene lo
  anterior y el botón del módulo anterior se resetea solo (`useIsPlaying`).
- Los loops leen el estado con getters (`getTracks()`, `getChords()`), no con closures.
  Por eso puedes editar velocities o activar "jazzificar" sin parar la reproducción.
- Todo es síntesis, sin samples: `PolySynth` para armonía, `MembraneSynth`/`NoiseSynth`
  para batería. Suena decente, no realista — es una chuleta, no un beat final.
- El 808 se afina a la tonalidad global.

## Estado global

Tonalidad (fundamental + modo) y BPM viven en `MusicContext` y se persisten en `localStorage`
bajo el prefijo `beatsheet:`. Cambiar la tonalidad en el círculo de quintas la cambia en todos
los módulos.

Las notas personales de cada módulo también van a `localStorage` (`beatsheet:notes:<módulo>`).
Son locales a este navegador: no se sincronizan ni salen de la máquina.

---

## Deploy

Es un sitio estático. En Vercel: framework **Vite**, build `npm run build`, output `dist`.
Sin variables de entorno ni backend.

## Fase 2 — backlog

Melodías (chord tones vs notas de paso), arreglo/estructura por género, mixing
(mapa de frecuencias), FL hacks filtrables y export MIDI. Nada de eso está implementado;
la arquitectura ya lo admite sin tocar los módulos existentes.
