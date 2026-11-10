import { useState } from 'react'
import { Card } from '../ui/Card'

/**
 * Heads-up de reglas para juegos complejos (feedback 2026-07-18):
 * "habrá esto, estos pueden hacer esto, así ganas, así pierdes".
 * Abierto por defecto en la fase de reparto; colapsable después.
 */
export function HowToPlay({ title, lines, startOpen = false }: {
  title?: string
  lines: string[]
  startOpen?: boolean
}) {
  const [open, setOpen] = useState(startOpen)
  return (
    <Card accent="var(--amber)" style={{ display: 'grid', gap: 8, padding: open ? undefined : '10px 14px' }}>
      <button onClick={() => setOpen((o) => !o)}
        style={{
          display: 'flex', alignItems: 'center', gap: 8, background: 'none', border: 'none',
          color: 'var(--ink)', cursor: 'pointer', padding: 0, textAlign: 'left',
        }}>
        <span style={{ fontFamily: 'var(--font-display)', fontSize: '1rem', flex: 1 }}>
          📖 {title ?? 'Cómo se juega'}
        </span>
        <span style={{ fontWeight: 700, color: 'var(--muted)' }}>{open ? '▲' : '▼'}</span>
      </button>
      {open && (
        <div style={{ display: 'grid', gap: 6 }}>
          {lines.map((l, i) => (
            <p key={i} style={{ fontWeight: 700, fontSize: '0.88rem', lineHeight: 1.35 }}>{l}</p>
          ))}
        </div>
      )}
    </Card>
  )
}
