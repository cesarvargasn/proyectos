import { motion, type HTMLMotionProps } from 'framer-motion'
import type { ReactNode } from 'react'

type Variant = 'primary' | 'secondary' | 'danger' | 'ghost'

const styles: Record<Variant, React.CSSProperties> = {
  primary: {
    background: 'var(--amber)',
    color: '#000',
    border: 'var(--border)',
    borderColor: '#000',
    boxShadow: 'var(--shadow)',
  },
  secondary: {
    background: 'var(--surface)',
    color: 'var(--ink)',
    border: 'var(--border)',
    boxShadow: 'var(--shadow)',
  },
  danger: {
    background: 'var(--coral)',
    color: '#000',
    border: 'var(--border)',
    borderColor: '#000',
    boxShadow: 'var(--shadow)',
  },
  ghost: {
    background: 'transparent',
    color: 'var(--muted)',
    border: '2px solid var(--muted)',
    boxShadow: 'none',
  },
}

interface ButtonProps extends HTMLMotionProps<'button'> {
  variant?: Variant
  big?: boolean
  children: ReactNode
}

export function Button({ variant = 'primary', big = false, children, style, ...rest }: ButtonProps) {
  return (
    <motion.button
      whileTap={{ scale: 0.94, x: 2, y: 2, boxShadow: '0px 0px 0 #000' }}
      transition={{ type: 'spring', stiffness: 500, damping: 30 }}
      style={{
        fontFamily: big ? 'var(--font-display)' : 'var(--font-body)',
        fontWeight: big ? 400 : 700,
        textTransform: 'uppercase',
        letterSpacing: '0.02em',
        fontSize: big ? '1.3rem' : '1rem',
        padding: big ? '18px 28px' : '12px 20px',
        ...styles[variant],
        ...style,
      }}
      {...rest}
    >
      {children}
    </motion.button>
  )
}
