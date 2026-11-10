import type { Avatar as AvatarData } from '../lib/types'

// Set curado brutalist: símbolo + color. Mismos sets que dev_add_bots en SQL.
export const AVATAR_SYMBOLS = ['★', '⚡', '☾', '♦', '▲', '●', '✕', '♠'] as const
export const AVATAR_COLORS = ['#FFB224', '#FF5C47', '#7ED957', '#5CB8FF', '#C792EA', '#F5EFE6'] as const

// Móviles renderizan ★⚡♦♠ como emoji de color; U+FE0E fuerza presentación texto.
// Se aplica solo al pintar: los datos guardados (DB y localStorage) quedan planos.
const VS_TEXT = String.fromCharCode(0xfe0e) // variation selector-15 (texto)
const VS_EMOJI = String.fromCharCode(0xfe0f) // variation selector-16 (emoji)
export function textSymbol(s: string): string {
  return s.split(VS_TEXT).join('').split(VS_EMOJI).join('') + VS_TEXT
}

export function AvatarBlock({ avatar, size = 48 }: { avatar: AvatarData; size?: number }) {
  return (
    <div
      style={{
        width: size,
        height: size,
        flexShrink: 0,
        background: avatar.color || 'var(--amber)',
        border: '3px solid #000',
        boxShadow: '3px 3px 0 #000',
        display: 'grid',
        placeItems: 'center',
        fontSize: size * 0.55,
        color: '#000',
        lineHeight: 1,
      }}
    >
      {textSymbol(avatar.symbol || '★')}
    </div>
  )
}
