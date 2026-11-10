import { useEffect, useState } from 'react'
import {
  DndContext, PointerSensor, useSensor, useSensors, closestCorners,
  useDroppable, type DragEndEvent, type DragOverEvent,
} from '@dnd-kit/core'
import {
  SortableContext, verticalListSortingStrategy, arrayMove, useSortable,
} from '@dnd-kit/sortable'
import { CSS } from '@dnd-kit/utilities'
import { supabase } from '../lib/supabase'
import type { Question } from '../lib/types'

export const CATEGORIES = [
  { value: 'personalidad',   label: 'Personalidad' },
  { value: 'valores',        label: 'Valores' },
  { value: 'relacion',       label: 'Relación' },
  { value: 'lifestyle',      label: 'Lifestyle' },
  { value: 'humor',          label: 'Humor' },
  { value: 'suenos',         label: 'Sueños' },
  { value: 'sexualidad',     label: 'Sexualidad' },
  { value: 'familia',        label: 'Familia' },
  { value: 'espiritualidad', label: 'Espiritualidad' },
  { value: 'social',         label: 'Social' },
  { value: 'trabajo',        label: 'Trabajo' },
  { value: 'fisico',         label: 'Físico' },
  { value: 'general',        label: 'General' },
]
const catLabel = (v: string) => CATEGORIES.find(c => c.value === v)?.label ?? v

// Two containers; a question id lives in exactly one of them.
type ContainerId = 'bank' | 'active'

interface Props { eventId: string }

