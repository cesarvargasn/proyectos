import { motion } from 'framer-motion'
import type { GameCtx, GameDefinition, GameState } from '../../engine/types'
import { Button } from '../../ui/Button'
import { Card } from '../../ui/Card'
import { AvatarBlock } from '../../ui/Avatar'

/**
 * Paranoia (013): la pregunta aparece SOLO en el celular del Preguntón
 * (player_secrets). La lee en silencio y señala a alguien diciendo su
 * nombre EN VOZ ALTA. El señalado decide: modo trago = paga un trago por
 * ver la pregunta o la entierra; modo social = moneda al aire del server.
 * Sin puntos — la paranoia ES el juego.
 */
interface PaState extends GameState {
  deck?: { id: string }[]
  round_idx?: number
  turn_order?: string[]
  turn_idx?: number
  target?: string | null
  decision?: 'pago' | 'enterrada' | 'cara' | 'sello' | null
  question?: string | null
}

function ParanoiaView({ ctx }: { ctx: GameCtx<PaState> }) {
  const { state: st, players, me, act, secret, settings } = ctx
  const asker = players.find((p) => p.id === st.turn_order?.[st.turn_idx ?? 0])
  const target = players.find((p) => p.id === st.target)
  const drinking = settings.mode === 'drinking'
  const header = (
    <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase' }}>
      Pregunta {(st.round_idx ?? 0) + 1} de {st.deck?.length ?? 0} · pregunta: {asker?.name ?? '?'} 🤫
    </p>
  )

  if (st.phase === 'senalar') {
    const soyAsker = me.id === asker?.id
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        {header}
        {soyAsker ? (
          <>
            <Card accent="var(--amber)">
              <p style={{ fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase', color: 'var(--muted)' }}>
                Solo tú ves esto 🤫
              </p>
              <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.2rem', lineHeight: 1.3 }}>
                {String(secret?.question ?? '…')}
              </p>
            </Card>
            <p style={{ fontWeight: 700, textAlign: 'center' }}>
              Léela en silencio. Toca tu respuesta y DI SU NOMBRE en voz alta:
            </p>
            <div style={{ display: 'grid', gap: 8, gridTemplateColumns: 'repeat(auto-fill, minmax(140px, 1fr))' }}>
              {players.filter((p) => p.id !== me.id).map((p) => (
                <motion.button key={p.id} whileTap={{ scale: 0.95 }}
                  onClick={() => void act('point', { target: p.id })}
                  style={{ display: 'flex', alignItems: 'center', gap: 8, padding: 10, cursor: 'pointer',
                    background: 'var(--surface)', color: 'var(--ink)', border: 'var(--border)' }}>
                  <AvatarBlock avatar={p.avatar} size={26} />
                  <span style={{ fontWeight: 700, overflow: 'hidden', textOverflow: 'ellipsis' }}>{p.name}</span>
                </motion.button>
              ))}
            </div>
          </>
        ) : (
          <Card>
            <p style={{ fontWeight: 700, textAlign: 'center' }}>
              👀 {asker?.name ?? '?'} está leyendo una pregunta secreta…<br />va a señalar a alguien.
            </p>
          </Card>
        )}
      </div>
    )
  }

  if (st.phase === 'decidir') {
    const soyTarget = me.id === st.target
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        {header}
        <motion.div initial={{ scale: 0.8 }} animate={{ scale: 1 }}
          transition={{ type: 'spring', stiffness: 300, damping: 15 }}>
          <Card accent="var(--coral)" style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            {target && <AvatarBlock avatar={target.avatar} size={32} />}
            <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.15rem' }}>
              ¡{asker?.name ?? '?'} señaló a {target?.name ?? '?'}! 🫵
            </p>
          </Card>
        </motion.div>
        {soyTarget ? (
          drinking ? (
            <div style={{ display: 'grid', gap: 8 }}>
              <p style={{ fontWeight: 700, textAlign: 'center' }}>¿Quieres saber POR QUÉ te señalaron?</p>
              <Button big onClick={() => void act('decide', { pay: true })}>Tomo 1 y revelan la pregunta 🍺</Button>
              <Button big variant="danger" onClick={() => void act('decide', { pay: false })}>Me lo llevo a la tumba 🤐</Button>
            </div>
          ) : (
            <div style={{ display: 'grid', gap: 8 }}>
              <p style={{ fontWeight: 700, textAlign: 'center' }}>La moneda decide si la pregunta se revela…</p>
              <Button big onClick={() => void act('decide', {})}>Lanzar la moneda 🪙</Button>
            </div>
          )
        ) : (
          <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>
            {drinking ? `${target?.name ?? '?'} decide si paga por la verdad…` : `${target?.name ?? '?'} lanza la moneda…`}
          </p>
        )}
      </div>
    )
  }

  if (st.phase === 'reveal') {
    const revelada = st.question != null
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        {header}
        <motion.div initial={{ scale: 0.7 }} animate={{ scale: 1 }}
          transition={{ type: 'spring', stiffness: 300, damping: 14 }}>
          {revelada ? (
            <Card accent="var(--amber)" style={{ display: 'grid', gap: 8 }}>
              <p style={{ fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase', color: 'var(--muted)' }}>
                La pregunta era{st.decision === 'cara' ? ' (cayó cara 🪙)' : ''}:
              </p>
              <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.25rem', lineHeight: 1.3 }}>{st.question}</p>
              <p style={{ fontWeight: 700 }}>…y la respuesta fue <span style={{ color: 'var(--coral)' }}>{target?.name ?? '?'}</span> 🫵</p>
            </Card>
          ) : (
            <Card style={{ display: 'grid', gap: 8 }}>
              <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.25rem' }}>
                ☠️ La pregunta quedó enterrada{st.decision === 'sello' ? ' (cayó sello 🪙)' : ''}.
              </p>
              <p style={{ fontWeight: 700, color: 'var(--muted)' }}>
                {target?.name ?? '?'} jamás sabrá por qué lo señalaron. Eso es la paranoia.
              </p>
            </Card>
          )}
        </motion.div>
      </div>
    )
  }

  return null
}

function ParanoiaHost({ ctx }: { ctx: GameCtx<PaState> }) {
  const { state: st, advance } = ctx
  if (st.phase === 'reveal') {
    const last = (st.round_idx ?? 0) + 1 >= (st.deck?.length ?? 0)
    return <Button big onClick={() => void advance(true)}>{last ? 'Terminar juego 🏁' : 'Siguiente pregunta →'}</Button>
  }
  if (st.phase === 'senalar') {
    return <Button variant="danger" onClick={() => void advance(true)}>Preguntón dormido → saltar turno</Button>
  }
  return null
}

const PHASE_TITLE: Record<string, string> = {
  senalar: 'La pregunta secreta',
  decidir: '¿Pagas por la verdad?',
  reveal: 'El veredicto',
}

export const paranoiaGame: GameDefinition<PaState> = {
  id: 'paranoia',
  nameEs: 'Paranoia',
  phaseTitle: (st) => PHASE_TITLE[st.phase] ?? st.phase,
  needsSecret: (st) => st.phase === 'senalar',
  PlayerView: ParanoiaView,
  HostView: ParanoiaHost,
}
