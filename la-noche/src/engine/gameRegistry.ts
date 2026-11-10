import type { GameDefinition, GameState } from './types'
import { ruletaGame } from '../games/la-ruleta'
import { impostorGame } from '../games/impostor'
import { tresRondasGame } from '../games/tres-rondas'
import { parejasGame } from '../games/parejas-a-gritos'
import { lobosGame } from '../games/lobos'
import { dosCuartosGame } from '../games/dos-cuartos'

/**
 * game_type → módulo del juego. Cada juego nuevo se registra aquí
 * (y se marca available:true en games/registry.ts para que salga en el lobby).
 * El estado concreto de cada juego se valida dentro de su módulo, no aquí.
 *
 * 025: los bancos (Yo Nunca, Verdad o Reto, El Más Probable + Paranoia
 * fusionada) dejaron de ser juegos — viven como base de datos en /cartas.
 * Prueba se borró. Retirados (módulos quedan en src/games/ como historia):
 * El Rey, Mentiras, La Manada (023) + Batalla de Frases y Sin Filtro (026).
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const GAME_DEFS: Record<string, GameDefinition<any>> = {
  'la-ruleta': ruletaGame,
  impostor: impostorGame,
  'tres-rondas': tresRondasGame,
  'parejas-a-gritos': parejasGame,
  lobos: lobosGame,
  'dos-cuartos': dosCuartosGame,
}

export function getGameDef(gameType: string): GameDefinition<GameState> | null {
  return GAME_DEFS[gameType] ?? null
}
