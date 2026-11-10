import { motion } from 'framer-motion'
import type { GameCtx, GameDefinition, GameState } from '../../engine/types'
import { Podium } from '../../engine/Podium'
import { Button } from '../../ui/Button'
import { Card } from '../../ui/Card'
import { AvatarBlock } from '../../ui/Avatar'

/**
 * Sin Filtro (010/022): estilo CAH con mazo 100% original.
 * MANO FINITA: repartes N cartas al arrancar y NO se reponen — cada ronda
 * tienes una menos ("agh, hubiera usado la anterior"). Modos:
 *  · juez (clásico): juez rotativo corona a ciegas.
 *  · votos: no hay juez — todos votan la mejor (menos la propia).
 * Suspenso opcional: el host lee las jugadas en voz alta antes de mostrarlas.
 */
interface SfPlay { pid: string; text: string }
interface SfState extends GameState {
  timer_s?: number
  negras?: { text: string }[]
  negra_idx?: number
  hand_n?: number
  judge_mode?: 'juez' | 'votos'
  suspenso?: boolean
  shown?: boolean
  votes?: Record<string, string>
  turn_order?: string[]
  juez_idx?: number
  plays?: SfPlay[]
  winner_idx?: number | null
  scores?: Record<string, number>
}

function juezId(st: SfState): string | undefined {
  if ((st.judge_mode ?? 'juez') !== 'juez') return undefined
  return st.turn_order?.[st.juez_idx ?? 0]
}

function NegraBanner({ st, players }: { st: SfState; players: { id: string; name: string }[] }) {
  const juez = players.find((p) => p.id === juezId(st))
  return (
    <div style={{ display: 'grid', gap: 10 }}>
      <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase' }}>
        Ronda {(st.negra_idx ?? 0) + 1} de {st.negras?.length ?? 0}
        {juez ? ` · juez: ${juez.name} 👑` : ' · todos votan 🗳'}
      </p>
      <motion.div key={st.negra_idx} initial={{ scale: 0.92, rotate: -1 }} animate={{ scale: 1, rotate: 0 }}
        transition={{ type: 'spring', stiffness: 300, damping: 18 }}>
        <Card style={{ background: '#000', border: '3px solid var(--ink)' }}>
          <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.25rem', lineHeight: 1.3, color: 'var(--ink)' }}>
            {st.negras?.[st.negra_idx ?? 0]?.text}
          </p>
        </Card>
      </motion.div>
    </div>
  )
}

