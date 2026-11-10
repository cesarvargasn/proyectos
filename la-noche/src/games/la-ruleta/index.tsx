import { useEffect, useState } from 'react'
import { motion } from 'framer-motion'
import type { GameCtx, GameDefinition, GameState } from '../../engine/types'
import { renderCardText } from '../../engine/cardText'
import { Button } from '../../ui/Button'
import { Card } from '../../ui/Card'

/**
 * La Ruleta (007/022): stream de cartas tipo Picolo con escalación 1→5.
 * Sin acciones de jugador: la sala ejecuta, el host pasa. Countdown
 * opcional al pasar carta (host grita "¡saquen el cel!", 3-2-1, carta).
 */
interface RuletaState extends GameState {
  deck?: { text: string; intensity: number; card_type: string }[]
  round_idx?: number
  slots?: Record<string, string>
  rules?: string[]
  countdown_s?: number
}

const TYPE_STYLE: Record<string, { label: string; color: string }> = {
  directa: { label: 'DIRECTA', color: 'var(--amber)' },
  grupal: { label: 'TODOS', color: '#7ED957' },
  duelo: { label: 'DUELO', color: 'var(--coral)' },
  reto: { label: 'RETO', color: '#C792EA' },
  regla: { label: 'REGLA NUEVA', color: '#5CB8FF' },
}

/** segundos que faltan para phase_ends_at (0 = ya pasó / no hay) */
function useCountdown(endsAt: string | null) {
  const [left, setLeft] = useState(() =>
    endsAt ? Math.max(0, new Date(endsAt).getTime() - Date.now()) : 0)
  useEffect(() => {
    if (!endsAt) { setLeft(0); return }
    const tick = () => setLeft(Math.max(0, new Date(endsAt).getTime() - Date.now()))
    tick()
    const id = setInterval(tick, 200)
    return () => clearInterval(id)
  }, [endsAt])
  return left
}

function RuletaView({ ctx }: { ctx: GameCtx<RuletaState> }) {
  const { state: st, settings } = ctx
  const card = st.deck?.[st.round_idx ?? 0]
  const tipo = TYPE_STYLE[card?.card_type ?? ''] ?? TYPE_STYLE.directa
  const rules = st.rules ?? []
  const msLeft = useCountdown(st.phase_ends_at)
  const cocinando = msLeft > 0

  return (
    <div style={{ display: 'grid', gap: 14 }}>
      {rules.length > 0 && (
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {rules.map((r, i) => (
            <span key={i} style={{ fontSize: '0.72rem', fontWeight: 700, background: '#5CB8FF', color: '#000', border: '2px solid #000', padding: '3px 8px' }}>
              📌 {renderCardText(r, st.slots, settings.mode)}
            </span>
          ))}
        </div>
      )}
      <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase' }}>
        Carta {(st.round_idx ?? 0) + 1} de {st.deck?.length ?? 0}
      </p>
      {cocinando ? (
        <motion.div key={`cd-${st.round_idx}`} initial={{ scale: 0.8 }} animate={{ scale: 1 }}>
          <Card accent="var(--coral)" style={{ minHeight: 180, display: 'grid', placeItems: 'center', padding: 22 }}>
            <motion.p key={Math.ceil(msLeft / 1000)}
              initial={{ scale: 1.8, opacity: 0.4 }} animate={{ scale: 1, opacity: 1 }}
              style={{ fontFamily: 'var(--font-display)', fontSize: '4rem', color: 'var(--coral)' }}>
              {Math.ceil(msLeft / 1000)}
            </motion.p>
          </Card>
        </motion.div>
      ) : (
        <motion.div key={st.round_idx} initial={{ scale: 0.9, rotate: -1.5 }} animate={{ scale: 1, rotate: 0 }}
          transition={{ type: 'spring', stiffness: 300, damping: 18 }}>
          <Card accent={tipo.color} style={{ minHeight: 180, display: 'grid', alignContent: 'center', gap: 12, textAlign: 'center', padding: 22 }}>
            <span style={{ fontFamily: 'var(--font-display)', fontSize: '0.8rem', color: tipo.color, textTransform: 'uppercase' }}>
              {tipo.label}
            </span>
            <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.45rem', lineHeight: 1.3 }}>
              {card ? renderCardText(card.text, st.slots, settings.mode) : '…'}
            </p>
          </Card>
        </motion.div>
      )}
    </div>
  )
}

function RuletaHost({ ctx }: { ctx: GameCtx<RuletaState> }) {
  const { state: st, advance } = ctx
  const last = (st.round_idx ?? 0) + 1 >= (st.deck?.length ?? 0)
  return (
    <Button big onClick={() => void advance(true)}>
      {last ? 'Terminar juego 🏁' : 'Siguiente carta →'}
    </Button>
  )
}

export const ruletaGame: GameDefinition<RuletaState> = {
  id: 'la-ruleta',
  nameEs: 'La Ruleta',
  phaseTitle: () => 'La Ruleta',
  PlayerView: RuletaView,
  HostView: RuletaHost,
}
