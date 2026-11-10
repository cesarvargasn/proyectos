import { useEffect, useState } from 'react'
import { useParams, Link } from 'react-router-dom'
import { motion, AnimatePresence } from 'framer-motion'
import { supabase } from '../lib/supabase'
import { getSession } from '../lib/session'
import type { FeedbackQuestion } from '../lib/types'

export default function Feedback() {
  const { code } = useParams<{ code: string }>()
  const session = getSession()

  const [eventId, setEventId] = useState<string | null>(null)
  const [eventName, setEventName] = useState('')
  const [questions, setQuestions] = useState<FeedbackQuestion[]>([])
  const [answers, setAnswers] = useState<Record<string, number | boolean | string>>({})
  const [loading, setLoading] = useState(true)
  const [submitting, setSubmitting] = useState(false)
  const [done, setDone] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => { load() }, [code])

  async function load() {
    setLoading(true)
    const { data: ev } = await supabase.from('events').select('id, name').eq('code', (code ?? '').toUpperCase()).single()
    if (!ev) { setError('Evento no encontrado.'); setLoading(false); return }
    setEventId(ev.id)
    setEventName(ev.name)
    const { data: qs } = await supabase.from('feedback_questions').select('*').eq('active', true).order('order_index')
    setQuestions((qs ?? []) as FeedbackQuestion[])
    setLoading(false)
  }

  function setAnswer(id: string, value: number | boolean | string) {
    setAnswers(a => ({ ...a, [id]: value }))
  }

  async function submit() {
    if (!eventId) return
    setSubmitting(true)
    setError(null)
    // participant_id taken silently from the local session if present; never shown
    const { error: dbErr } = await supabase.from('feedback').insert({
      event_id: eventId,
      participant_id: session?.participantId ?? null,
      answers,
    })
    if (dbErr) { setError('No se pudo enviar. Intenta de nuevo.'); setSubmitting(false); return }
    setDone(true)
  }

  if (loading) return <div className="page-center"><p className="muted">Cargando...</p></div>

  if (error && !eventId) {
    return (
      <div className="page-center">
        <div className="card text-center"><p className="error">{error}</p><Link to="/" className="back-link">← Inicio</Link></div>
      </div>
    )
  }

  return (
    <div className="page-center">
      <AnimatePresence mode="wait">
        {done ? (
          <motion.div key="thanks" className="card text-center"
            initial={{ opacity: 0, scale: 0.9 }} animate={{ opacity: 1, scale: 1 }}
            transition={{ type: 'spring', stiffness: 160, damping: 14 }}>
            <motion.div className="waiting-pulse-box"
              animate={{ borderColor: ['var(--orange)', 'var(--border)', 'var(--orange)'], rotate: [0, 45, 0] }}
              transition={{ duration: 2, repeat: Infinity, ease: 'easeInOut' }} />
            <h1 className="title">Gracias</h1>
            <p className="subtitle">Tu feedback quedó registrado.</p>
            <Link to="/" className="back-link">← Inicio</Link>
          </motion.div>
        ) : (
          <motion.div key="form" className="card"
            initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.4 }}>
            <div className="login-header">
              <p>{eventName}</p>
              <h1 className="title">¿Cómo estuvo?</h1>
            </div>
            <p className="subtitle">Tu respuesta es anónima en el agregado.</p>

            <div className="form">
              {questions.map(q => (
                <div key={q.id} className="field">
                  <label>{q.text}</label>
                  {q.type === 'rating' && (
                    <div className="fb-rating">
                      {[1, 2, 3, 4, 5].map(n => (
                        <button key={n} type="button"
                          className={`fb-rating-btn${answers[q.id] === n ? ' selected' : ''}`}
                          onClick={() => setAnswer(q.id, n)}>{n}</button>
                      ))}
                    </div>
                  )}
                  {q.type === 'boolean' && (
                    <div className="fb-bool">
                      <button type="button" className={`fb-bool-btn${answers[q.id] === true ? ' selected' : ''}`}
                        onClick={() => setAnswer(q.id, true)}>Sí</button>
                      <button type="button" className={`fb-bool-btn${answers[q.id] === false ? ' selected' : ''}`}
                        onClick={() => setAnswer(q.id, false)}>No</button>
                    </div>
                  )}
                  {q.type === 'text' && (
                    <textarea className="fb-textarea" rows={3} value={(answers[q.id] as string) ?? ''}
                      onChange={e => setAnswer(q.id, e.target.value)} placeholder="Opcional..." />
                  )}
                </div>
              ))}

              {questions.length === 0 && <p className="muted">No hay preguntas de feedback activas.</p>}
              {error && <p className="error">{error}</p>}

              <button className="btn-primary" onClick={submit} disabled={submitting || questions.length === 0}>
                {submitting ? 'Enviando...' : 'Enviar ✓'}
              </button>
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  )
}
