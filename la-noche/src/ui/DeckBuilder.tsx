import { useEffect, useMemo, useState } from 'react'
import { Button } from './Button'
import { Input } from './Input'
import { adminListCards, launchGame, type ContentCard } from '../lib/api'
import { renderCardPreview } from '../engine/cardText'
import type { GameMeta } from '../games/registry'
import type { Party } from '../lib/types'

/**
 * Deck builder de dos paneles: izquierda = mazo de esta sesión (orden =
 * orden de lanzamiento, importa en La Ruleta), derecha = super banco con
 * buscador y filtros (tipo/tag). Tap mueve la carta de panel.
 * Solo admin (adminListCards valida en server). El último mazo por juego
 * se recuerda en localStorage.
 *
 * 027: la intensidad 1-5 se eliminó de toda la app (César: "no me parece").
 * La columna sigue en la DB pero nadie filtra ni la muestra.
 */
const lastDeckKey = (gameId: string) => `lanoche_deck_${gameId}`

interface Props {
  game: GameMeta
  partyId: string
  mode: Party['settings']['mode']
  timerDefault?: number
  onClose: () => void
  onLaunched: () => void
}

export function DeckBuilder({ game, partyId, mode, timerDefault, onClose, onLaunched }: Props) {
  const [bank, setBank] = useState<ContentCard[]>([])
  const [picked, setPicked] = useState<string[]>([]) // ids en orden de lanzamiento
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [q, setQ] = useState('')
  const [fType, setFType] = useState<string | null>(null)
  const [fTag, setFTag] = useState<string | null>(null)
  const [timer, setTimer] = useState(timerDefault ?? 30)

  useEffect(() => {
    adminListCards(game.id)
      .then((cards) => {
        setBank(cards)
        // precarga el último mazo usado (solo ids que sigan existiendo)
        try {
          const saved: string[] = JSON.parse(localStorage.getItem(lastDeckKey(game.id)) ?? '[]')
          const valid = new Set(cards.map((c) => c.id))
          setPicked(saved.filter((id) => valid.has(id)))
        } catch { /* sin mazo previo */ }
      })
      .catch((e: Error) => setError(e.message === 'SOLO_ADMIN'
        ? 'Solo la cuenta admin puede armar mazos. Entra en /crear o /cartas primero.'
        : e.message))
  }, [game.id])

  const byId = useMemo(() => new Map(bank.map((c) => [c.id, c])), [bank])
  const types = useMemo(() => [...new Set(bank.map((c) => c.card_type))].filter((t) => t !== 'default'), [bank])
  const tags = useMemo(() => [...new Set(bank.flatMap((c) => c.tags))].sort(), [bank])
  const pickedSet = useMemo(() => new Set(picked), [picked])

  const available = bank.filter((c) =>
    c.enabled && !pickedSet.has(c.id)
    && (!q || c.text_es.toLowerCase().includes(q.toLowerCase()))
    && (!fType || c.card_type === fType)
    && (!fTag || c.tags.includes(fTag)))

  async function lanzar() {
    if (picked.length === 0 || busy) return
    setBusy(true)
    setError('')
    try {
      localStorage.setItem(lastDeckKey(game.id), JSON.stringify(picked))
      await launchGame(partyId, game.id, { card_ids: picked, timer_s: timer })
      onLaunched()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'falló')
      setBusy(false)
    }
  }

  const chip = (active: boolean) => ({
    padding: '5px 9px', fontWeight: 700, fontSize: '0.72rem', cursor: 'pointer',
    border: 'var(--border-thin)', textTransform: 'uppercase' as const,
    background: active ? 'var(--amber)' : 'var(--bg)', color: active ? '#000' : 'var(--ink)',
  })

  const cardRow = (c: ContentCard, action: string, onTap: () => void, accent?: string) => (
    <button key={c.id} onClick={onTap}
      style={{
        textAlign: 'left', cursor: 'pointer', padding: '8px 10px', display: 'grid', gap: 4,
        background: 'var(--surface)', color: 'var(--ink)',
        border: 'var(--border-thin)', borderLeft: accent ? `4px solid ${accent}` : 'var(--border-thin)',
      }}>
      <span style={{ fontSize: '0.85rem', lineHeight: 1.3 }}>{renderCardPreview(c.text_es, mode)}</span>
      <span style={{ fontSize: '0.68rem', fontWeight: 700, color: 'var(--muted)' }}>
        {c.card_type !== 'default' && `${c.card_type.toUpperCase()} · `}
        {c.tags.length > 0 && `${c.tags.join(', ')} · `}
        <span style={{ color: 'var(--amber)' }}>{action}</span>
      </span>
    </button>
  )

  return (
    <div style={{ position: 'fixed', inset: 0, background: 'var(--bg)', zIndex: 60, overflowY: 'auto', padding: '20px 16px 120px' }}>
      <div style={{ maxWidth: 980, margin: '0 auto', display: 'grid', gap: 14 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
          <h3 style={{ color: game.accent, flex: 1 }}>Armar mazo · {game.nameEs}</h3>
          <button onClick={onClose} style={{ background: 'none', border: 'none', color: 'var(--muted)', fontWeight: 700, cursor: 'pointer' }}>✕ cerrar</button>
        </div>

        {error && <p style={{ color: 'var(--coral)', fontWeight: 700 }}>⚠ {error}</p>}

        <div style={{ display: 'grid', gap: 14, gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))', alignItems: 'start' }}>
          {/* IZQUIERDA: mazo de la sesión */}
          <section style={{ display: 'grid', gap: 8, border: 'var(--border)', padding: 12, background: 'var(--surface)' }}>
            <p style={{ fontWeight: 700, textTransform: 'uppercase', fontSize: '0.8rem' }}>
              Mazo de esta noche · {picked.length}
            </p>
            {picked.length === 0 && (
              <p style={{ color: 'var(--muted)', fontSize: '0.85rem', fontWeight: 700 }}>
                Toca cartas del banco → para meterlas aquí. El orden de la lista es el orden de juego.
              </p>
            )}
            <div style={{ display: 'grid', gap: 6 }}>
              {picked.map((id) => {
                const c = byId.get(id)
                return c ? cardRow(c, '— quitar', () => setPicked((p) => p.filter((x) => x !== id)), game.accent) : null
              })}
            </div>
          </section>

          {/* DERECHA: super banco */}
          <section style={{ display: 'grid', gap: 8 }}>
            <p style={{ fontWeight: 700, textTransform: 'uppercase', fontSize: '0.8rem', color: 'var(--muted)' }}>
              Banco · {available.length} disponibles
            </p>
            <Input placeholder="Buscar…" value={q} onChange={(e) => setQ(e.target.value)} />
            <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap' }}>
              {types.map((t) => (
                <button key={t} onClick={() => setFType(fType === t ? null : t)} style={chip(fType === t)}>{t}</button>
              ))}
              {tags.map((t) => (
                <button key={t} onClick={() => setFTag(fTag === t ? null : t)} style={chip(fTag === t)}>{t}</button>
              ))}
            </div>
            <div style={{ display: 'grid', gap: 6 }}>
              {available.map((c) => cardRow(c, '+ al mazo', () => setPicked((p) => [...p, c.id])))}
              {available.length === 0 && bank.length > 0 && (
                <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.85rem' }}>Nada con esos filtros.</p>
              )}
            </div>
          </section>
        </div>
      </div>

      {/* barra de lanzamiento */}
      <div style={{ position: 'fixed', bottom: 0, left: 0, right: 0, background: 'var(--bg)', borderTop: 'var(--border)', padding: '12px 16px' }}>
        <div style={{ maxWidth: 980, margin: '0 auto', display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
          {timerDefault !== undefined && (
            <div style={{ display: 'flex', gap: 4 }}>
              {[15, 20, 30, 45, 60].map((n) => (
                <button key={n} onClick={() => setTimer(n)} style={chip(timer === n)}>{n}s</button>
              ))}
            </div>
          )}
          <span style={{ flex: 1 }} />
          <Button big onClick={() => void lanzar()} disabled={picked.length === 0 || busy}
            style={picked.length === 0 ? { opacity: 0.4 } : undefined}>
            Lanzar con {picked.length} 🚀
          </Button>
        </div>
      </div>
    </div>
  )
}
