import { useEffect, useState } from 'react'
import { useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { motion, AnimatePresence } from 'framer-motion'
import { supabase } from '../lib/supabase'
import { getSession } from '../lib/session'
import { isAdminAuthed } from '../lib/adminAuth'
import ProgressBar from '../components/ProgressBar'
import QuestionCard from '../components/QuestionCard'
import type { EventQuestion } from '../lib/types'

type SavedAnswers = Record<string, number>

const STORAGE_KEY = 'matchmaking_answers'

const slideVariants = {
  enter: (dir: number) => ({ x: dir > 0 ? 56 : -56, opacity: 0 }),
  center: { x: 0, opacity: 1 },
  exit: (dir: number) => ({ x: dir > 0 ? -56 : 56, opacity: 0 }),
}

export default function Questionnaire() {
  const navigate = useNavigate()
  const { code } = useParams<{ code: string }>()
  const [searchParams] = useSearchParams()
  const returnToAdmin = searchParams.get('return') === 'admin'
  const session = getSession()

  const [questions, setQuestions] = useState<EventQuestion[]>([])
  const [current, setCurrent] = useState(0)
  const [direction, setDirection] = useState(1)
  const [answers, setAnswers] = useState<SavedAnswers>(() => {
    try { return JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '{}') } catch { return {} }
  })
  const [loading, setLoading] = useState(true)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!session) { navigate(`/e/${code}`); return }
    loadQuestions()
  }, [])

  async function loadQuestions() {
    const { data, error: dbError } = await supabase
      .from('event_questions')
      .select('*, questions(*)')
      .eq('active', true)
      .eq('event_id', session!.eventId)
      .order('display_order')

    if (dbError || !data) { setError('Error cargando preguntas.'); setLoading(false); return }
    setQuestions(data as EventQuestion[])
    setLoading(false)
  }

  function handleAnswer(questionId: string, value: number) {
    const updated = { ...answers, [questionId]: value }
    setAnswers(updated)
    localStorage.setItem(STORAGE_KEY, JSON.stringify(updated))
    if (current < questions.length - 1) {
      setTimeout(() => {
        setDirection(1)
        setCurrent(c => c + 1)
      }, 260)
    }
  }

  function handleBack() {
    if (current > 0) {
      setDirection(-1)
      setCurrent(c => c - 1)
    }
  }

  async function handleSubmit() {
    if (!session) return
    setSubmitting(true)
    setError(null)

    const answerRows = questions.map(eq => ({
      question_id: eq.question_id,
      value: answers[eq.question_id] ?? 3,
    }))

    const { error: insertError } = await supabase.rpc('submit_answers', {
      p_token:    session.token,
      p_event_id: session.eventId,
      p_answers:  answerRows,
    })

    if (insertError) {
      setError('Error guardando respuestas. Intenta de nuevo.')
      setSubmitting(false)
      return
    }

    localStorage.removeItem(STORAGE_KEY)

    // Admin answering their own questionnaire → back to the admin panel
    // (guarded: only a logged-in admin can be sent there)
    if (returnToAdmin && isAdminAuthed()) {
      navigate(`/admin/${session.eventId}`)
      return
    }
    navigate(`/e/${code}/reveal`)
  }

  if (loading) return <div className="page-center"><p className="muted">Cargando...</p></div>
  if (error) return <div className="page-center"><p className="error">{error}</p></div>
  if (questions.length === 0) return <div className="page-center"><p>No hay preguntas activas.</p></div>

  const q = questions[current]
  const isLast = current === questions.length - 1
  const currentAnswer = answers[q.question_id]
  const allAnswered = questions.every(eq => answers[eq.question_id] !== undefined)

  return (
    <div className="page-center">
      <div className="questionnaire">
        <ProgressBar current={current} total={questions.length} />

        <AnimatePresence mode="wait" custom={direction}>
          <motion.div
            key={current}
            custom={direction}
            variants={slideVariants}
            initial="enter"
            animate="center"
            exit="exit"
            transition={{ duration: 0.22, ease: 'easeInOut' }}
          >
            <QuestionCard
              text={q.questions.text}
              value={currentAnswer}
              onChange={val => handleAnswer(q.question_id, val)}
            />
          </motion.div>
        </AnimatePresence>

        {error && <p className="error">{error}</p>}

        <div className="nav-buttons">
          <button className="btn-ghost" onClick={handleBack} disabled={current === 0}>
            ← Atrás
          </button>
          {isLast && (
            <button
              className="btn-primary"
              onClick={handleSubmit}
              disabled={submitting || !allAnswered}
            >
              {submitting ? 'Enviando...' : 'Enviar ✓'}
            </button>
          )}
        </div>

        <p className="question-counter">{current + 1} / {questions.length}</p>
      </div>
    </div>
  )
}
