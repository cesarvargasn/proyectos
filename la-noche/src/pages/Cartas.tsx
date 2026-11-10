import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Button } from '../ui/Button'
import { Input } from '../ui/Input'
import { supabase } from '../lib/supabase'
import { adminListCards, adminUpsertCard, adminSetEnabled, adminDeleteCard, type ContentCard } from '../lib/api'

/**
 * 025-b: dos familias distintas en /cartas.
 *
 * BASES (base: true) — Yo Nunca, El Más Probable (absorbió Paranoia) y
 * Verdad o Reto ya no son juegos: la base ES el producto. El admin la LEE
 * en la fiesta desde el celular y AÑADE cuando se le ocurre una. Nada de
 * apagar/prender/borrar — eso existía para decidir qué entraba a los mazos
 * de juego, y aquí ya no hay mazo. La curación fina (borrar/editar en lote)
 * se hace por CSV + npm run content, no desde esta UI.
 *
 * MAZOS — juegos lanzables que sí arman mazo desde content_cards: ahí el
 * editor completo (apagar = no entra al mazo) sigue teniendo sentido.
 */
const DECK_GAMES: { id: string; nameEs: string; types: string[]; base?: boolean }[] = [
  { id: 'yo-nunca', nameEs: 'Yo Nunca', types: ['default'], base: true },
  { id: 'el-senalado', nameEs: 'El Más Probable', types: ['default'], base: true },
  // banco mezclado: el card_type solo etiqueta la carta al leerla en voz alta
  { id: 'verdad-o-reto', nameEs: 'Verdad o Reto', types: ['verdad', 'reto'], base: true },
  { id: 'la-ruleta', nameEs: 'La Ruleta', types: ['directa', 'grupal', 'duelo', 'reto', 'regla'] },
]

interface Draft {
  id: string | null
  card_type: string
  text_es: string
  intensity: number // 027: ya no se muestra ni filtra; se guarda fijo en 2
}

