import { motion } from 'framer-motion'
import type { GameCtx, GameDefinition, GameState } from '../../engine/types'
import { Button } from '../../ui/Button'
import { Card } from '../../ui/Card'

/**
 * Yo Nunca v2 (005): puro banco de cartas. El sí/no, las risas y los
 * tragos pasan en la sala; la app solo pone la carta en todas las
 * pantallas y el host pasa a la siguiente.
 */
interface YoNuncaState extends GameState {
  deck?: { text: string; intensity: number }[]
  round_idx?: number
}

const FIRE = ['', '🌱', '🙂', '🌶', '🔥', '💀']

function YoNuncaView({ ctx }: { ctx: GameCtx<YoNuncaState> }) {
  const { state: st } = ctx
  const card = st.deck?.[st.round_idx ?? 0]
  return (
    <div style={{ display: 'grid', gap: 12 }}>
      <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase' }}>
        Carta {(st.round_idx ?? 0) + 1} de {st.deck?.length ?? 0} · {FIRE[card?.intensity ?? 0]}
      </p>
      <motion.div key={st.round_idx} initial={{ scale: 0.9, rotate: -1.5 }} animate={{ scale: 1, rotate: 0 }}
        transition={{ type: 'spring', stiffness: 300, damping: 18 }}>
        <Card accent="var(--amber)" style={{ minHeight: 180, display: 'grid', placeItems: 'center', textAlign: 'center', padding: 24 }}>
          <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.6rem', lineHeight: 1.25 }}>
            {card?.text ?? '…'}
          </p>
        </Card>
      </motion.div>
      <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>
        El que sí… ya sabe qué hacer 🍻
      </p>
    </div>
  )
}

function YoNuncaHost({ ctx }: { ctx: GameCtx<YoNuncaState> }) {
  const { state: st, advance } = ctx
  const last = (st.round_idx ?? 0) + 1 >= (st.deck?.length ?? 0)
  return (
    <Button big onClick={() => void advance(true)}>
      {last ? 'Terminar juego 🏁' : 'Siguiente carta →'}
    </Button>
  )
}

export const yoNuncaGame: GameDefinition<YoNuncaState> = {
  id: 'yo-nunca',
  nameEs: 'Yo Nunca',
  phaseTitle: () => 'Yo nunca…',
  PlayerView: YoNuncaView,
  HostView: YoNuncaHost,
}
