import { supabase, ensureAuth } from './supabase'
import type { Avatar, Party, Player } from './types'

interface JoinResult {
  party_id: string
  code: string
  player_id: string
}

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args)
  if (error) throw new Error(error.message)
  return data as T
}

// Crear noche exige cuenta real (admin), nunca sesión anónima.
export async function createParty(name: string, avatar: Avatar): Promise<JoinResult> {
  const { data } = await supabase.auth.getSession()
  if (!data.session || data.session.user.is_anonymous) throw new Error('SOLO_ADMIN')
  return rpc<JoinResult>('create_party', { p_name: name, p_avatar: avatar })
}

export async function joinParty(code: string, name: string, avatar: Avatar): Promise<JoinResult> {
  await ensureAuth()
  return rpc<JoinResult>('join_party', { p_code: code, p_name: name, p_avatar: avatar })
}

export const heartbeat = (partyId: string) => rpc<void>('heartbeat', { p_party_id: partyId })
export const leaveParty = (partyId: string) => rpc<void>('leave_party', { p_party_id: partyId })
export const kickPlayer = (partyId: string, target: string) =>
  rpc<void>('kick_player', { p_party_id: partyId, p_target: target })
export const transferHost = (partyId: string, target: string) =>
  rpc<void>('transfer_host', { p_party_id: partyId, p_target: target })
export const claimHost = (partyId: string) => rpc<void>('claim_host', { p_party_id: partyId })
export const updateSettings = (partyId: string, settings: Party['settings']) =>
  rpc<void>('update_settings', { p_party_id: partyId, p_settings: settings })
export const devAddBots = (partyId: string, n: number) =>
  rpc<void>('dev_add_bots', { p_party_id: partyId, p_n: n })
export const devRemoveBots = (partyId: string) => rpc<void>('dev_remove_bots', { p_party_id: partyId })

// --- engine (fase 2) ---
export interface LaunchOpts {
  n_cards?: number
  intensity?: number
  timer_s?: number
  /** mazo armado a mano (deck builder); el server respeta el orden */
  card_ids?: string[]
  /** la-ruleta: countdown al pasar carta (0 = off) */
  countdown_s?: number
  /** sin-filtro: juez rotativo o votación de todos */
  judge_mode?: 'juez' | 'votos'
  /** sin-filtro: el host lee las jugadas antes de mostrarlas */
  suspenso?: boolean
  /** dos-cuartos: modo en vivo (solo reparto). Impostor/charadas/lobos: siempre en vivo (028) */
  offline?: boolean
  /** impostor: 1-3 impostores (028) */
  n_impostors?: number
  /** lobos: roles especiales on/off */
  roles?: { vidente?: boolean; protector?: boolean; bruja?: boolean; cazador?: boolean }
}
export const launchGame = (partyId: string, gameType: string, opts: LaunchOpts = {}) =>
  rpc<string>('launch_game', { p_party_id: partyId, p_game_type: gameType, p_opts: opts })
export const endGame = (partyId: string) => rpc<void>('end_game', { p_party_id: partyId })
export const advancePhase = (partyId: string, force = false) =>
  rpc<void>('advance_phase', { p_party_id: partyId, p_force: force })
export const submitAction = (partyId: string, action: string, payload: Record<string, unknown> = {}) =>
  rpc<void>('submit_action', { p_party_id: partyId, p_action: action, p_payload: payload })
export const devBotTick = (partyId: string) => rpc<void>('dev_bot_tick', { p_party_id: partyId })

// --- deck curator (solo admin, RPCs validan sesión no-anónima) ---
export interface ContentCard {
  id: string
  game_type: string
  card_type: string
  text_es: string
  text_en: string | null
  intensity: number
  tags: string[]
  enabled: boolean
}
export const adminListCards = (gameType: string) =>
  rpc<ContentCard[]>('admin_list_cards', { p_game_type: gameType })
export const adminUpsertCard = (card: { id: string | null; game_type: string; card_type: string; text_es: string; intensity: number }) =>
  rpc<string>('admin_upsert_card', {
    p_id: card.id, p_game_type: card.game_type, p_card_type: card.card_type,
    p_text_es: card.text_es, p_intensity: card.intensity,
  })
export const adminSetEnabled = (id: string, enabled: boolean) =>
  rpc<void>('admin_set_enabled', { p_id: id, p_enabled: enabled })
export const adminDeleteCard = (id: string) => rpc<void>('admin_delete_card', { p_id: id })

export interface GameSession {
  id: string
  party_id: string
  game_type: string
  status: 'active' | 'ended'
  // Estado JSONB genérico; cada juego tipa el suyo en src/games/<id>/.
  state: import('../engine/types').GameState
}

export async function fetchActiveSession(partyId: string): Promise<GameSession | null> {
  const { data, error } = await supabase
    .from('game_sessions')
    .select('*')
    .eq('party_id', partyId)
    .eq('status', 'active')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle()
  if (error) throw new Error(error.message)
  return data as GameSession | null
}

export async function fetchMySecret(sessionId: string): Promise<Record<string, unknown> | null> {
  const { data, error } = await supabase
    .from('player_secrets')
    .select('payload')
    .eq('game_session_id', sessionId)
    .maybeSingle()
  if (error) throw new Error(error.message)
  return (data?.payload as Record<string, unknown>) ?? null
}

/** Fetch canónico: party + jugadores. Toda pantalla se reconstruye desde aquí. */
export async function fetchPartyState(partyId: string): Promise<{ party: Party; players: Player[] }> {
  const [p, pl] = await Promise.all([
    supabase.from('parties').select('*').eq('id', partyId).single(),
    supabase
      .from('players')
      .select('*')
      .eq('party_id', partyId)
      .in('status', ['active'])
      .order('joined_at'),
  ])
  if (p.error) throw new Error(p.error.message)
  if (pl.error) throw new Error(pl.error.message)
  return { party: p.data as Party, players: (pl.data ?? []) as Player[] }
}