export default function QuestionEditor({ eventId }: Props) {
  const [questions, setQuestions] = useState<Record<string, Question>>({})
  const [bank, setBank] = useState<string[]>([])      // question ids in the bank
  const [active, setActive] = useState<string[]>([])  // question ids active in this event, in order
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState('')

  // New-question form
  const [nqText, setNqText] = useState('')
  const [nqCat, setNqCat] = useState('personalidad')
  const [nqWeight, setNqWeight] = useState('1')

  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 6 } }))

  useEffect(() => { load() }, [eventId])

  async function load() {
    setLoading(true)
    setErr('')
    const [qRes, eqRes] = await Promise.all([
      supabase.from('questions').select('*').is('deleted_at', null).order('created_at'),
      supabase.from('event_questions').select('question_id, display_order, active')
        .eq('event_id', eventId).eq('active', true).order('display_order'),
    ])
    if (qRes.error) { setErr(`Error cargando banco: ${qRes.error.message}`); setLoading(false); return }

    const qMap: Record<string, Question> = {}
    for (const q of (qRes.data ?? []) as Question[]) qMap[q.id] = q
    const activeIds = (eqRes.data ?? []).map(r => r.question_id).filter(id => qMap[id])
    const activeSet = new Set(activeIds)
    const bankIds = (qRes.data ?? []).map(q => q.id).filter(id => !activeSet.has(id))

    setQuestions(qMap)
    setActive(activeIds)
    setBank(bankIds)
    setLoading(false)
  }

  const containerOf = (id: string): ContainerId => (active.includes(id) ? 'active' : 'bank')

  // ── DnD: move between/within containers (visual), persist on drop ──
  function handleDragOver(e: DragOverEvent) {
    const { active: a, over } = e
    if (!over) return
    const activeId = String(a.id)
    const overId = String(over.id)
    const from = containerOf(activeId)
    // over can be a container droppable id ('bank'/'active') or another item id
    const to: ContainerId = overId === 'bank' || overId === 'active' ? overId as ContainerId : containerOf(overId)
    if (from === to) return

    if (to === 'active') {
      setBank(b => b.filter(x => x !== activeId))
      setActive(arr => arr.includes(activeId) ? arr : [...arr, activeId])
    } else {
      setActive(arr => arr.filter(x => x !== activeId))
      setBank(b => b.includes(activeId) ? b : [activeId, ...b])
    }
  }

  function handleDragEnd(e: DragEndEvent) {
    const { active: a, over } = e
    if (over) {
      const activeId = String(a.id)
      const overId = String(over.id)
      if (containerOf(activeId) === 'active' && overId !== 'active' && containerOf(overId) === 'active') {
        const oldI = active.indexOf(activeId)
        const newI = active.indexOf(overId)
        if (oldI !== newI && oldI >= 0 && newI >= 0) setActive(arr => arrayMove(arr, oldI, newI))
      }
    }
    // Persist on the next tick (state updates are queued)
    setTimeout(persist, 0)
  }

  async function persist() {
    setSaving(true)
    setErr('')
    // Active rows: upsert active=true with order; everything else for this event → active=false
    const upserts = active.map((qid, i) => ({
      event_id: eventId, question_id: qid, display_order: i + 1, active: true,
    }))
    if (upserts.length) {
      const { error } = await supabase.from('event_questions')
        .upsert(upserts, { onConflict: 'event_id,question_id' })
      if (error) { setErr(`Error guardando: ${error.message}`); setSaving(false); return }
    }
    // Deactivate any event_question for this event not in the active set
    const { data: rows } = await supabase.from('event_questions')
      .select('question_id').eq('event_id', eventId).eq('active', true)
    const toDeactivate = (rows ?? []).map(r => r.question_id).filter(id => !active.includes(id))
    if (toDeactivate.length) {
      await supabase.from('event_questions').update({ active: false })
        .eq('event_id', eventId).in('question_id', toDeactivate)
    }
    setSaving(false)
  }

  // ── Inline edits (operate on the shared question bank) ──
  async function updateQuestion(id: string, patch: Partial<Pick<Question, 'text' | 'category' | 'weight'>>) {
    setQuestions(m => ({ ...m, [id]: { ...m[id], ...patch } }))
    const { error } = await supabase.from('questions').update(patch).eq('id', id)
    if (error) setErr(`Error: ${error.message}`)
  }

  async function softDelete(id: string) {
    if (!confirm('¿Borrar del banco? (soft delete — no rompe eventos que ya la usan)')) return
    setBank(b => b.filter(x => x !== id))
    setActive(a => a.filter(x => x !== id))
    const { error } = await supabase.from('questions').update({ deleted_at: new Date().toISOString() }).eq('id', id)
    if (error) setErr(`Error: ${error.message}`)
  }

  async function addQuestion() {
    if (!nqText.trim()) return
    const { data, error } = await supabase.from('questions')
      .insert({ text: nqText.trim(), category: nqCat, weight: parseFloat(nqWeight) || 1 })
      .select('*').single()
    if (error || !data) { setErr(`Error: ${error?.message ?? 'desconocido'}`); return }
    const q = data as Question
    setQuestions(m => ({ ...m, [q.id]: q }))
    setBank(b => [q.id, ...b])
    setNqText('')
  }

  if (loading) return <p className="admin-loading">Cargando editor...</p>

  return (
    <div className="admin-section">
      {/* New question */}
      <div className="add-question-form">
        <h3>Nueva pregunta (al banco)</h3>
        <div className="field-row">
          <input className="input-wide" placeholder="Texto de la pregunta..." value={nqText}
            onChange={e => setNqText(e.target.value)} />
          <select value={nqCat} onChange={e => setNqCat(e.target.value)}>
            {CATEGORIES.map(c => <option key={c.value} value={c.value}>{c.label}</option>)}
          </select>
          <input className="input-weight" type="number" min="0.5" max="5" step="0.5" value={nqWeight}
            onChange={e => setNqWeight(e.target.value)} title="Peso" />
          <button className="btn-primary" onClick={addQuestion}>+ Añadir</button>
        </div>
      </div>

      {err && <p className="error">{err}</p>}
      <p className="muted">
        Arrastra preguntas del banco a la derecha para activarlas en este evento. En el panel derecho,
        arrastra para reordenar (= orden del cuestionario) y edita peso/categoría inline. {saving && '· Guardando…'}
      </p>

      <DndContext sensors={sensors} collisionDetection={closestCorners}
        onDragOver={handleDragOver} onDragEnd={handleDragEnd}>
        <div className="qe-grid">
          <Panel id="bank" title={`Banco (${bank.length})`}>
            <SortableContext items={bank} strategy={verticalListSortingStrategy}>
              {bank.map(id => questions[id] && (
                <BankItem key={id} q={questions[id]}
                  onEditText={t => updateQuestion(id, { text: t })}
                  onDelete={() => softDelete(id)} />
              ))}
              {bank.length === 0 && <p className="qe-empty">Vacío</p>}
            </SortableContext>
          </Panel>

          <Panel id="active" title={`Activas en este evento (${active.length})`}>
            <SortableContext items={active} strategy={verticalListSortingStrategy}>
              {active.map(id => questions[id] && (
                <ActiveItem key={id} q={questions[id]}
                  onCat={c => updateQuestion(id, { category: c })}
                  onWeight={w => updateQuestion(id, { weight: w })} />
              ))}
              {active.length === 0 && <p className="qe-empty">Arrastra preguntas aquí</p>}
            </SortableContext>
          </Panel>
        </div>
      </DndContext>
    </div>
  )
}

