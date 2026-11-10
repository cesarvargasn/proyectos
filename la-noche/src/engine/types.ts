import type { ComponentType } from 'react'
import type { Party, Player } from '../lib/types'

/** Estado JSONB de game_sessions.state. Cada juego lo extiende con sus campos. */
export interface GameState {
  phase: string
  phase_ends_at: string | null
  [key: string]: unknown
}

/**
 * Contexto que el shell (Game.tsx) arma en cada render y pasa a las vistas.
 * Las vistas del juego solo renderizan y llaman act(); nunca hacen fetch propio.
 */
export interface GameCtx<S extends GameState = GameState> {
  partyId: string
  code: string
  players: Player[]
  me: Player
  isHost: boolean
  sessionId: string
  /** settings de la party (mode social|drinking, intensity) — para {drink:N} etc. */
  settings: Party['settings']
  state: S
  /** payload de player_secrets propio; null si el shell no lo pidió (ver needsSecret). */
  secret: Record<string, unknown> | null
  /** submit_action + refetch. Única vía de mutación desde un juego. */
  act: (action: string, payload?: Record<string, unknown>) => Promise<void>
  /** advance_phase + refetch. force=true solo lo acepta el server si eres host. */
  advance: (force?: boolean) => Promise<void>
}

/**
 * Contrato de un juego. Un módulo por juego en src/games/<id>/.
 * El shell posee: fetch canónico, realtime, heartbeat, TimerBar, auto-advance,
 * bot runner y panel de host (Forzar avance / Terminar). El juego posee: sus fases.
 */
export interface GameDefinition<S extends GameState = GameState> {
  /** Debe coincidir con game_sessions.game_type y con GameMeta.id del registry. */
  id: string
  nameEs: string
  /** Título de cabecera según la fase actual. */
  phaseTitle: (state: S) => string
  /** true → el shell hace fetch de player_secrets tras cada refetch. */
  needsSecret?: (state: S) => boolean
  /** Vista principal (host incluido; controles extra de host van en HostView). */
  PlayerView: ComponentType<{ ctx: GameCtx<S> }>
  /** Controles de host propios del juego, encima del panel compartido. */
  HostView?: ComponentType<{ ctx: GameCtx<S> }>
}