/** /cartas — curador de mazos, solo cuenta admin (RPCs re-validan en server). */
export function Cartas() {
  const nav = useNavigate()
  const [adminReady, setAdminReady] = useState<boolean | null>(null)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const [game, setGame] = useState(DECK_GAMES[0])
  const [cards, setCards] = useState<ContentCard[]>([])
  const [draft, setDraft] = useState<Draft | null>(null)
  const [typeFilter, setTypeFilter] = useState<string | null>(null)

  useEffect(() => {
    void supabase.auth.getSession().then(({ data }) => {
      setAdminReady(!!data.session && !data.session.user.is_anonymous)
    })
  }, [])

  useEffect(() => {
    if (!adminReady) return
    setDraft(null)
    setTypeFilter(null)
    adminListCards(game.id).then(setCards).catch((e: Error) => setError(e.message))
  }, [adminReady, game.id])

  async function login(e: React.FormEvent) {
    e.preventDefault()
    if (busy) return
    setBusy(true)
    setError('')
    const { error: err } = await supabase.auth.signInWithPassword({ email: email.trim(), password })
    setBusy(false)
    if (err) { setError('Email o contraseña incorrectos.'); return }
    setAdminReady(true)
  }

  async function save() {
    if (!draft || !draft.text_es.trim() || busy) return
    setBusy(true)
    setError('')
    try {
      await adminUpsertCard({ ...draft, game_type: game.id, text_es: draft.text_es.trim() })
      setCards(await adminListCards(game.id))
      setDraft(null)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'falló')
    }
    setBusy(false)
  }

  async function toggle(c: ContentCard) {
    await adminSetEnabled(c.id, !c.enabled).catch(() => {})
    setCards((cs) => cs.map((x) => (x.id === c.id ? { ...x, enabled: !c.enabled } : x)))
  }

  async function remove(c: ContentCard) {
    if (!window.confirm(`¿Borrar esta carta?\n\n"${c.text_es}"`)) return
    await adminDeleteCard(c.id).catch(() => {})
    setCards((cs) => cs.filter((x) => x.id !== c.id))
    setDraft(null)
  }

  if (adminReady === null) return null

  if (!adminReady) {
    return (
      <main style={{ maxWidth: 480, margin: '0 auto', padding: '48px 24px 60px' }}>
        <form onSubmit={(e) => void login(e)} style={{ display: 'grid', gap: 18 }}>
          <div>
            <p style={{ color: 'var(--muted)', fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.12em' }}>zona del admin</p>
            <h2>Cartas</h2>
          </div>
          <Input autoFocus type="email" placeholder="Email" value={email} onChange={(e) => setEmail(e.target.value)} />
          <Input type="password" placeholder="Contraseña" value={password} onChange={(e) => setPassword(e.target.value)} />
          {error && <p style={{ color: 'var(--coral)', fontWeight: 700 }}>{error}</p>}
          <Button big type="submit" disabled={busy || !email.trim() || !password}>{busy ? '…' : 'Entrar'}</Button>
          <Button variant="ghost" type="button" onClick={() => nav('/')}>Volver</Button>
        </form>
      </main>
    )
  }

  const enabledCount = cards.filter((c) => c.enabled).length

  return (
    <main style={{ maxWidth: 560, margin: '0 auto', padding: '32px 20px 80px', display: 'grid', gap: 18 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
        <h2 style={{ flex: 1 }}>Cartas</h2>
        <button onClick={() => nav('/')} style={{ background: 'none', color: 'var(--muted)', border: 'none', fontWeight: 700, cursor: 'pointer' }}>← salir</button>
      </div>

      {[
        { label: 'Bases de la noche', items: DECK_GAMES.filter((g) => g.base) },
        { label: 'Mazos de juego', items: DECK_GAMES.filter((g) => !g.base) },
      ].map((grp) => (
        <div key={grp.label} style={{ display: 'grid', gap: 6 }}>
          <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.72rem', textTransform: 'uppercase', letterSpacing: '0.1em' }}>
            {grp.label}
          </p>
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            {grp.items.map((g) => (
              <button key={g.id} onClick={() => setGame(g)}
                style={{
                  padding: '8px 12px', fontWeight: 700, fontSize: '0.85rem', cursor: 'pointer',
                  background: game.id === g.id ? 'var(--amber)' : 'var(--surface)',
                  color: game.id === g.id ? '#000' : 'var(--ink)',
                  border: 'var(--border-thin)',
                }}>
                {g.nameEs}
              </button>
            ))}
          </div>
        </div>
      ))}

      <div style={{ display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
        <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.85rem', flex: 1 }}>
          {game.base
            ? `${cards.length} cartas`
            : `${enabledCount} activas · ${cards.length - enabledCount} apagadas`}
        </p>
        {game.base && game.types.length > 1 && (
          <div style={{ display: 'flex', gap: 6 }}>
            {[null, ...game.types].map((t) => (
              <button key={t ?? 'todas'} onClick={() => setTypeFilter(t)}
                style={{
                  padding: '6px 10px', fontWeight: 700, fontSize: '0.75rem', cursor: 'pointer', textTransform: 'uppercase',
                  border: 'var(--border-thin)',
                  background: typeFilter === t ? 'var(--amber)' : 'var(--surface)',
                  color: typeFilter === t ? '#000' : 'var(--ink)',
                }}>
                {t ?? 'todas'}
              </button>
            ))}
          </div>
        )}
      </div>

      {error && <p style={{ color: 'var(--coral)', fontWeight: 700 }}>⚠ {error}</p>}

      {/* editor (nueva o existente) */}
      {draft ? (
        <div style={{ border: 'var(--border)', background: 'var(--surface)', padding: 14, display: 'grid', gap: 10 }}>
          <textarea
            autoFocus
            value={draft.text_es}
            onChange={(e) => setDraft({ ...draft, text_es: e.target.value })}
            rows={3}
            maxLength={220}
            placeholder="Texto de la carta… (tokens: {p1} {p2} {drink:1})"
            style={{ background: 'var(--bg)', color: 'var(--ink)', border: 'var(--border-thin)', padding: 10, fontFamily: 'inherit', fontSize: '1rem', resize: 'vertical' }}
          />
          {game.types.length > 1 && (
            <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
              <span style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem' }}>Tipo:</span>
              {game.types.map((t) => (
                <button key={t} onClick={() => setDraft({ ...draft, card_type: t })}
                  style={{
                    padding: '6px 10px', fontWeight: 700, fontSize: '0.78rem', cursor: 'pointer', textTransform: 'uppercase',
                    border: 'var(--border-thin)',
                    background: draft.card_type === t ? 'var(--amber)' : 'var(--bg)',
                    color: draft.card_type === t ? '#000' : 'var(--ink)',
                  }}>
                  {t}
                </button>
              ))}
            </div>
          )}
          <div style={{ display: 'flex', gap: 8 }}>
            <Button style={{ flex: 1 }} onClick={() => void save()} disabled={busy || !draft.text_es.trim()}>
              {draft.id ? 'Guardar ✓' : 'Añadir ✓'}
            </Button>
            <Button variant="ghost" onClick={() => setDraft(null)}>Cancelar</Button>
          </div>
        </div>
      ) : (
        <Button big onClick={() => setDraft({ id: null, card_type: typeFilter ?? game.types[0], text_es: '', intensity: 2 })}>
          {game.base ? '+ Añadir' : '+ Nueva carta'}
        </Button>
      )}

      {/* lista */}
      {game.base ? (
        /* MODO LECTURA (bases): texto grande para leer en la fiesta, cero botones */
        <div style={{ display: 'grid', gap: 10 }}>
          {cards
            .filter((c) => typeFilter === null || c.card_type === typeFilter)
            .map((c) => (
              <div key={c.id}
                style={{
                  border: 'var(--border-thin)', background: 'var(--surface)', padding: '14px 16px',
                  display: 'grid', gap: 6,
                }}>
                <p style={{ fontSize: '1.08rem', lineHeight: 1.4 }}>{c.text_es}</p>
                {c.card_type !== 'default' && (
                  <span style={{
                    fontSize: '0.72rem', fontWeight: 700, textTransform: 'uppercase',
                    color: c.card_type === 'reto' ? 'var(--coral)' : 'var(--muted)',
                  }}>
                    {c.card_type}
                  </span>
                )}
              </div>
            ))}
          {cards.length === 0 && <p style={{ color: 'var(--muted)', fontWeight: 700 }}>La base está vacía todavía.</p>}
        </div>
      ) : (
        /* EDITOR (mazos de juego): apagar = no entra al mazo al lanzar */
        <div style={{ display: 'grid', gap: 8 }}>
          {cards.map((c) => (
            <div key={c.id}
              style={{
                border: 'var(--border-thin)', background: 'var(--surface)', padding: '10px 12px',
                display: 'grid', gap: 6, opacity: c.enabled ? 1 : 0.45,
              }}>
              <p style={{ fontSize: '0.92rem', lineHeight: 1.35 }}>{c.text_es}</p>
              <div style={{ display: 'flex', gap: 10, alignItems: 'center', fontSize: '0.75rem', fontWeight: 700 }}>
                {c.card_type !== 'default' && <span style={{ color: 'var(--muted)', textTransform: 'uppercase' }}>{c.card_type}</span>}
                <span style={{ flex: 1 }} />
                <button onClick={() => setDraft({ id: c.id, card_type: c.card_type, text_es: c.text_es, intensity: c.intensity })}
                  style={{ background: 'none', border: 'none', color: 'var(--amber)', fontWeight: 700, cursor: 'pointer' }}>
                  editar
                </button>
                <button onClick={() => void toggle(c)}
                  style={{ background: 'none', border: 'none', color: c.enabled ? 'var(--muted)' : '#7ED957', fontWeight: 700, cursor: 'pointer' }}>
                  {c.enabled ? 'apagar' : 'prender'}
                </button>
                <button onClick={() => void remove(c)}
                  style={{ background: 'none', border: 'none', color: 'var(--coral)', fontWeight: 700, cursor: 'pointer' }}>
                  borrar
                </button>
              </div>
            </div>
          ))}
          {cards.length === 0 && <p style={{ color: 'var(--muted)', fontWeight: 700 }}>Sin cartas para este juego todavía.</p>}
        </div>
      )}
    </main>
  )
}