function Panel({ id, title, children }: { id: ContainerId; title: string; children: React.ReactNode }) {
  const { setNodeRef, isOver } = useDroppable({ id })
  return (
    <div className={`qe-panel${isOver ? ' qe-panel-over' : ''}`}>
      <h4 className="qe-panel-title">{title}</h4>
      <div ref={setNodeRef} className="qe-list">{children}</div>
    </div>
  )
}

function BankItem({ q, onEditText, onDelete }:
  { q: Question; onEditText: (t: string) => void; onDelete: () => void }) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({ id: q.id })
  const style = { transform: CSS.Transform.toString(transform), transition, opacity: isDragging ? 0.4 : 1 }
  const [editing, setEditing] = useState(false)
  const [text, setText] = useState(q.text)
  return (
    <div ref={setNodeRef} style={style} className="qe-item">
      <span className="qe-handle" {...attributes} {...listeners}>⋮⋮</span>
      {editing ? (
        <input className="qe-text-input" value={text} autoFocus
          onChange={e => setText(e.target.value)}
          onBlur={() => { setEditing(false); if (text.trim() && text !== q.text) onEditText(text.trim()) }}
          onKeyDown={e => { if (e.key === 'Enter') (e.target as HTMLInputElement).blur() }} />
      ) : (
        <span className="qe-text" onClick={() => setEditing(true)} title="Click para editar">{q.text}</span>
      )}
      <span className="qe-cat-tag">{catLabel(q.category)}</span>
      <button className="btn-danger-sm" onClick={onDelete} title="Borrar del banco">✕</button>
    </div>
  )
}

function ActiveItem({ q, onCat, onWeight }:
  { q: Question; onCat: (c: string) => void; onWeight: (w: number) => void }) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({ id: q.id })
  const style = { transform: CSS.Transform.toString(transform), transition, opacity: isDragging ? 0.4 : 1 }
  return (
    <div ref={setNodeRef} style={style} className="qe-item qe-item-active">
      <span className="qe-handle" {...attributes} {...listeners}>⋮⋮</span>
      <span className="qe-text">{q.text}</span>
      <select className="qe-mini-select" value={q.category} onChange={e => onCat(e.target.value)}>
        {CATEGORIES.map(c => <option key={c.value} value={c.value}>{c.label}</option>)}
      </select>
      <input className="qe-mini-weight" type="number" min="0.5" max="5" step="0.5"
        value={q.weight} title="Peso" onChange={e => onWeight(parseFloat(e.target.value) || 1)} />
    </div>
  )
}
