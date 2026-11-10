import { motion } from 'framer-motion'
import { Card } from '../ui/Card'
import { AvatarBlock } from '../ui/Avatar'
import type { Player } from '../lib/types'

/**
 * Podio compartido de Wave 2: drumroll de último a primero,
 * el ganador cae de último con badge. scores = {playerId: puntos}.
 */
export function Podium({ players, scores, unit = 'pts' }: {
  players: Player[]
  scores: Record<string, number>
  unit?: string
}) {
  const rows = players
    .map((p) => ({ p, n: scores[p.id] ?? 0 }))
    .sort((a, b) => b.n - a.n)
  const medals = ['🥇', '🥈', '🥉']

  return (
    <div style={{ display: 'grid', gap: 10 }}>
      {rows.map(({ p, n }, i) => {
        // los de abajo aparecen primero, el ganador de último
        const delay = 0.4 * (rows.length - 1 - i)
        return (
          <motion.div key={p.id} initial={{ opacity: 0, y: 18 }} animate={{ opacity: 1, y: 0 }}
            transition={{ delay, type: 'spring', stiffness: 300, damping: 20 }}>
            <Card accent={i === 0 ? 'var(--amber)' : undefined}
              style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
              <span style={{ fontFamily: 'var(--font-display)', fontSize: '1.2rem', minWidth: 34 }}>
                {medals[i] ?? `${i + 1}º`}
              </span>
              <AvatarBlock avatar={p.avatar} size={32} />
              <span style={{ fontWeight: 700, flex: 1, overflow: 'hidden', textOverflow: 'ellipsis' }}>{p.name}</span>
              <span style={{ fontFamily: 'var(--font-display)', fontSize: '1.2rem', color: i === 0 ? 'var(--amber)' : 'var(--ink)' }}>
                {n} {unit}
              </span>
            </Card>
          </motion.div>
        )
      })}
    </div>
  )
}
