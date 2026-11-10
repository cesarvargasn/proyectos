import { motion } from 'framer-motion'
import type { GameCtx, GameDefinition, GameState } from '../../engine/types'
import { renderCardText } from '../../engine/cardText'
import { Button } from '../../ui/Button'
import { Card } from '../../ui/Card'
import { AvatarBlock } from '../../ui/Avatar'

/**
 * Verdad o Reto (007/022): rotación de turno; el del turno elige en su cel,
 * la carta sale en TODAS las pantallas y la sala hace el resto. Cumplí/Paso
 * SOLO pasa el turno — el grupo es el juez en vivo, sin castigos de app.
 * Regla: 2 verdades seguidas → la tercera es RETO obligado (server).
 */
interface VoRState extends GameState {
  turn_order?: string[]
  turn_idx?: number
  turn_no?: number
  total_turns?: number
  choice?: 'verdad' | 'reto' | null
  card?: { text: string; intensity: number } | null
  rerolled?: boolean
  streaks?: Record<string, number>
}

function turnPlayer(ctx: GameCtx<VoRState>) {
  const st = ctx.state
  return ctx.players.find((p) => p.id === st.turn_order?.[st.turn_idx ?? 0])
}

function VoRView({ ctx }: { ctx: GameCtx<VoRState> }) {
  const { state: st, me, act, settings } = ctx
  const turno = turnPlayer(ctx)
  const esMiTurno = turno?.id === me.id

  const header = (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
      {turno && <AvatarBlock avatar={turno.avatar} size={32} />}
      <p style={{ fontWeight: 700, flex: 1 }}>
        {esMiTurno ? 'TU TURNO' : `Turno de ${turno?.name ?? '…'}`}
      </p>
      <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem' }}>
        {st.turn_no ?? 0}/{st.total_turns ?? 0}
      </p>
    </div>
  )

  if (st.phase === 'elegir') {
    const retoObligado = (st.streaks?.[turno?.id ?? ''] ?? 0) >= 2
    return (
      <div style={{ display: 'grid', gap: 16 }}>
        {header}
        {retoObligado && (
          <Card accent="var(--coral)">
            <p style={{ fontWeight: 700, textAlign: 'center' }}>
              😈 {esMiTurno ? 'Llevas' : `${turno?.name} lleva`} 2 verdades seguidas — la tercera es RETO obligado
            </p>
          </Card>
        )}
        {esMiTurno ? (
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <Button big disabled={retoObligado} style={retoObligado ? { opacity: 0.35 } : undefined}
              onClick={() => { if (!retoObligado) void act('choose', { value: 'verdad' }) }}>
              VERDAD 🗣
            </Button>
            <Button big variant="danger" onClick={() => void act('choose', { value: 'reto' })}>RETO 😈</Button>
          </div>
        ) : (
          <Card style={{ textAlign: 'center' }}>
            <p style={{ color: 'var(--muted)', fontWeight: 700 }}>{turno?.name} está eligiendo…</p>
          </Card>
        )}
      </div>
    )
  }

  if (st.phase === 'carta' && st.card) {
    const esReto = st.choice === 'reto'
    return (
      <div style={{ display: 'grid', gap: 16 }}>
        {header}
        <p style={{ fontFamily: 'var(--font-display)', color: esReto ? 'var(--coral)' : 'var(--amber)', textTransform: 'uppercase' }}>
          {esReto ? 'RETO 😈' : 'VERDAD 🗣'}
        </p>
        <motion.div key={`${st.turn_no}-${st.rerolled}`} initial={{ scale: 0.9, rotate: -1.5 }} animate={{ scale: 1, rotate: 0 }}
          transition={{ type: 'spring', stiffness: 300, damping: 18 }}>
          <Card accent={esReto ? 'var(--coral)' : 'var(--amber)'} style={{ minHeight: 150, display: 'grid', placeItems: 'center', textAlign: 'center', padding: 20 }}>
            <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.4rem', lineHeight: 1.3 }}>
              {renderCardText(st.card.text, undefined, settings.mode)}
            </p>
          </Card>
        </motion.div>
        {esMiTurno && (
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <Button big onClick={() => void act('done')}>Cumplí ✓</Button>
            <Button big variant="ghost" onClick={() => void act('done')}>Paso →</Button>
          </div>
        )}
      </div>
    )
  }

  return null
}

function VoRHost({ ctx }: { ctx: GameCtx<VoRState> }) {
  const { state: st, act } = ctx
  if (st.phase !== 'carta' || st.rerolled) return null
  return (
    <Button variant="ghost" onClick={() => void act('reroll')}>
      🎲 Cambiar carta (1 por turno)
    </Button>
  )
}

export const vorGame: GameDefinition<VoRState> = {
  id: 'verdad-o-reto',
  nameEs: 'Verdad o Reto',
  phaseTitle: (st) => (st.phase === 'elegir' ? '¿Verdad o reto?' : 'Cumple o paga'),
  PlayerView: VoRView,
  HostView: VoRHost,
}
