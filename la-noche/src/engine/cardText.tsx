import type { ReactNode } from 'react'
import type { Party } from '../lib/types'

/**
 * Render de texto de carta con tokens:
 *   {p1}..{p9}  → nombre resuelto por el server (state.slots), resaltado
 *   {drink:N}   → "toma N 🍺". El modo social/puntos se eliminó (025,
 *                 decisión César 2026-09-12): La Noche es solo versión trago.
 *                 El parámetro mode se conserva para no tocar cada callsite,
 *                 pero se ignora.
 * Tokens sin resolver quedan como texto plano (mejor feo que roto).
 */
export function renderCardText(
  text: string,
  slots: Record<string, string> | undefined,
  _mode: Party['settings']['mode'],
): ReactNode[] {
  return text.split(/(\{p[1-9]\}|\{drink:[1-9]\})/g).map((part, i) => {
    const slot = part.match(/^\{(p[1-9])\}$/)
    if (slot) {
      const name = slots?.[slot[1]]
      return name
        ? <strong key={i} style={{ color: 'var(--amber)' }}>{name}</strong>
        : <span key={i}>{part}</span>
    }
    const drink = part.match(/^\{drink:([1-9])\}$/)
    if (drink) {
      const n = drink[1]
      return (
        <strong key={i} style={{ color: 'var(--coral)' }}>
          {`toma ${n} 🍺`}
        </strong>
      )
    }
    return <span key={i}>{part}</span>
  })
}

/**
 * Preview de carta para el deck builder: aún NO hay jugadores asignados,
 * así que {p1}..{p9} se muestran como placeholders ("alguien" / "otro") en
 * vez del token crudo. {drink:N} siempre es trago (025).
 * En juego real los nombres los pinta renderCardText con state.slots.
 */
export function renderCardPreview(
  text: string,
  _mode: Party['settings']['mode'],
): ReactNode[] {
  return text.split(/(\{p[1-9]\}|\{drink:[1-9]\})/g).map((part, i) => {
    const slot = part.match(/^\{(p[1-9])\}$/)
    if (slot) {
      const label = slot[1] === 'p1' ? 'alguien' : 'otro'
      return <em key={i} style={{ color: 'var(--muted)' }}>{label}</em>
    }
    const drink = part.match(/^\{drink:([1-9])\}$/)
    if (drink) {
      const n = drink[1]
      return (
        <strong key={i} style={{ color: 'var(--coral)' }}>
          {`toma ${n} 🍺`}
        </strong>
      )
    }
    return <span key={i}>{part}</span>
  })
}
