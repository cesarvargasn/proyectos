import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { FeedbackQuestion, FeedbackType } from '../lib/types'

interface Props { eventId: string }

const TYPES: { value: FeedbackType; label: string }[] = [
  { value: 'rating',  label: 'Rating 1-5' },
  { value: 'boolean', label: 'Sí / No' },
  { value: 'text',    label: 'Texto libre' },
]

export default function FeedbackAdmin({ eventId }: Props) {
  const [questions, setQuestions] = useState<FeedbackQuestion[]>([])
  const [responses, setResponses] = useState<Record<string, unknown>[]>([])
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')

  const [newText, setNewText] = useState('')
  const [newType, setNewType] = useState<FeedbackType>('rating')

  useEffect(() => { load() }, [eventId])

  async function load() {
    setLoading(true)
    setErr('')
    const [qRes, fRes] = await Promise.all([
      supabase.from('feedback_questions').select('*').order('order_index'),
      supabase.rpc('get_event_feedback', { p_event_id: eventId }),
    ])
    if (qRes.error) setErr(`Error: ${qRes.error.message}`)
    setQuestions((qRes.data ?? []) as FeedbackQuestion[])
    setResponses((fRes.data ?? []).map((r: { answers: Record<string, unknown> }) => r.answers ?? {}))
    setLoading(false)
  }

  async function addQuestion() {
    if (!newText.trim()) return
    const maxOrder = questions.reduce((m, q) => Math.max(m, q.order_index), 0)
    const { error } = await supabase.from('feedback_questions')
      .insert({ text: newText.trim(), type: newType, order_index: maxOrder + 1, active: true })
    if (error) { setErr(error.message); return }
    setNewText('')
    load()
  }

  async function patchQuestion(id: string, patch: Partial<FeedbackQuestion>) {
    setQuestions(qs => qs.map(q => q.id === id ? { ...q, ...patch } : q))
    const { error } = await supabase.from('feedback_questions').update(patch).eq('id', id)
    if (error) setErr(error.message)
  }

  async function deleteQuestion(id: string) {
    if (!confirm('¿Borrar esta pregunta de feedback?')) return
    await supabase.from('feedback_questions').delete().eq('id', id)
    load()
  }

  async function move(id: string, dir: -1 | 1) {
    const sorted = [...questions].sort((a, b) => a.order_index - b.order_index)
    const i = sorted.findIndex(q => q.id === id)
    const j = i + dir
    if (j < 0 || j >= sorted.length) return
    const a = sorted[i], b = sorted[j]
    await Promise.all([
      supabase.from('feedback_questions').update({ order_index: b.order_index }).eq('id', a.id),
      supabase.from('feedback_questions').update({ order_index: a.order_index }).eq('id', b.id),
    ])
    load()
  }

  // ── Summary aggregation ──
  function summarize(q: FeedbackQuestion) {
    const vals = responses.map(r => r[q.id]).filter(v => v !== undefined && v !== null && v !== '')
    if (q.type === 'rating') {
      const nums = vals.map(Number).filter(n => !isNaN(n))
      const avg = nums.length ? (nums.reduce((s, n) => s + n, 0) / nums.length) : 0
      return { kind: 'rating' as const, avg, n: nums.length }
    }
    if (q.type === 'boolean') {
      const bools = vals.map(v => v === true || v === 'true' || v === 'si' || v === 1)
      const yes = bools.filter(Boolean).length
      return { kind: 'boolean' as const, pct: bools.length ? Math.round((yes / bools.length) * 100) : 0, n: bools.length }
    }
    return { kind: 'text' as const, comments: vals.map(String).filter(s => s.trim()) }
  }

  if (loading) return <p className="admin-loading">Cargando feedback...</p>

  const sorted = [...questions].sort((a, b) => a.order_index - b.order_index)

  return (
    <div className="admin-section">
      {err && <p className="error">{err}</p>}

      {/* ── Summary ── */}
      <div>
        <h3 className="admin-section-title">Resumen ({responses.length} respuestas)</h3>
        {responses.length === 0 ? (
          <p className="muted">Aún no hay respuestas. Comparte <code>/e/CÓDIGO/feedback</code>.</p>
        ) : (
          <div className="fb-summary">
            {sorted.filter(q => q.type !== 'text').map(q => {
              const s = summarize(q)
              return (
                <div key={q.id} className="fb-summary-row">
                  <span className="fb-summary-q">{q.text}</span>
                  <span className="fb-summary-val">
                    {s.kind === 'rating' && <><strong>{s.avg.toFixed(2)}</strong> / 5 <span className="muted">({s.n})</span></>}
                    {s.kind === 'boolean' && <><strong>{s.pct}%</strong> sí <span className="muted">({s.n})</span></>}
                  </span>
                </div>
              )
            })}
            {sorted.filter(q => q.type === 'text').map(q => {
              const s = summarize(q)
              if (s.kind !== 'text') return null
              return (
                <div key={q.id} className="fb-comments">
                  <p className="fb-summary-q">{q.text}</p>
                  {s.comments.length === 0
                    ? <p className="muted">Sin comentarios.</p>
                    : <ul className="fb-comment-list">{s.comments.map((c, i) => <li key={i}>“{c}”</li>)}</ul>}
                </div>
              )
            })}
          </div>
        )}
      </div>

      {/* ── Question editor ── */}
      <div>
        <h3 className="admin-section-title">Preguntas del feedback</h3>
        <div className="add-question-form">
          <div className="field-row">
            <input className="input-wide" placeholder="Nueva pregunta de feedback..." value={newText}
              onChange={e => setNewText(e.target.value)} />
            <select value={newType} onChange={e => setNewType(e.target.value as FeedbackType)}>
              {TYPES.map(t => <option key={t.value} value={t.value}>{t.label}</option>)}
            </select>
            <button className="btn-primary" onClick={addQuestion}>+ Añadir</button>
          </div>
        </div>

        <table className="questions-table" style={{ marginTop: '20px' }}>
          <thead>
            <tr><th>Activa</th><th>Pregunta</th><th>Tipo</th><th>Orden</th><th></th></tr>
          </thead>
          <tbody>
            {sorted.map(q => (
              <tr key={q.id} className={q.active ? 'row-active' : ''}>
                <td><input type="checkbox" checked={q.active} onChange={() => patchQuestion(q.id, { active: !q.active })} /></td>
                <td>
                  <input className="qe-text-input" defaultValue={q.text}
                    onBlur={e => { const v = e.target.value.trim(); if (v && v !== q.text) patchQuestion(q.id, { text: v }) }} />
                </td>
                <td>
                  <select className="qe-mini-select" value={q.type}
                    onChange={e => patchQuestion(q.id, { type: e.target.value as FeedbackType })}>
                    {TYPES.map(t => <option key={t.value} value={t.value}>{t.label}</option>)}
                  </select>
                </td>
                <td style={{ whiteSpace: 'nowrap' }}>
                  <button className="btn-ghost qe-ord-btn" onClick={() => move(q.id, -1)}>↑</button>
                  <button className="btn-ghost qe-ord-btn" onClick={() => move(q.id, 1)}>↓</button>
                </td>
                <td><button className="btn-danger-sm" onClick={() => deleteQuestion(q.id)}>✕</button></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
