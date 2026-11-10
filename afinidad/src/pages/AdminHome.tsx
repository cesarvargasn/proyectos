import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { useAdminAuth, signInAdmin, signOutAdmin } from '../lib/adminAuth'
import type { Event } from '../lib/types'

const CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'

function generateCode(): string {
  return Array.from({ length: 6 }, () =>
    CODE_CHARS[Math.floor(Math.random() * CODE_CHARS.length)]
  ).join('')
}

interface EventWithCount extends Event {
  participant_count: number
  phase: string
}

export default function AdminHome() {
  const navigate = useNavigate()
  const authed = useAdminAuth()
  const [emailInput, setEmailInput] = useState('')
  const [passwordInput, setPasswordInput] = useState('')
  const [loginError, setLoginError] = useState('')
  const [loggingIn, setLoggingIn] = useState(false)

  const [events, setEvents] = useState<EventWithCount[]>([])
  const [loading, setLoading] = useState(false)

  const [newName, setNewName] = useState('')
  const [newCode, setNewCode] = useState(generateCode())
  const [creating, setCreating] = useState(false)
  const [createError, setCreateError] = useState('')

  const [copied, setCopied] = useState<string | null>(null)

  useEffect(() => {
    if (authed) loadEvents()
  }, [authed])

  async function loadEvents() {
    setLoading(true)
    const { data: eventsData } = await supabase
      .from('events')
      .select('*')
      .order('created_at', { ascending: false })

    if (!eventsData) { setLoading(false); return }

    const enriched = await Promise.all(
      eventsData.map(async (ev) => {
        const [{ count }, stateRes] = await Promise.all([
          supabase.from('participants').select('*', { count: 'exact', head: true }).eq('event_id', ev.id),
          supabase.from('event_state').select('phase').eq('event_id', ev.id).single(),
        ])
        return {
          ...ev,
          participant_count: count ?? 0,
          phase: stateRes.data?.phase ?? 'waiting',
        } as EventWithCount
      })
    )
    setEvents(enriched)
    setLoading(false)
  }

  async function login(e: React.FormEvent) {
    e.preventDefault()
    setLoginError('')
    setLoggingIn(true)
    const err = await signInAdmin(emailInput, passwordInput)
    setLoggingIn(false)
    if (err) { setLoginError('Email o contraseña incorrectos.'); return }
    setPasswordInput('')
    // useAdminAuth reacts to the auth change → panel renders automatically
  }

  function logout() {
    signOutAdmin()
  }

  async function createEvent(e: React.FormEvent) {
    e.preventDefault()
    if (!newName.trim()) { setCreateError('Escribe un nombre para el evento.'); return }
    setCreating(true)
    setCreateError('')

    const code = newCode.trim().toUpperCase()

    const { data: ev, error: evErr } = await supabase
      .from('events')
      .insert({ name: newName.trim(), code })
      .select('id')
      .single()

    if (evErr || !ev) {
      setCreateError(evErr?.message ?? 'Error al crear evento.')
      setCreating(false)
      return
    }

    const { data: allQ } = await supabase.from('questions').select('id').order('created_at')

    if (allQ && allQ.length > 0) {
      await supabase.from('event_questions').insert(
        allQ.map((q, i) => ({
          event_id: ev.id,
          question_id: q.id,
          display_order: i + 1,
          active: true,
        }))
      )
    }

    // Compute the id in code so the DB needs no sequence default
    const { data: maxRows } = await supabase
      .from('event_state').select('id').order('id', { ascending: false }).limit(1)
    const nextId = (maxRows?.[0]?.id ?? 0) + 1

    await supabase.from('event_state').insert({
      id: nextId,
      event_id: ev.id,
      phase: 'waiting',
      reveal_at: null,
      admin_participates: false,
    })

    setNewName('')
    setNewCode(generateCode())
    setCreating(false)
    loadEvents()
  }

  function copyLink(code: string) {
    const url = `${window.location.origin}/e/${code}`
    navigator.clipboard.writeText(url)
    setCopied(code)
    setTimeout(() => setCopied(null), 2000)
  }

  const phaseLabel: Record<string, string> = {
    waiting: 'Esperando',
    matching: 'Calculando',
    funnel: 'Embudo',
    countdown: 'Countdown',
    reveal: 'Revelado',
  }

  if (authed === null) {
    return <div className="page-center"><p className="muted">Cargando...</p></div>
  }

  if (!authed) {
    return (
      <div className="page-center">
        <div className="card">
          <div className="login-header">
            <p>Afinidad</p>
            <h1 className="title">Admin</h1>
          </div>
          <form onSubmit={login} className="form">
            <div className="field">
              <label>Email</label>
              <input
                type="email"
                value={emailInput}
                onChange={e => setEmailInput(e.target.value)}
                autoComplete="email"
                autoFocus
              />
            </div>
            <div className="field">
              <label>Contraseña</label>
              <input
                type="password"
                value={passwordInput}
                onChange={e => setPasswordInput(e.target.value)}
                autoComplete="current-password"
              />
            </div>
            {loginError && <p className="error">{loginError}</p>}
            <button type="submit" className="btn-primary" disabled={loggingIn}>
              {loggingIn ? 'Entrando...' : 'Entrar'}
            </button>
          </form>
          <Link to="/" className="back-link" style={{ marginTop: '24px', display: 'block', textAlign: 'center' }}>
            ← Volver al inicio
          </Link>
        </div>
      </div>
    )
  }

  return (
    <div className="admin-layout">
      <header className="admin-topbar">
        <div style={{ display: 'flex', alignItems: 'center', gap: '16px' }}>
          <Link to="/" className="admin-back-btn">←</Link>
          <h1>Afinidad — Eventos</h1>
        </div>
        <button onClick={logout} className="btn-ghost"
          style={{ width: 'auto', padding: '6px 14px', fontSize: '0.68rem', color: 'var(--muted)', borderColor: 'var(--black2)' }}>
          Salir
        </button>
      </header>

      <div className="admin-content">
        <section className="admin-section">
          <h2 className="admin-section-title">Crear evento</h2>
          <form onSubmit={createEvent} className="create-event-form">
            <div className="field">
              <label>Nombre del evento</label>
              <input
                type="text"
                value={newName}
                onChange={e => setNewName(e.target.value)}
                placeholder="Ej: Fiesta junio 2025"
                autoComplete="off"
              />
            </div>
            <div className="field">
              <label>Código (editable)</label>
              <div style={{ display: 'flex', gap: '8px' }}>
                <input
                  type="text"
                  value={newCode}
                  onChange={e => setNewCode(e.target.value.toUpperCase().slice(0, 6))}
                  maxLength={6}
                  style={{ flex: 1, letterSpacing: '0.2em', fontWeight: 700 }}
                />
                <button
                  type="button"
                  className="btn-ghost"
                  onClick={() => setNewCode(generateCode())}
                  style={{ width: 'auto', padding: '12px 14px', whiteSpace: 'nowrap' }}
                >
                  ↻
                </button>
              </div>
            </div>
            {createError && <p className="error">{createError}</p>}
            <button type="submit" className="btn-primary" disabled={creating} style={{ width: 'auto' }}>
              {creating ? 'Creando...' : '+ Crear evento'}
            </button>
          </form>
        </section>

        <section className="admin-section">
          <h2 className="admin-section-title">Eventos</h2>
          {loading && <p className="admin-loading">Cargando...</p>}
          {!loading && events.length === 0 && (
            <p className="muted">Aún no hay eventos. Crea uno arriba.</p>
          )}
          <div className="events-list">
            {events.map(ev => (
              <div key={ev.id} className="event-card">
                <div className="event-card-left">
                  <span className="event-code-badge">{ev.code}</span>
                  <div>
                    <p className="event-name">{ev.name}</p>
                    <p className="event-meta">
                      {ev.participant_count} participante{ev.participant_count !== 1 ? 's' : ''}
                      {' · '}
                      <span className={`phase-badge phase-${ev.phase}`}>
                        {phaseLabel[ev.phase] ?? ev.phase}
                      </span>
                    </p>
                  </div>
                </div>
                <div className="event-card-actions">
                  <button
                    className="btn-ghost"
                    onClick={() => copyLink(ev.code)}
                    style={{ width: 'auto', padding: '8px 14px', fontSize: '0.72rem' }}
                  >
                    {copied === ev.code ? '✓ Copiado' : 'Copiar link'}
                  </button>
                  <button
                    className="btn-primary"
                    onClick={() => navigate(`/admin/${ev.id}`)}
                    style={{ width: 'auto', padding: '8px 20px', fontSize: '0.72rem' }}
                  >
                    Gestionar →
                  </button>
                </div>
              </div>
            ))}
          </div>
        </section>
      </div>
    </div>
  )
}
