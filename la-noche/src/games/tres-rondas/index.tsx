import { useState } from 'react'
import { motion } from 'framer-motion'
import type { GameCtx, GameDefinition, GameState } from '../../engine/types'
import { Button } from '../../ui/Button'
import { Card } from '../../ui/Card'
import { AvatarBlock } from '../../ui/Avatar'

/**
 * Tres Rondas (014): Fishbowl. Mismo pool en 3 rondas — 1 Descríbelo,
 * 2 UNA palabra, 3 Actúalo. 2 equipos; turnos de 60s donde el actor ve
 * la palabra y su equipo grita. +1 por acierto.
 */
interface TrState extends GameState {
  pool?: string[]
  remaining?: string[]
  round?: number
  timer_s?: number
  turn_order?: string[]
  turn_idx?: number
  teams?: Record<string, 'A' | 'B'>
  team_scores?: { A: number; B: number }
  mode_base?: boolean
}

const ROUND_NAME = ['', 'Descríbelo 🗣', 'UNA palabra ☝️', 'Actúalo 🎭']

function TresRondasView({ ctx }: { ctx: GameCtx<TrState> }) {
  const { state: st, players, me, act, advance } = ctx
  const [verPalabra, setVerPalabra] = useState(false)
  const actorId = st.turn_order?.[st.turn_idx ?? 0]
  const actor = players.find((p) => p.id === actorId)
  const myTeam = st.teams?.[me.id]
  const scores = st.team_scores ?? { A: 0, B: 0 }

  // MODO BASE (022): la app solo arma equipos y dispensa palabras;
  // turnos, tiempos y puntos se manejan EN VIVO.
  if (st.mode_base) {
    const word = st.remaining?.[0]
    const equipoA = players.filter((p) => st.teams?.[p.id] === 'A')
    const equipoB = players.filter((p) => st.teams?.[p.id] === 'B')
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <Card accent={myTeam === 'A' ? 'var(--amber)' : 'var(--coral)'} style={{ textAlign: 'center' }}>
          <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.6rem' }}>
            Eres del EQUIPO {myTeam ?? '?'}
          </p>
        </Card>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
          <Card style={{ display: 'grid', gap: 2 }}>
            <p style={{ fontWeight: 700, color: 'var(--amber)' }}>Equipo A</p>
            {equipoA.map((p) => <p key={p.id} style={{ fontWeight: 700, fontSize: '0.85rem' }}>{p.name}</p>)}
          </Card>
          <Card style={{ display: 'grid', gap: 2 }}>
            <p style={{ fontWeight: 700, color: 'var(--coral)' }}>Equipo B</p>
            {equipoB.map((p) => <p key={p.id} style={{ fontWeight: 700, fontSize: '0.85rem' }}>{p.name}</p>)}
          </Card>
        </div>
        <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.85rem', textAlign: 'center' }}>
          3 rondas con las MISMAS palabras: 1 Descríbelo 🗣 · 2 UNA palabra ☝️ · 3 Actúalo 🎭.
          Turnos y puntos: en vivo. Quedan {st.remaining?.length ?? 0} palabras.
        </p>
        {word == null ? (
          <Card><p style={{ fontWeight: 700, textAlign: 'center' }}>Se acabaron las palabras 🏁 (el host termina el juego)</p></Card>
        ) : verPalabra ? (
          <motion.div key={word} initial={{ scale: 0.9 }} animate={{ scale: 1 }}>
            <Card accent="var(--amber)" style={{ minHeight: 90, display: 'grid', placeItems: 'center' }}>
              <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.5rem', textAlign: 'center' }}>{word}</p>
            </Card>
          </motion.div>
        ) : (
          <Button big variant="secondary" onClick={() => setVerPalabra(true)}>
            Ver palabra 🙈 (solo si te toca actuar)
          </Button>
        )}
        {verPalabra && word != null && (
          <div style={{ display: 'flex', gap: 8 }}>
            <Button big style={{ flex: 1 }} onClick={() => { setVerPalabra(false); void act('next_word') }}>
              Siguiente palabra →
            </Button>
            <Button variant="ghost" onClick={() => setVerPalabra(false)}>Tapar 🙈</Button>
          </div>
        )}
      </div>
    )
  }
  const header = (
    <div style={{ display: 'grid', gap: 6 }}>
      <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase' }}>
        Ronda {st.round ?? 1}/3 · {ROUND_NAME[st.round ?? 1]} · quedan {st.remaining?.length ?? 0}
      </p>
      <div style={{ display: 'flex', gap: 10, fontFamily: 'var(--font-display)', fontSize: '1.1rem' }}>
        <span style={{ color: 'var(--amber)' }}>Equipo A: {scores.A}</span>
        <span style={{ color: 'var(--coral)' }}>Equipo B: {scores.B}</span>
        {myTeam && <span style={{ color: 'var(--muted)', fontSize: '0.85rem', alignSelf: 'center' }}>(eres {myTeam})</span>}
      </div>
    </div>
  )

  if (st.phase === 'entre') {
    // quién sigue: el próximo en turn_order (para que se sepa a quién le toca)
    const order = st.turn_order ?? []
    const nextId = order.length > 0 ? order[((st.turn_idx ?? -1) + 1) % order.length] : undefined
    const next = players.find((p) => p.id === nextId)
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        {header}
        <Card accent="var(--amber)" style={{ display: 'grid', gap: 6 }}>
          <p style={{ fontWeight: 700 }}>
            {ROUND_NAME[st.round ?? 1]} — sigue: <span style={{ color: 'var(--amber)' }}>
              {next ? `${next.name} (equipo ${st.teams?.[next.id] ?? '?'})` : '…'}</span>
          </p>
          <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.85rem' }}>
            {next?.id === me.id ? '¡Te toca a TI! Tu equipo adivina lo que hagas.' : 'Cuando esté listo, ¡dale!'}
          </p>
        </Card>
        <Button big onClick={() => void advance(false)}>¡Empezar turno! ▶️</Button>
      </div>
    )
  }

  if (st.phase === 'turno') {
    const soyActor = me.id === actorId
    const word = st.remaining?.[0]
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        {header}
        {soyActor ? (
          <>
            <motion.div key={word} initial={{ scale: 0.9 }} animate={{ scale: 1 }}
              transition={{ type: 'spring', stiffness: 300, damping: 16 }}>
              <Card accent="var(--amber)" style={{ minHeight: 90, display: 'grid', placeItems: 'center' }}>
                <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.5rem', textAlign: 'center' }}>{word ?? '…'}</p>
              </Card>
            </motion.div>
            <Button big onClick={() => void act('got')}>¡La adivinaron! +1 ✅</Button>
            <div style={{ display: 'flex', gap: 8 }}>
              <Button variant="secondary" onClick={() => void act('pass')}>Pasar ↻</Button>
              <Button variant="danger" onClick={() => void act('end_turn')}>Terminar turno</Button>
            </div>
          </>
        ) : (
          <Card style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            {actor && <AvatarBlock avatar={actor.avatar} size={30} />}
            <p style={{ fontWeight: 700 }}>
              {actor?.name ?? '?'} (equipo {st.teams?.[actorId ?? ''] ?? '?'}) tiene la palabra —
              {st.teams?.[actorId ?? ''] === myTeam ? ' ¡GRITA LO QUE SEA! 📣' : ' shhh, no es tu equipo 🤫'}
            </p>
          </Card>
        )}
      </div>
    )
  }

  if (st.phase === 'podio') {
    const winner = scores.A === scores.B ? null : scores.A > scores.B ? 'A' : 'B'
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        {header}
        <motion.div initial={{ scale: 0.7 }} animate={{ scale: 1 }}
          transition={{ type: 'spring', stiffness: 300, damping: 14 }}>
          <Card accent={winner === 'A' ? 'var(--amber)' : winner === 'B' ? 'var(--coral)' : undefined}>
            <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.4rem', textAlign: 'center' }}>
              {winner ? `¡Ganó el equipo ${winner}! 🏆` : '¡Empate! 🤝'}
            </p>
            <p style={{ fontWeight: 700, textAlign: 'center' }}>A {scores.A} · B {scores.B}</p>
          </Card>
        </motion.div>
      </div>
    )
  }

  return null
}

function TresRondasHost({ ctx }: { ctx: GameCtx<TrState> }) {
  const { state: st, advance } = ctx
  if (st.mode_base) {
    return <Button variant="ghost" onClick={() => void advance(true)}>Terminar juego 🏁</Button>
  }
  if (st.phase === 'podio') {
    return <Button big onClick={() => void advance(true)}>Terminar juego 🏁</Button>
  }
  return null
}

const PHASE_TITLE: Record<string, string> = {
  base: 'Equipos y palabras',
  entre: 'Prepárense…',
  turno: '¡A gritar!',
  podio: 'El veredicto',
}

export const tresRondasGame: GameDefinition<TrState> = {
  id: 'tres-rondas',
  nameEs: 'Charadas',
  phaseTitle: (st) => PHASE_TITLE[st.phase] ?? st.phase,
  PlayerView: TresRondasView,
  HostView: TresRondasHost,
}