function SinFiltroView({ ctx }: { ctx: GameCtx<SfState> }) {
  const { state: st, players, me, isHost, act, secret } = ctx
  const modoVotos = (st.judge_mode ?? 'juez') === 'votos'
  const juez = juezId(st)
  const soyJuez = me.id === juez
  const plays = st.plays ?? []
  const shown = st.shown ?? true

  if (st.phase === 'jugar') {
    const hand = (secret?.hand as string[] | undefined) ?? []
    const played = plays.some((p) => p.pid === me.id)
    const sinCartas = hand.length === 0 && !played
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <NegraBanner st={st} players={players} />
        {soyJuez ? (
          <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>
            Eres EL JUEZ 👑 — espera las jugadas… ({plays.length} van)
          </p>
        ) : played ? (
          <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>
            Carta jugada ✓ ({plays.length} van)
          </p>
        ) : sinCartas ? (
          <Card><p style={{ fontWeight: 700, textAlign: 'center', color: 'var(--muted)' }}>
            Te quedaste sin cartas 🫥 — mira cómo sufren los demás
          </p></Card>
        ) : (
          <>
            <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>
              Tu mano — quedan {hand.length} y NO se reponen 😬 toca para jugar
            </p>
            <div style={{ display: 'grid', gap: 8 }}>
              {hand.map((c, i) => (
                <motion.button key={`${i}-${c}`} whileTap={{ scale: 0.96 }}
                  onClick={() => void act('play', { idx: i })}
                  style={{
                    padding: 12, textAlign: 'left', fontWeight: 700, background: 'var(--ink)',
                    color: '#000', border: 'var(--border)',
                  }}>
                  {c}
                </motion.button>
              ))}
            </div>
          </>
        )}
      </div>
    )
  }

  if (st.phase === 'juzgar') {
    // suspenso: solo el host ve las jugadas hasta que las "muestre"
    if (!shown && !isHost) {
      return (
        <div style={{ display: 'grid', gap: 14 }}>
          <NegraBanner st={st} players={players} />
          <Card accent="var(--coral)">
            <p style={{ fontWeight: 700, textAlign: 'center' }}>🎙 El anfitrión está leyendo las jugadas en voz alta… atentos.</p>
          </Card>
        </div>
      )
    }
    const myVote = st.votes?.[me.id]
    const puedoVotar = modoVotos && shown
    const puedoCoronar = !modoVotos && soyJuez && shown
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <NegraBanner st={st} players={players} />
        {!shown && isHost && (
          <Card accent="var(--coral)">
            <p style={{ fontWeight: 700 }}>🎙 Solo tú las ves. Léelas con drama y luego muéstralas.</p>
          </Card>
        )}
        <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>
          {!shown ? 'Jugadas (ocultas para el resto):'
            : modoVotos ? (myVote != null ? 'Voto puesto (puedes cambiarlo)' : 'Vota la mejor 🗳 (menos la tuya)')
            : soyJuez ? 'Corona la mejor 👑 (son anónimas)' : 'El juez delibera…'}
          {modoVotos && shown && ` · ${Object.keys(st.votes ?? {}).length}/${players.length}`}
        </p>
        <div style={{ display: 'grid', gap: 8 }}>
          {plays.map((p, i) => {
            const esMia = p.pid === me.id
            const clickable = (puedoCoronar || (puedoVotar && !esMia))
            return (
              <motion.button key={i} initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }}
                transition={{ delay: 0.15 * i, type: 'spring', stiffness: 300, damping: 20 }}
                whileTap={clickable ? { scale: 0.96 } : undefined}
                onClick={() => {
                  if (puedoCoronar) void act('crown', { idx: i })
                  else if (puedoVotar && !esMia) void act('vote', { idx: i })
                }}
                style={{
                  padding: 12, textAlign: 'left', fontWeight: 700,
                  background: myVote === String(i) ? 'var(--amber)' : 'var(--ink)',
                  color: '#000', border: 'var(--border)',
                  cursor: clickable ? 'pointer' : 'default',
                  opacity: puedoVotar && esMia ? 0.55 : 1,
                }}>
                {p.text}{puedoVotar && esMia ? '  (la tuya)' : ''}
              </motion.button>
            )
          })}
        </div>
      </div>
    )
  }

  if (st.phase === 'resultado') {
    const w = st.winner_idx != null ? plays[st.winner_idx] : null
    const winner = players.find((p) => p.id === w?.pid)
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <NegraBanner st={st} players={players} />
        <motion.div initial={{ scale: 0.7 }} animate={{ scale: 1 }}
          transition={{ type: 'spring', stiffness: 300, damping: 14 }}>
          <Card accent="var(--amber)" style={{ display: 'grid', gap: 8 }}>
            <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.3rem' }}>{w?.text ?? '…'}</p>
            <motion.div initial={{ opacity: 0, x: -16 }} animate={{ opacity: 1, x: 0 }}
              transition={{ delay: 0.6, type: 'spring', stiffness: 300, damping: 18 }}
              style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              {winner && <AvatarBlock avatar={winner.avatar} size={28} />}
              <span style={{ fontWeight: 700 }}>{winner?.name ?? '?'}</span>
              <span style={{ fontFamily: 'var(--font-display)', color: 'var(--amber)' }}>+1 👑</span>
            </motion.div>
          </Card>
        </motion.div>
      </div>
    )
  }

  if (st.phase === 'podio') {
    return <Podium players={players} scores={st.scores ?? {}} unit="👑" />
  }

  return null
}

function SinFiltroHost({ ctx }: { ctx: GameCtx<SfState> }) {
  const { state: st, act, advance } = ctx
  const modoVotos = (st.judge_mode ?? 'juez') === 'votos'
  if (st.phase === 'resultado') {
    const last = (st.negra_idx ?? 0) + 1 >= (st.negras?.length ?? 0)
    return <Button big onClick={() => void advance(true)}>{last ? 'Ver podio 🏆' : 'Siguiente ronda →'}</Button>
  }
  if (st.phase === 'podio') {
    return <Button big onClick={() => void advance(true)}>Terminar juego 🏁</Button>
  }
  if (st.phase === 'juzgar') {
    if (!(st.shown ?? true)) {
      return <Button big onClick={() => void act('show')}>Mostrar jugadas a todos 👀</Button>
    }
    return (
      <Button variant="danger" onClick={() => void advance(true)}>
        {modoVotos ? 'Cerrar votación ya' : 'Juez ausente → coronar random'}
      </Button>
    )
  }
  return null
}

const PHASE_TITLE: Record<string, string> = {
  jugar: 'Completa la frase',
  juzgar: 'El veredicto',
  resultado: 'Y la ronda es para…',
  podio: 'El podio',
}

export const sinFiltroGame: GameDefinition<SfState> = {
  id: 'sin-filtro',
  nameEs: 'Sin Filtro',
  phaseTitle: (st) => PHASE_TITLE[st.phase] ?? st.phase,
  needsSecret: (st) => st.phase === 'jugar',
  PlayerView: SinFiltroView,
  HostView: SinFiltroHost,
}
