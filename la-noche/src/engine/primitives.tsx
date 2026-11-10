import { useEffect, useState } from 'react'
import { motion } from 'framer-motion'
import { Button } from '../ui/Button'
import { Card } from '../ui/Card'
import { Input } from '../ui/Input'
import { AvatarBlock } from '../ui/Avatar'
import type { Player } from '../lib/types'

/* ============================================================
   Las 5 primitivas compartidas (fase 2) + kit de reveal.
   Todas puramente presentacionales: reciben estado, emiten acciones.
   ============================================================ */

/** 1. TIMER — cuenta regresiva anclada al server (phase_ends_at). */
export function TimerBar({ endsAt, onExpire }: { endsAt: string | null; onExpire?: () => void }) {
  const [left, setLeft] = useState(0)
  useEffect(() => {
    if (!endsAt) return
    const end = new Date(endsAt).getTime()
    const tick = () => {
      const s = Math.max(0, Math.ceil((end - Date.now()) / 1000))
      setLeft(s)
      if (s === 0) onExpire?.()
    }
    tick()
    const id = setInterval(tick, 1000)
    return () => clearInterval(id)
  }, [endsAt]) // eslint-disable-line react-hooks/exhaustive-deps
  if (!endsAt) return null
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
      <span style={{ fontFamily: 'var(--font-display)', fontSize: '1.6rem', color: left <= 5 ? 'var(--coral)' : 'var(--amber)', minWidth: 54 }}>
        {left}s
      </span>
      <div style={{ flex: 1, height: 10, border: 'var(--border-thin)' }}>
        <motion.div animate={{ width: `${Math.min(100, (left / 45) * 100)}%` }} style={{ height: '100%', background: left <= 5 ? 'var(--coral)' : 'var(--amber)' }} />
      </div>
    </div>
  )
}

/** 2. SECRET DEAL — tu secreto, tap para revelar solo en tu pantalla. */
export function SecretDeal({ secret, onReady, ready }: { secret: string | null; onReady: () => void; ready: boolean }) {
  const [shown, setShown] = useState(false)
  return (
    <div style={{ display: 'grid', gap: 16 }}>
      <motion.div whileTap={{ scale: 0.97 }} onClick={() => setShown((s) => !s)} style={{ cursor: 'pointer' }}>
        <Card accent="var(--amber)" style={{ minHeight: 140, display: 'grid', placeItems: 'center' }}>
          {shown ? (
            <motion.span initial={{ scale: 0.5 }} animate={{ scale: 1 }} transition={{ type: 'spring', stiffness: 400, damping: 15 }}
              style={{ fontFamily: 'var(--font-display)', fontSize: '2rem', color: 'var(--amber)' }}>
              {secret ?? '…'}
            </motion.span>
          ) : (
            <span style={{ color: 'var(--muted)', fontWeight: 700 }}>🤫 TOCA PARA VER TU SECRETO</span>
          )}
        </Card>
      </motion.div>
      <Button big onClick={onReady} disabled={ready} style={ready ? { opacity: 0.4 } : undefined}>
        {ready ? 'Esperando al resto…' : 'Ya lo vi ✓'}
      </Button>
    </div>
  )
}

/** 3. VOTE — grid de jugadores, tap para votar. */
export function VoteGrid({ players, meId, votedFor, onVote }: { players: Player[]; meId: string; votedFor: string | null; onVote: (id: string) => void }) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
      {players.filter((p) => p.id !== meId).map((p) => (
        <motion.button key={p.id} whileTap={{ scale: 0.92 }} onClick={() => onVote(p.id)}
          style={{
            display: 'flex', alignItems: 'center', gap: 10, padding: 10,
            background: votedFor === p.id ? 'var(--amber)' : 'var(--surface)',
            color: votedFor === p.id ? '#000' : 'var(--ink)',
            border: 'var(--border)', boxShadow: votedFor === p.id ? 'var(--shadow)' : 'none',
            fontWeight: 700, textAlign: 'left',
          }}>
          <AvatarBlock avatar={p.avatar} size={32} />
          <span style={{ fontSize: '0.9rem', overflow: 'hidden', textOverflow: 'ellipsis' }}>{p.name}</span>
        </motion.button>
      ))}
    </div>
  )
}

/** 4. TEXT INPUT — respuesta escrita + contador "N/M listos". */
export function TextPanel({ done, total, submitted, onSubmit }: { done: number; total: number; submitted: boolean; onSubmit: (t: string) => void }) {
  const [text, setText] = useState('')
  return (
    <div style={{ display: 'grid', gap: 12 }}>
      {!submitted ? (
        <>
          <Input autoFocus placeholder="Escribe aquí…" maxLength={80} value={text} onChange={(e) => setText(e.target.value)} />
          <Button big onClick={() => text.trim() && onSubmit(text.trim())} disabled={!text.trim()} style={!text.trim() ? { opacity: 0.4 } : undefined}>
            Enviar ✓
          </Button>
        </>
      ) : (
        <Card><p style={{ fontWeight: 700 }}>Enviado ✓</p></Card>
      )}
      <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>{done}/{total} listos</p>
    </div>
  )
}

/** 5. TURN ORDER — de quién es el turno; botón solo para el dueño. */
export function TurnBanner({ current, isMe, onDone }: { current: Player | undefined; isMe: boolean; onDone: () => void }) {
  if (!current) return null
  return (
    <div style={{ display: 'grid', gap: 14, justifyItems: 'center' }}>
      <motion.div key={current.id} initial={{ scale: 0.6, rotate: -4 }} animate={{ scale: 1, rotate: 0 }} transition={{ type: 'spring', stiffness: 300, damping: 16 }}>
        <Card accent="var(--coral)" style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
          <AvatarBlock avatar={current.avatar} size={48} />
          <div>
            <p style={{ color: 'var(--muted)', fontSize: '0.8rem', fontWeight: 700, textTransform: 'uppercase' }}>turno de</p>
            <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.3rem' }}>{current.name}</p>
          </div>
        </Card>
      </motion.div>
      {isMe && <Button big variant="danger" onClick={onDone}>Terminé mi turno ✓</Button>}
    </div>
  )
}

/** REVEAL KIT — lista con pops escalonados (los reveals son el producto). */
export function StaggerReveal({ items }: { items: { key: string; node: React.ReactNode }[] }) {
  return (
    <div style={{ display: 'grid', gap: 10 }}>
      {items.map((it, i) => (
        <motion.div key={it.key} initial={{ scale: 0, y: 20 }} animate={{ scale: 1, y: 0 }}
          transition={{ type: 'spring', stiffness: 350, damping: 18, delay: 0.35 * i }}>
          {it.node}
        </motion.div>
      ))}
    </div>
  )
}
