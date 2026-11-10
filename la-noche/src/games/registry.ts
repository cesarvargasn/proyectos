/**
 * Registro estático de los 16 juegos (spine, fase 1).
 * El engine real (GameDefinition completo) llega en fase 2.
 * wave: orden de construcción del plan (3=Wave1 ... 7=Wave4).
 */
export interface GameMeta {
  id: string
  nameEs: string
  tagline: string
  accent: string
  minPlayers: number
  maxPlayers: number
  available: boolean // false = "próximamente" en el grid
}

export const GAMES: GameMeta[] = [
  { id: 'la-ruleta', nameEs: 'La Ruleta', tagline: 'Cartas sin piedad', accent: '#C792EA', minPlayers: 3, maxPlayers: 20, available: true },
  { id: 'impostor', nameEs: 'Impostor', tagline: 'Uno no sabe la palabra', accent: '#5CB8FF', minPlayers: 4, maxPlayers: 12, available: true },
  // rename 026: "Tres Rondas" confundía — es charadas, se llama Charadas (id interno queda)
  { id: 'tres-rondas', nameEs: 'Charadas', tagline: 'Describe. Una palabra. Actúa.', accent: '#FF5C47', minPlayers: 4, maxPlayers: 16, available: true },
  { id: 'parejas-a-gritos', nameEs: 'Parejas a Gritos', tagline: '45 segundos de caos', accent: '#7ED957', minPlayers: 6, maxPlayers: 20, available: true },
  { id: 'lobos', nameEs: 'Lobos', tagline: 'La aldea duerme…', accent: '#C792EA', minPlayers: 6, maxPlayers: 20, available: true },
  { id: 'dos-cuartos', nameEs: 'Dos Cuartos y la Bomba', tagline: 'Rehenes y pánico', accent: '#FF5C47', minPlayers: 6, maxPlayers: 20, available: true },
  // RETIRADOS 023 (decisión de César tras la fiesta del 2026-07-25): El Rey
  // sobrecomplicaba, Mentiras y La Manada no enganchaban. RETIRADOS 026:
  // Batalla de Frases (ocurrencias) y Sin Filtro. No salen del lobby como
  // "próximamente" porque no van a volver solos: revivir uno = volver a
  // listarlo aquí, registrarlo en engine/gameRegistry y devolverle su rama en
  // los dispatchers. Sus módulos y migraciones siguen en el repo.
  //
  // BASES DE DATOS 025: Yo Nunca, Verdad o Reto y El Más Probable (que
  // absorbió a Paranoia) ya NO son juegos — son bancos de prompts que el
  // admin consulta y cura en /cartas. Prueba (test del motor) se borró.
]
