import { motion } from 'framer-motion'
import type { GameCtx, GameDefinition, GameState } from '../../engine/types'
import { renderCardText } from '../../engine/cardText'
import { Button } from '../../ui/Button'
import { Card } from '../../ui/Card'
import { AvatarBlock } from '../../ui/Avatar'

/**
 * El Rey (007/022): baraja virtual de 52, turno rotativo, reglas por rango
 * data-driven (editar aquí = editar el juego). 4º rey = fin.
 * Fase 'reveal': tras sacar se ve QUIÉN sacó y la carta; el turno rota
 * cuando el que sacó (o el host) da "Siguiente" — nadie se salta la regla.
 */
interface ReyState extends GameState {
  deck?: { r: string; s: string }[]
  idx?: number
  turn_order?: string[]
  turn_idx?: number
  kings?: number
  last_card?: { r: string; s: string } | null
}

// Reglas A–K — texto original, {drink:N} se resuelve por modo.
const REGLAS: Record<string, { titulo: string; regla: string }> = {
  A: { titulo: 'Cascada', regla: 'Todos {drink:1}, en cadena empezando por quien sacó la carta.' },
  '2': { titulo: 'Tú eliges', regla: 'Señala a alguien: {drink:1}.' },
  '3': { titulo: 'Para ti', regla: 'Quien sacó la carta {drink:1}.' },
  '4': { titulo: 'Al piso', regla: 'Todos tocan el piso: el último {drink:1}.' },
  '5': { titulo: 'Al cielo', regla: 'Todos levantan la mano: el último {drink:1}.' },
  '6': { titulo: 'Espejo', regla: 'Elige tu espejo: cada vez que tú tomes, esa persona también {drink:1}.' },
  '7': { titulo: 'Sietes', regla: 'Cuenten en ronda; en cada múltiplo de 7 se aplaude en vez de decirlo. El que falle {drink:1}.' },
  '8': { titulo: 'Historia', regla: 'Di una palabra; en ronda cada uno repite todo y agrega una. El que falle {drink:1}.' },
  '9': { titulo: 'Rima', regla: 'Di una palabra; en ronda cada uno la rima. El que falle {drink:1}.' },
  '10': { titulo: 'Categorías', regla: 'Di una categoría; en ronda cada uno da un ejemplo. El que se quede {drink:1}.' },
  J: { titulo: 'Regla nueva', regla: 'Inventa una regla para el resto de la partida. Quien la rompa {drink:1}.' },
  Q: { titulo: 'Preguntas', regla: 'Desde ya, solo se habla con preguntas. El primero que afirme algo {drink:1}.' },
  K: { titulo: 'EL REY', regla: 'Rey a la vista. El 4º rey paga el castigo real: {drink:3}.' },
}

const ROJO = new Set(['♥', '♦'])

function CartaGrande({ card }: { card: { r: string; s: string } }) {
  return (
    <motion.div key={card.r + card.s} initial={{ rotateY: 90, scale: 0.8 }} animate={{ rotateY: 0, scale: 1 }}
      transition={{ type: 'spring', stiffness: 260, damping: 20 }}>
      <Card style={{ display: 'grid', placeItems: 'center', padding: 20, background: 'var(--ink)' }}>
        <span style={{ fontFamily: 'var(--font-display)', fontSize: '3.2rem', color: ROJO.has(card.s) ? 'var(--coral)' : '#000', lineHeight: 1 }}>
          {card.r}{card.s}
        </span>
      </Card>
    </motion.div>
  )
}

function ReyView({ ctx }: { ctx: GameCtx<ReyState> }) {
  const { state: st, players, me, act, settings } = ctx
  const turno = players.find((p) => p.id === st.turn_order?.[st.turn_idx ?? 0])
  const esMiTurno = turno?.id === me.id
  const card = st.last_card
  const regla = card ? REGLAS[card.r] : null

  if (st.phase === 'fin') {
    return (
      <div style={{ display: 'grid', gap: 16, justifyItems: 'center', textAlign: 'center' }}>
        {card && <CartaGrande card={card} />}
        <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.6rem', color: 'var(--coral)' }}>
          {st.kings === 4 ? '¡SALIÓ EL 4º REY! 👑' : 'Se acabó la baraja'}
        </p>
        {st.kings === 4 && (
          <p style={{ fontWeight: 700 }}>{renderCardText(REGLAS.K.regla, undefined, settings.mode)}</p>
        )}
      </div>
    )
  }

  const header = (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
      {turno && <AvatarBlock avatar={turno.avatar} size={32} />}
      <p style={{ fontWeight: 700, flex: 1 }}>
        {st.phase === 'reveal'
          ? (esMiTurno ? 'SACASTE TÚ' : `Sacó ${turno?.name ?? '…'}`)
          : (esMiTurno ? 'TU TURNO' : `Saca ${turno?.name ?? '…'}`)}
      </p>
      <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem' }}>
        👑 {st.kings ?? 0}/4 · {(st.deck?.length ?? 52) - (st.idx ?? 0)} cartas
      </p>
    </div>
  )

  // reveal: la carta recién sacada, con su dueño; el turno rota al dar "Siguiente"
  if (st.phase === 'reveal' && card && regla) {
    return (
      <div style={{ display: 'grid', gap: 16 }}>
        {header}
        <div style={{ display: 'grid', gap: 12, justifyItems: 'center', textAlign: 'center' }}>
          <CartaGrande card={card} />
          <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.1rem', color: 'var(--amber)', textTransform: 'uppercase' }}>
            {regla.titulo}
          </p>
          <p style={{ fontWeight: 700 }}>{renderCardText(regla.regla, undefined, settings.mode)}</p>
        </div>
        {esMiTurno && (
          <Button big onClick={() => void act('next')}>Listo, siguiente →</Button>
        )}
      </div>
    )
  }

  return (
    <div style={{ display: 'grid', gap: 16 }}>
      {header}

      {card && regla ? (
        <div style={{ display: 'grid', gap: 12, justifyItems: 'center', textAlign: 'center' }}>
          <CartaGrande card={card} />
          <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.1rem', color: 'var(--amber)', textTransform: 'uppercase' }}>
            {regla.titulo}
          </p>
          <p style={{ fontWeight: 700 }}>{renderCardText(regla.regla, undefined, settings.mode)}</p>
        </div>
      ) : (
        <Card style={{ textAlign: 'center' }}>
          <p style={{ color: 'var(--muted)', fontWeight: 700 }}>La baraja está lista. 👑 4 reyes escondidos.</p>
        </Card>
      )}

      {esMiTurno && (
        <Button big onClick={() => void act('draw')}>Sacar carta 🃏</Button>
      )}
    </div>
  )
}

function ReyHost({ ctx }: { ctx: GameCtx<ReyState> }) {
  const { state: st, me, act, advance } = ctx
  if (st.phase === 'reveal' && st.turn_order?.[st.turn_idx ?? 0] !== me.id) {
    return <Button variant="secondary" onClick={() => void act('next')}>Siguiente (host) →</Button>
  }
  if (st.phase !== 'fin') return null
  return (
    <Button big onClick={() => void advance(true)}>Volver al lobby 🏁</Button>
  )
}

export const reyGame: GameDefinition<ReyState> = {
  id: 'el-rey',
  nameEs: 'El Rey',
  phaseTitle: (st) => (st.phase === 'fin' ? 'Larga vida al rey' : st.phase === 'reveal' ? 'Salió la carta' : 'El Rey'),
  PlayerView: ReyView,
  HostView: ReyHost,
}
