import type { InputHTMLAttributes } from 'react'

export function Input(props: InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      {...props}
      style={{
        background: 'var(--bg)',
        color: 'var(--ink)',
        border: 'var(--border)',
        padding: '14px 16px',
        fontSize: '1.1rem',
        width: '100%',
        outline: 'none',
        ...props.style,
      }}
      onFocus={(e) => {
        e.currentTarget.style.borderColor = 'var(--amber)'
        props.onFocus?.(e)
      }}
      onBlur={(e) => {
        e.currentTarget.style.borderColor = 'var(--ink)'
        props.onBlur?.(e)
      }}
    />
  )
}
