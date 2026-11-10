import type { CSSProperties, ReactNode } from 'react'

interface CardProps {
  accent?: string
  children: ReactNode
  style?: CSSProperties
  onClick?: (e: React.MouseEvent) => void
}

/** Bloque base warm brutalist: borde grueso + sombra dura. */
export function Card({ accent, children, style, onClick }: CardProps) {
  return (
    <div
      onClick={onClick}
      style={{
        background: 'var(--surface)',
        border: 'var(--border)',
        boxShadow: accent ? `4px 4px 0 ${accent}` : 'var(--shadow)',
        padding: '20px',
        ...style,
      }}
    >
      {children}
    </div>
  )
}
