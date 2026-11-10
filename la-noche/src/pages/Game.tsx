import { useCallback, useEffect, useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase, ensureAuth } from '../lib/supabase'
import {
  fetchPartyState, fetchActiveSession, fetchMySecret, heartbeat,
  submitAction, advancePhase, endGame, devBotTick, type GameSession,
} from '../lib/api'
import { loadSession } from '../lib/session'
import { useWakeLock } from '../hooks/useWakeLock'
import { Button } from '../ui/Button'
import { TimerBar } from '../engine/primitives'
import { getGameDef } from '../engine/gameRegistry'
import type { GameCtx } from '../engine/types'
import type { Party, Player } from '../lib/types'

const DEV_BOTS = import.meta.env.VITE_DEV_BOTS === 'true'

/**
 * Shell genérico de juego: fetch canónico, realtime, heartbeat, timer,
 * bot runner y panel de host. La UI de cada fase vive en el módulo del
 * juego (src/games/<id>/), resuelto por game_type vía gameRegistry.
 */
export function Game() {
  const nav = useNavigate()
  const stored = loadSession()
  const [players, setPlayers] = useState<Player[]>([])
  const [party, setParty] = useState<Party | null>(null)
  const [session, setSession] = useState<GameSession | null>(null)
  const [secret, setSecret] = useState<Record<string, unknown> | null>(null)

  useWakeLock()

  const refetch = useCallback(async () => {
    if (!stored) return
    try {
      const [{ party, players }, gs] = await Promise.all([
        fetchPartyState(stored.partyId),
        fetchActiveSession(stored.partyId),
      ])
      setPlayers(players)
      setParty(party)
      if (!gs || party.status !== 'in_game') {
        nav('/sala') // juego terminó → todos de vuelta al lobby
        return
      }
      setSession(gs)
      const def = getGameDef(gs.game_type)
      if (def?.needsSecret?.(gs.state)) {
        setSecret(await fetchMySecret(gs.id))
      }
    } catch {
      nav('/sala')
    }
  }, [stored?.partyId]) // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (!stored) { nav('/'); return }
    void ensureAuth().then(refetch)
    const ch = supabase
      .channel(`game-${stored.partyId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'game_sessions', filter: `party_id=eq.${stored.partyId}` }, () => void refetch())
      .on('postgres_changes', { event: '*', schema: 'public', table: 'parties', filter: `id=eq.${stored.partyId}` }, () => void refetch())
      .subscribe()
    const hb = setInterval(() => void heartbeat(stored.partyId).catch(() => {}), 10_000)
    // pantalla bloqueada → desbloqueada: sync inmediato
    const onVisible = () => {
      if (document.visibilityState === 'visible') {
        void heartbeat(stored.partyId).catch(() => {})
        void refetch()
      }
    }
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      void supabase.removeChannel(ch)
      clearInterval(hb)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  const me = useMemo(() => players.find((p) => p.id === stored?.playerId), [players, stored?.playerId])
  const isHost = me?.is_host ?? false

  // bot runner: host + flag → tick cada 3s
  useEffect(() => {
    if (!isHost || !DEV_BOTS || !stored) return
    const id = setInterval(() => void devBotTick(stored.partyId).catch(() => {}), 3000)
    return () => clearInterval(id)
  }, [isHost, stored?.partyId]) // eslint-disable-line react-hooks/exhaustive-deps

  if (!stored || !session || !me) return null
  const def = getGameDef(session.game_type)
  const st = session.state

  // timer venció → cualquier cliente intenta avanzar; server valida
  const tryAdvance = () => void advancePhase(stored.partyId, false).catch(() => {})

  const ctx: GameCtx = {
    partyId: stored.partyId,
    code: stored.code,
    players,
    me,
    isHost,
    sessionId: session.id,
    settings: party?.settings ?? { mode: 'social', intensity: 2 },
    state: st,
    secret,
    act: (action, payload = {}) => submitAction(stored.partyId, action, payload).then(refetch),
    advance: (force = false) => advancePhase(stored.partyId, force).then(refetch),
  }

  return (
    <main style={{ maxWidth: 480, margin: '0 auto', padding: '24px 20px 140px', display: 'grid', gap: 22 }}>
      <div>
        <p style={{ color: 'var(--muted)', fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.1em' }}>
          {def?.nameEs ?? session.game_type} · {stored.code}
        </p>
        <h2>{def?.phaseTitle(st) ?? st.phase}</h2>
      </div>

      <TimerBar endsAt={st.phase_ends_at} onExpire={tryAdvance} />

      {def
        ? <def.PlayerView ctx={ctx} />
        : <p style={{ color: 'var(--muted)' }}>Este juego no está en esta versión de la app. Actualiza la página.</p>}

      {isHost && def?.HostView && (
        <div style={{ display: 'grid', gap: 6 }}>
          <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.75rem', textTransform: 'uppercase', textAlign: 'center' }}>
            👑 Solo tú (admin) ves estos botones
          </p>
          <def.HostView ctx={ctx} />
        </div>
      )}

      {/* panel flotante del host */}
      {isHost && (
        <div style={{ position: 'fixed', bottom: 0, left: 0, right: 0, background: 'var(--bg)', borderTop: 'var(--border)', padding: '12px 20px', display: 'flex', gap: 10, maxWidth: 480, margin: '0 auto' }}>
          <Button variant="danger" style={{ flex: 1 }} onClick={() => void advancePhase(stored.partyId, true).then(refetch)}>
            Forzar avance ⏭
          </Button>
          <Button variant="ghost" onClick={() => void endGame(stored.partyId)}>
            Terminar
          </Button>
        </div>
      )}
    </main>
  )
}
