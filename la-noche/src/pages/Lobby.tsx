import { useCallback, useEffect, useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { motion, AnimatePresence } from 'framer-motion'
import { QRCodeSVG } from 'qrcode.react'
import { Button } from '../ui/Button'
import { Card } from '../ui/Card'
import { CodeMarquee } from '../ui/CodeMarquee'
import { AvatarBlock } from '../ui/Avatar'
import { GAMES, type GameMeta } from '../games/registry'
import { DeckBuilder } from '../ui/DeckBuilder'
import { supabase, ensureAuth } from '../lib/supabase'
import {
  fetchPartyState, heartbeat, leaveParty, kickPlayer, transferHost,
  claimHost, devAddBots, devRemoveBots, launchGame,
} from '../lib/api'
import { loadSession, clearSession } from '../lib/session'
import { useWakeLock } from '../hooks/useWakeLock'
import type { Party, Player } from '../lib/types'

const DEV_BOTS = import.meta.env.VITE_DEV_BOTS === 'true'
const STALE_MS = 20_000
const HOST_STALE_MS = 60_000

// Juegos de mazo → modal de configuración antes de lanzar.
const DECK_DEFAULTS: Record<string, { n: number; sizes: number[]; timer?: number }> = {
  'la-ruleta': { n: 40, sizes: [20, 30, 40] },
  // 028: impostor y charadas solo en vivo → sin timer (nadie lo usaba)
  impostor: { n: 3, sizes: [3, 5, 7] },
  'tres-rondas': { n: 25, sizes: [15, 25, 40] },
  'parejas-a-gritos': { n: 3, sizes: [2, 3, 5] },
}
// juegos sin mazo pero con opciones de lanzamiento (022)
const SETUP_ONLY = new Set(['lobos', 'dos-cuartos'])

interface LaunchCfg {
  n_cards: number
  timer_s: number
  countdown_s: number
  judge_mode: 'juez' | 'votos'
  suspenso: boolean
  offline: boolean
  n_impostors: number
  roles: { vidente: boolean; protector: boolean; bruja: boolean; cazador: boolean }
}

function Toggle({ on, label, onClick }: { on: boolean; label: string; onClick: () => void }) {
  return (
    <button onClick={onClick}
      style={{
        padding: '8px 10px', fontWeight: 700, fontSize: '0.85rem', cursor: 'pointer',
        border: 'var(--border-thin)', textAlign: 'left',
        background: on ? 'var(--amber)' : 'var(--bg)',
        color: on ? '#000' : 'var(--ink)',
      }}>
      {on ? '☑' : '☐'} {label}
    </button>
  )
}

export function Lobby() {
  const nav = useNavigate()
  const session = loadSession()
  const [party, setParty] = useState<Party | null>(null)
  const [players, setPlayers] = useState<Player[]>([])
  const [now, setNow] = useState(Date.now())
  const [showQR, setShowQR] = useState(false)
  const [managing, setManaging] = useState<Player | null>(null)
  const [launchError, setLaunchError] = useState<string | null>(null)
  const [launching, setLaunching] = useState<GameMeta | null>(null)
  const [builderGame, setBuilderGame] = useState<GameMeta | null>(null)
  const [cfg, setCfg] = useState<LaunchCfg>({
    n_cards: 15, timer_s: 30,
    countdown_s: 0, judge_mode: 'juez', suspenso: false, offline: false, n_impostors: 1,
    roles: { vidente: true, protector: true, bruja: false, cazador: false },
  })

  useWakeLock()

  const refetch = useCallback(async () => {
    if (!session) return
    try {
      const { party, players } = await fetchPartyState(session.partyId)
      setParty(party)
      setPlayers(players)
    } catch {
      // party borrada o sin acceso → volver al inicio
      clearSession()
      nav('/')
    }
  }, [session?.partyId]) // eslint-disable-line react-hooks/exhaustive-deps

  // guard + carga inicial + realtime + heartbeat + reloj de staleness
  useEffect(() => {
    if (!session) {
      nav('/')
      return
    }
    void ensureAuth().then(refetch)

    const channel = supabase
      .channel(`party-${session.partyId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'players', filter: `party_id=eq.${session.partyId}` }, () => void refetch())
      .on('postgres_changes', { event: '*', schema: 'public', table: 'parties', filter: `id=eq.${session.partyId}` }, () => void refetch())
      .subscribe()

    const hb = setInterval(() => void heartbeat(session.partyId).catch(() => {}), 10_000)
    void heartbeat(session.partyId).catch(() => {})
    const clock = setInterval(() => setNow(Date.now()), 5_000)

    // pantalla bloqueada → desbloqueada: sync inmediato
    const onVisible = () => {
      if (document.visibilityState === 'visible') {
        void heartbeat(session.partyId).catch(() => {})
        void refetch()
      }
    }
    document.addEventListener('visibilitychange', onVisible)

    return () => {
      void supabase.removeChannel(channel)
      clearInterval(hb)
      clearInterval(clock)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  const me = useMemo(() => players.find((p) => p.id === session?.playerId), [players, session?.playerId])
  const host = useMemo(() => players.find((p) => p.is_host), [players])
  const isHost = me?.is_host ?? false
  const activeCount = players.length

  const isStale = (p: Player) => !p.is_bot && now - new Date(p.last_seen).getTime() > STALE_MS
  const hostStale = host ? !host.is_bot && now - new Date(host.last_seen).getTime() > HOST_STALE_MS : true

  // si me kickearon / me sacaron, players ya no me incluye
  useEffect(() => {
    if (party && players.length > 0 && session && !players.some((p) => p.id === session.playerId)) {
      clearSession()
      nav('/')
    }
  }, [players, party]) // eslint-disable-line react-hooks/exhaustive-deps

  // juego en marcha → todos a la pantalla de juego
  useEffect(() => {
    if (party?.status === 'in_game') nav('/juego')
  }, [party?.status]) // eslint-disable-line react-hooks/exhaustive-deps

  if (!session || !party) return null

  const joinUrl = `${window.location.origin}/j/${party.code}`

  async function salir() {
    await leaveParty(session!.partyId).catch(() => {})
    clearSession()
    nav('/')
  }

  return (
    <main style={{ maxWidth: 480, margin: '0 auto', padding: '24px 20px 120px', display: 'grid', gap: 28 }}>
      <CodeMarquee code={party.code} />

      {/* banner failover */}
      {hostStale && !isHost && (
        <Card accent="var(--coral)" style={{ display: 'grid', gap: 10 }}>
          <p style={{ fontWeight: 700 }}>El host desapareció 👀</p>
          <Button variant="danger" onClick={() => void claimHost(session.partyId).then(refetch).catch(() => {})}>
            Tomar el mando
          </Button>
        </Card>
      )}

      {/* jugadores */}
      <section style={{ display: 'grid', gap: 12 }}>
        <h3>
          En la noche <span style={{ color: 'var(--amber)' }}>({activeCount})</span>
        </h3>
        <div style={{ display: 'grid', gap: 8 }}>
          <AnimatePresence>
            {players.map((p) => (
              <motion.div
                key={p.id}
                layout
                initial={{ scale: 0.8, opacity: 0 }}
                animate={{ scale: 1, opacity: 1 }}
                exit={{ scale: 0.8, opacity: 0 }}
                transition={{ type: 'spring', stiffness: 400, damping: 25 }}
                onClick={isHost && p.id !== me?.id ? () => setManaging(p) : undefined}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: 12,
                  padding: '8px 12px',
                  border: 'var(--border-thin)',
                  background: 'var(--surface)',
                  opacity: isStale(p) ? 0.45 : 1,
                  cursor: isHost && p.id !== me?.id ? 'pointer' : 'default',
                }}
              >
                <AvatarBlock avatar={p.avatar} size={40} />
                <span style={{ fontWeight: 700, flex: 1 }}>
                  {p.name}
                  {p.id === me?.id && <span style={{ color: 'var(--muted)' }}> (tú)</span>}
                </span>
                {p.is_host && (
                  <span style={{ fontFamily: 'var(--font-display)', fontSize: '0.7rem', background: 'var(--amber)', color: '#000', padding: '3px 8px', border: '2px solid #000' }}>
                    HOST
                  </span>
                )}
                {isStale(p) && <span style={{ fontSize: '0.75rem', color: 'var(--coral)', fontWeight: 700 }}>desconectado</span>}
              </motion.div>
            ))}
          </AnimatePresence>
        </div>
        {isHost && DEV_BOTS && (
          <div style={{ display: 'flex', gap: 10 }}>
            <Button variant="secondary" style={{ flex: 1 }} onClick={() => void devAddBots(session.partyId, 4).then(refetch)}>
              +4 bots 🤖
            </Button>
            <Button variant="ghost" style={{ flex: 1 }} onClick={() => void devRemoveBots(session.partyId).then(refetch)}>
              Sin bots
            </Button>
          </div>
        )}
      </section>

      {/* modal gestionar jugador (host) */}
      {managing && (
        <div
          onClick={() => setManaging(null)}
          style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.7)', display: 'grid', placeItems: 'center', zIndex: 50, padding: 24 }}
        >
          <Card style={{ display: 'grid', gap: 12, width: '100%', maxWidth: 360 }}>
            <h3>{managing.name}</h3>
            {!managing.is_bot && (
              <Button variant="secondary" onClick={() => { void transferHost(session.partyId, managing.id).then(refetch); setManaging(null) }}>
                Hacer host
              </Button>
            )}
            <Button variant="danger" onClick={() => { void kickPlayer(session.partyId, managing.id).then(refetch); setManaging(null) }}>
              Expulsar
            </Button>
            <Button variant="ghost" onClick={() => setManaging(null)}>Cancelar</Button>
          </Card>
        </div>
      )}

      {/* panel del host */}
      {isHost && (
        <>
          <section style={{ display: 'grid', gap: 12 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', gap: 8 }}>
              <h3 style={{ flex: 1 }}>Juegos</h3>
              <button
                onClick={() => nav('/cartas')}
                style={{ background: 'var(--surface)', color: 'var(--ink)', border: 'var(--border-thin)', padding: '6px 12px', fontWeight: 700 }}
              >
                🗂 Cartas
              </button>
              <button
                onClick={() => setShowQR(true)}
                style={{ background: 'var(--surface)', color: 'var(--ink)', border: 'var(--border-thin)', padding: '6px 12px', fontWeight: 700 }}
              >
                QR para unirse
              </button>
            </div>
            {launchError && (
              <p onClick={() => setLaunchError(null)}
                style={{ color: 'var(--coral)', fontWeight: 700, fontSize: '0.85rem', border: 'var(--border-thin)', padding: '8px 12px', cursor: 'pointer' }}>
                ⚠ {launchError} (toca para cerrar)
              </p>
            )}
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
              {GAMES.map((g) => {
                const enough = activeCount >= g.minPlayers && activeCount <= g.maxPlayers
                const playable = g.available && enough
                return (
                  <div
                    key={g.id}
                    onClick={playable ? () => {
                      const d = DECK_DEFAULTS[g.id]
                      if (d || SETUP_ONLY.has(g.id)) {
                        setCfg({
                          n_cards: d?.n ?? 15,
                          timer_s: d?.timer ?? 30,
                          countdown_s: 0, judge_mode: 'juez', suspenso: false, offline: false, n_impostors: 1,
                          roles: {
                            vidente: true, protector: true,
                            bruja: activeCount >= 8, cazador: activeCount >= 12,
                          },
                        })
                        setLaunching(g)
                      } else {
                        void launchGame(session.partyId, g.id).then(() => nav('/juego')).catch((e: Error) => {
                          setLaunchError(`No se pudo lanzar: ${e.message}`)
                        })
                      }
                    } : undefined}
                    style={{
                      border: 'var(--border-thin)',
                      background: 'var(--surface)',
                      padding: 12,
                      opacity: playable ? 1 : 0.45,
                      display: 'grid',
                      gap: 4,
                      cursor: playable ? 'pointer' : 'default',
                      boxShadow: playable ? '3px 3px 0 #000' : 'none',
                    }}
                  >
                    <span style={{ fontFamily: 'var(--font-display)', fontSize: '0.9rem', color: g.accent, textTransform: 'uppercase', lineHeight: 1.1 }}>
                      {g.nameEs}
                    </span>
                    <span style={{ fontSize: '0.72rem', color: 'var(--muted)' }}>
                      {!g.available ? 'próximamente' : enough ? g.tagline : `${g.minPlayers}–${g.maxPlayers} jugadores`}
                    </span>
                  </div>
                )
              })}
            </div>
          </section>

          {/* 025: modo social/puntos eliminado — solo versión trago.
              027: intensidad 1-5 eliminada (César: "no me parece"). La columna
              sigue en la DB pero ya nadie filtra ni la muestra. */}
        </>
      )}

      {/* modal configurar y lanzar juego de mazo (host) */}
      {launching && (
        <div
          onClick={() => setLaunching(null)}
          style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.7)', display: 'grid', placeItems: 'center', zIndex: 50, padding: 24 }}
        >
          <Card style={{ display: 'grid', gap: 14, width: '100%', maxWidth: 380 }} onClick={(e) => e.stopPropagation()}>
            <h3 style={{ color: launching.accent }}>{launching.nameEs}</h3>

            {DECK_DEFAULTS[launching.id] && (
              <>
                <div style={{ display: 'grid', gap: 6 }}>
                  <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase' }}>
                    Cartas
                  </p>
                  <div style={{ display: 'flex', gap: 6 }}>
                    {(DECK_DEFAULTS[launching.id]?.sizes ?? [10, 15, 20]).map((n) => (
                      <button key={n} onClick={() => setCfg((c) => ({ ...c, n_cards: n }))}
                        style={{
                          flex: 1, padding: '8px 0', fontWeight: 700, cursor: 'pointer', border: 'var(--border-thin)',
                          background: cfg.n_cards === n ? 'var(--amber)' : 'var(--bg)',
                          color: cfg.n_cards === n ? '#000' : 'var(--ink)',
                        }}>
                        {n}
                      </button>
                    ))}
                  </div>
                </div>

                {DECK_DEFAULTS[launching.id]?.timer !== undefined && (
                  <div style={{ display: 'grid', gap: 6 }}>
                    <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase' }}>Timer</p>
                    <div style={{ display: 'flex', gap: 6 }}>
                      {[15, 20, 30, 45, 60].map((n) => (
                        <button key={n} onClick={() => setCfg((c) => ({ ...c, timer_s: n }))}
                          style={{
                            flex: 1, padding: '8px 0', fontWeight: 700, fontSize: '0.85rem', cursor: 'pointer', border: 'var(--border-thin)',
                            background: cfg.timer_s === n ? 'var(--amber)' : 'var(--bg)',
                            color: cfg.timer_s === n ? '#000' : 'var(--ink)',
                          }}>
                          {n}s
                        </button>
                      ))}
                    </div>
                  </div>
                )}
              </>
            )}

            {launching.id === 'la-ruleta' && (
              <div style={{ display: 'grid', gap: 6 }}>
                <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase' }}>Countdown al pasar carta</p>
                <div style={{ display: 'flex', gap: 6 }}>
                  {[0, 3, 5].map((n) => (
                    <button key={n} onClick={() => setCfg((c) => ({ ...c, countdown_s: n }))}
                      style={{
                        flex: 1, padding: '8px 0', fontWeight: 700, fontSize: '0.85rem', cursor: 'pointer', border: 'var(--border-thin)',
                        background: cfg.countdown_s === n ? 'var(--amber)' : 'var(--bg)',
                        color: cfg.countdown_s === n ? '#000' : 'var(--ink)',
                      }}>
                      {n === 0 ? 'Off' : `${n}s`}
                    </button>
                  ))}
                </div>
              </div>
            )}

            {/* 028: impostor, charadas y lobos son SIEMPRE en vivo (el server lo fuerza) */}
            {launching.id === 'dos-cuartos' && (
              <Toggle on={cfg.offline}
                label="🪑 Modo en vivo: solo reparte, el juego se habla"
                onClick={() => setCfg((c) => ({ ...c, offline: !c.offline }))} />
            )}

            {launching.id === 'impostor' && (
              <div style={{ display: 'grid', gap: 6 }}>
                <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase' }}>Impostores</p>
                <div style={{ display: 'flex', gap: 6 }}>
                  {[1, 2, 3].map((n) => {
                    const ok = n <= Math.max(1, activeCount - 2)
                    return (
                      <button key={n} disabled={!ok} onClick={() => setCfg((c) => ({ ...c, n_impostors: n }))}
                        style={{
                          flex: 1, padding: '8px 0', fontWeight: 700, cursor: ok ? 'pointer' : 'default',
                          border: 'var(--border-thin)', opacity: ok ? 1 : 0.35,
                          background: cfg.n_impostors === n ? 'var(--amber)' : 'var(--bg)',
                          color: cfg.n_impostors === n ? '#000' : 'var(--ink)',
                        }}>
                        {n} 🕵️
                      </button>
                    )
                  })}
                </div>
              </div>
            )}

            {launching.id === 'lobos' && (
              <div style={{ display: 'grid', gap: 6 }}>
                <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase' }}>Roles especiales (off = solo aldeanos y lobos)</p>
                <Toggle on={cfg.roles.vidente} label="🔮 Vidente"
                  onClick={() => setCfg((c) => ({ ...c, roles: { ...c.roles, vidente: !c.roles.vidente } }))} />
                <Toggle on={cfg.roles.protector} label="🛡 Protector"
                  onClick={() => setCfg((c) => ({ ...c, roles: { ...c.roles, protector: !c.roles.protector } }))} />
                <Toggle on={cfg.roles.bruja} label="🧪 Bruja"
                  onClick={() => setCfg((c) => ({ ...c, roles: { ...c.roles, bruja: !c.roles.bruja } }))} />
                <Toggle on={cfg.roles.cazador} label="🏹 Cazador"
                  onClick={() => setCfg((c) => ({ ...c, roles: { ...c.roles, cazador: !c.roles.cazador } }))} />
              </div>
            )}

            <Button big onClick={() => {
              const g = launching
              setLaunching(null)
              const opts: import('../lib/api').LaunchOpts = {}
              if (DECK_DEFAULTS[g.id]) {
                opts.n_cards = cfg.n_cards
                if (DECK_DEFAULTS[g.id]?.timer !== undefined) opts.timer_s = cfg.timer_s
              }
              if (g.id === 'la-ruleta') opts.countdown_s = cfg.countdown_s
              if (g.id === 'dos-cuartos') opts.offline = cfg.offline
              if (g.id === 'impostor') opts.n_impostors = cfg.n_impostors
              if (g.id === 'lobos') opts.roles = cfg.roles
              void launchGame(session.partyId, g.id, opts).then(() => nav('/juego')).catch((e: Error) => {
                setLaunchError(e.message === 'SIN_CARTAS'
                  ? `${g.nameEs} no tiene cartas — revisa /cartas`
                  : `No se pudo lanzar: ${e.message}`)
              })
            }}>
              Lanzar 🚀
            </Button>
            {DECK_DEFAULTS[launching.id] && (
              <Button variant="secondary" onClick={() => { setBuilderGame(launching); setLaunching(null) }}>
                🗂 Armar mazo a mano →
              </Button>
            )}
            <Button variant="ghost" onClick={() => setLaunching(null)}>Cancelar</Button>
          </Card>
        </div>
      )}

      {/* deck builder full-screen (host admin) */}
      {builderGame && (
        <DeckBuilder
          game={builderGame}
          partyId={session.partyId}
          mode={party.settings.mode}
          timerDefault={DECK_DEFAULTS[builderGame.id]?.timer}
          onClose={() => setBuilderGame(null)}
          onLaunched={() => nav('/juego')}
        />
      )}

      {/* modal QR */}
      {showQR && (
        <div
          onClick={() => setShowQR(false)}
          style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.85)', display: 'grid', placeItems: 'center', zIndex: 50, padding: 24 }}
        >
          <Card style={{ display: 'grid', gap: 14, placeItems: 'center', background: 'var(--ink)' }}>
            <QRCodeSVG value={joinUrl} size={240} bgColor="#F5EFE6" fgColor="#1A1614" />
            <span style={{ fontFamily: 'var(--font-display)', fontSize: '1.6rem', color: 'var(--bg)', letterSpacing: '0.2em' }}>
              {party.code}
            </span>
          </Card>
        </div>
      )}

      <Button variant="ghost" onClick={() => void salir()}>
        Salir de la noche
      </Button>
    </main>
  )
}
