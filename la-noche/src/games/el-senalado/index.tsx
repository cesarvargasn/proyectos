import { motion } from 'framer-motion'
import type { GameCtx, GameDefinition, GameState } from '../../engine/types'
import { VoteGrid } from '../../engine/primitives'
import { Button } from '../../ui/Button'
import { Card } from '../../ui/Card'
import { AvatarBlock } from '../../ui/Avatar'

/**
 * El Señalado (006): "¿quién es más probable que…?". Aquí el celular sí
 * aporta: voto secreto simultáneo (nadie arrastra a nadie) y reveal en
 * bar chart. El señalado se identifica por etiqueta + posición, no solo
 * por color; nombres y números van en tinta, la barra lleva el color
 * del avatar de cada quien.
 */
interface SenaladoState extends GameState {
  deck?: { text: string; intensity: number }[]
  round_idx?: number
  votes?: Record<string, string>
}

const FIRE = ['', '🌱', '🙂', '🌶', '🔥', '💀']

function CardBanner({ st }: { st: SenaladoState }) {
  const card = st.deck?.[st.round_idx ?? 0]
  return (
    <div style={{ display: 'grid', gap: 10 }}>
      <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase' }}>
        Carta {(st.round_idx ?? 0) + 1} de {st.deck?.length ?? 0} · {FIRE[card?.intensity ?? 0]}
      </p>
      <motion.div key={st.round_idx} initial={{ scale: 0.9, rotate: -1.5 }} animate={{ scale: 1, rotate: 0 }}
        transition={{ type: 'spring', stiffness: 300, damping: 18 }}>
        <Card accent="var(--coral)" style={{ minHeight: 110, display: 'grid', placeItems: 'center', textAlign: 'center' }}>
          <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.3rem', lineHeight: 1.25 }}>
            {card?.text ?? '…'}
          </p>
        </Card>
      </motion.div>
    </div>
  )
}

function SenaladoView({ ctx }: { ctx: GameCtx<SenaladoState> }) {
  const { state: st, players, me, act } = ctx
  const votes = st.votes ?? {}

  if (st.phase === 'voto') {
    return (
      <div style={{ display: 'grid', gap: 16 }}>
        <CardBanner st={st} />
        <VoteGrid
          players={players}
          meId={me.id}
          votedFor={votes[me.id] ?? null}
          onVote={(id) => void act('vote', { target: id })}
        />
        <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>
          {votes[me.id] ? 'Voto guardado (puedes cambiarlo)' : 'Vota en secreto…'}
          {' · '}{Object.keys(votes).length}/{players.length}
        </p>
      </div>
    )
  }

  if (st.phase === 'reveal') {
    const counts = players
      .map((p) => ({ p, n: Object.values(votes).filter((v) => v === p.id).length }))
      .filter((r) => r.n > 0)
      .sort((a, b) => b.n - a.n)
    const max = counts[0]?.n ?? 0
    const rows = counts.length

    return (
      <div style={{ display: 'grid', gap: 16 }}>
        <CardBanner st={st} />
        {rows === 0 ? (
          <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.2rem', color: 'var(--muted)' }}>
            Nadie votó 😴
          </p>
        ) : (
          <div style={{ display: 'grid', gap: 10 }}>
            {counts.map(({ p, n }, i) => {
              const winner = n === max
              // drumroll: los de abajo aparecen primero, el señalado cae de último
              const delay = 0.45 * (rows - 1 - i)
              return (
                <motion.div key={p.id} initial={{ opacity: 0, x: -24 }} animate={{ opacity: 1, x: 0 }}
                  transition={{ delay, type: 'spring', stiffness: 300, damping: 20 }}
                  style={{ display: 'grid', gap: 4 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                    <AvatarBlock avatar={p.avatar} size={28} />
                    <span style={{ fontWeight: 700, flex: 1 }}>{p.name}</span>
                    {winner && (
                      <motion.span initial={{ scale: 0 }} animate={{ scale: 1 }}
                        transition={{ delay: delay + 0.35, type: 'spring', stiffness: 400, damping: 12 }}
                        style={{ fontFamily: 'var(--font-display)', fontSize: '0.8rem', color: '#000', background: 'var(--coral)', border: '2px solid #000', padding: '2px 8px' }}>
                        EL SEÑALADO 🫵
                      </motion.span>
                    )}
                  </div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <div style={{ flex: 1, height: 22, border: 'var(--border-thin)' }}>
                      <motion.div initial={{ width: 0 }} animate={{ width: `${(n / max) * 100}%` }}
                        transition={{ delay: delay + 0.15, type: 'spring', stiffness: 160, damping: 22 }}
                        style={{ height: '100%', background: p.avatar.color || 'var(--amber)' }} />
                    </div>
                    <span style={{ fontFamily: 'var(--font-display)', minWidth: 24, textAlign: 'right' }}>{n}</span>
                  </div>
                </motion.div>
              )
            })}
          </div>
        )}
      </div>
    )
  }

  return null
}

function SenaladoHost({ ctx }: { ctx: GameCtx<SenaladoState> }) {
  const { state: st, advance } = ctx
  if (st.phase !== 'reveal') return null
  const last = (st.round_idx ?? 0) + 1 >= (st.deck?.length ?? 0)
  return (
    <Button big onClick={() => void advance(true)}>
      {last ? 'Terminar juego 🏁' : 'Siguiente carta →'}
    </Button>
  )
}

const PHASE_TITLE: Record<string, string> = {
  voto: '¿Quién es más probable…?',
  reveal: 'El veredicto',
}

export const senaladoGame: GameDefinition<SenaladoState> = {
  id: 'el-senalado',
  nameEs: 'El Más Probable',
  phaseTitle: (st) => PHASE_TITLE[st.phase] ?? st.phase,
  PlayerView: SenaladoView,
  HostView: SenaladoHost,
}
