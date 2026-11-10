import { useState, useEffect } from 'react'
import { useNavigate, useParams, Link } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { saveSession } from '../lib/session'

interface EventInfo {
  id: string
  name: string
}

export default function Register() {
  const navigate = useNavigate()
  const { code } = useParams<{ code: string }>()

  const [event, setEvent] = useState<EventInfo | null>(null)
  const [eventError, setEventError] = useState<string | null>(null)
  const [form, setForm] = useState({ first_name: '', email: '', phone: '', birthday: '' })
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!code) { navigate('/'); return }
    lookupEvent(code.toUpperCase())
  }, [code])

  async function lookupEvent(c: string) {
    const { data, error: dbError } = await supabase
      .from('events')
      .select('id, name')
      .eq('code', c)
      .single()

    if (dbError || !data) {
      setEventError('Evento no encontrado. Verifica el código.')
      return
    }
    setEvent(data)
  }

  function handleChange(e: React.ChangeEvent<HTMLInputElement>) {
    setForm(prev => ({ ...prev, [e.target.name]: e.target.value }))
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!event || !code) return

    // Required-field validation — block submit if phone/birthday empty
    if (!form.first_name.trim()) { setError('Escribe tu nombre.'); return }
    if (!form.email.trim())      { setError('Escribe tu email.'); return }
    if (!form.phone.trim())      { setError('El teléfono es obligatorio.'); return }
    if (!form.birthday)          { setError('El cumpleaños es obligatorio.'); return }

    setLoading(true)
    setError(null)

    const { data: rows, error: dbError } = await supabase.rpc('register_participant', {
      p_event_id:   event.id,
      p_first_name: form.first_name.trim(),
      p_email:      form.email.trim().toLowerCase(),
      p_phone:      form.phone.trim(),
      p_birthday:   form.birthday,
    })
    const data = rows?.[0] ?? null

    if (dbError || !data) {
      setError(dbError?.message ?? 'Error al registrarte. Intenta de nuevo.')
      setLoading(false)
      return
    }

    saveSession({
      participantId: data.id,
      token: data.token,
      firstName: data.first_name,
      eventId: event.id,
      eventCode: code.toUpperCase(),
    })

    navigate(`/e/${code}/q`)
  }

  if (eventError) {
    return (
      <div className="page-center">
        <div className="card text-center">
          <p className="error">{eventError}</p>
          <Link to="/" className="back-link">← Volver</Link>
        </div>
      </div>
    )
  }

  if (!event) {
    return (
      <div className="page-center">
        <p className="muted">Buscando evento...</p>
      </div>
    )
  }

  return (
    <div className="page-center">
      <div className="card">
        <div className="login-header">
          <p>{event.name}</p>
          <h1 className="title">¿Quién eres?</h1>
        </div>
        <p className="subtitle">Llena esto antes de empezar.</p>

        <form onSubmit={handleSubmit} className="form">
          <div className="field">
            <label htmlFor="first_name">Primer nombre *</label>
            <input
              id="first_name"
              name="first_name"
              type="text"
              required
              autoComplete="given-name"
              value={form.first_name}
              onChange={handleChange}
              placeholder="Tu nombre"
            />
          </div>

          <div className="field">
            <label htmlFor="email">Email *</label>
            <input
              id="email"
              name="email"
              type="email"
              required
              autoComplete="email"
              value={form.email}
              onChange={handleChange}
              placeholder="tu@email.com"
            />
          </div>

          <div className="field">
            <label htmlFor="phone">Teléfono *</label>
            <input
              id="phone"
              name="phone"
              type="tel"
              required
              autoComplete="tel"
              value={form.phone}
              onChange={handleChange}
              placeholder="+52 55 1234 5678"
            />
          </div>

          <div className="field">
            <label htmlFor="birthday">Cumpleaños *</label>
            <input
              id="birthday"
              name="birthday"
              type="date"
              required
              value={form.birthday}
              onChange={handleChange}
            />
          </div>

          {error && <p className="error">{error}</p>}

          <button type="submit" className="btn-primary" disabled={loading}>
            {loading ? 'Guardando...' : 'Continuar →'}
          </button>
        </form>
      </div>
    </div>
  )
}
