import { useEffect, useRef, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { motion, AnimatePresence } from 'framer-motion'
import { supabase } from '../lib/supabase'
import { getSession } from '../lib/session'
import type { EventPhase } from '../lib/types'
import { groupName, groupColor, roundLabel } from '../lib/funnel'

const FUNNEL_COUNTDOWN_SECONDS = 5

interface MyGroup { round: number; group_idx: number; score: number; members: string[] }

const COUNTDOWN_SECONDS = 15

function WaitingScreen() {
  const [dots, setDots] = useState(1)

  useEffect(() => {
    const id = setInterval(() => setDots(d => (d % 3) + 1), 700)
    return () => clearInterval(id)
  }, [])

  return (
    <div className="page-center">
      <div className="card text-center">
        <motion.div
          className="waiting-pulse-box"
          animate={{
            borderColor: ['#EDE0C4', '#C8400A', '#EDE0C4'],
            scale: [1, 1.05, 1],
          }}
          transition={{ duration: 2, repeat: Infinity, ease: 'easeInOut' }}
        />
        <h2 className="waiting-title">
          Espera{'.' .repeat(dots)}
        </h2>
        <p>Cuando todos terminen, el algoritmo despertará.</p>
        <p className="muted">Mantén esta pantalla abierta.</p>
      </div>
    </div>
  )
}

function MatchingScreen() {
  return (
    <div className="page-center">
      <div className="card text-center">
        <motion.div
          className="waiting-pulse-box"
          animate={{ rotate: [0, 90, 180, 270, 360] }}
          transition={{ duration: 1.4, repeat: Infinity, ease: 'linear' }}
          style={{ borderStyle: 'dashed' }}
        />
        <h2>Calculando...</h2>
        <p>El algoritmo está buscando a tu persona.</p>
      </div>
    </div>
  )
}

export default function Reveal() {
  const navigate = useNavigate()
  const { code } = useParams<{ code: string }>()
  const session = getSession()

  const [phase, setPhase] = useState<EventPhase>('waiting')
  const [countdown, setCountdown] = useState<number | null>(null)
  const [match, setMatch] = useState<{ name: string; score: number; trio: boolean } | null | 'none'>(null)
  // Rondas embudo
  const [funnelRound, setFunnelRound] = useState(0)
  const [funnelView, setFunnelView] = useState<'countdown' | 'group' | null>(null)
  const [group, setGroup] = useState<MyGroup | null | 'none'>(null)

  useEffect(() => {
    if (!session) { navigate(`/e/${code}`); return }
    subscribeToReveal()
    checkCurrentPhase()
  }, [])

  async function checkCurrentPhase() {
    let { data, error } = await supabase
      .from('event_state')
      .select('phase, reveal_at, funnel_round')
      .eq('event_id', session!.eventId)
      .single()
    if (error) {
      // Sin migration_embudo.sql la columna funnel_round no existe
      const res = await supabase
        .from('event_state')
        .select('phase, reveal_at')
        .eq('event_id', session!.eventId)
        .single()
      data = res.data ? { ...res.data, funnel_round: 0 } : null
    }

    if (!data) return

    if (data.phase === 'funnel' && data.funnel_round) {
      startFunnelCountdown(data.funnel_round, data.reveal_at)
    } else if (data.phase === 'countdown' && data.reveal_at) {
      startCountdownFromTimestamp(data.reveal_at)
    } else if (data.phase === 'reveal') {
      setPhase('reveal')
      await loadMatch()
    } else {
      setPhase(data.phase as EventPhase)
    }
  }

  function subscribeToReveal() {
    const channel = `reveal-room-${session!.eventId}`
    supabase
      .channel(channel)
      .on('broadcast', { event: 'COUNTDOWN' }, ({ payload }) => {
        startCountdownFromTimestamp(payload.reveal_at as string)
      })
      .on('broadcast', { event: 'FUNNEL' }, ({ payload }) => {
        startFunnelCountdown(payload.round as number, payload.reveal_at as string)
      })
      .on('broadcast', { event: 'RESET' }, () => {
        setFunnelView(null); setFunnelRound(0); setGroup(null); setMatch(null)
        setPhase('waiting')
      })
      .on('broadcast', { event: 'REVEAL' }, () => {
        setPhase('reveal')
        loadMatch()
      })
      .subscribe()
  }

  const funnelTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)

  function startFunnelCountdown(round: number, revealAt: string | null) {
    setPhase('funnel')
    setFunnelRound(round)
    setGroup(null)
    clearTimeout(funnelTimer.current)
    const target = revealAt ? new Date(revealAt).getTime() : Date.now()
    const tick = () => {
      const diff = Math.ceil((target - Date.now()) / 1000)
      if (diff <= 0) {
        setFunnelView('group')
        loadGroup()
      } else {
        setFunnelView('countdown')
        setCountdown(diff)
        funnelTimer.current = setTimeout(tick, 500)
      }
    }
    tick()
  }

  async function loadGroup() {
    if (!session) return
    const { data: rows } = await supabase.rpc('get_my_group', {
      p_token:    session.token,
      p_event_id: session.eventId,
    })
    const row = rows?.[0]
    setGroup(row ? (row as MyGroup) : 'none')
  }

  function startCountdownFromTimestamp(revealAt: string) {
    setFunnelView(null)
    setPhase('countdown')
    const tick = () => {
      const diff = Math.ceil((new Date(revealAt).getTime() - Date.now()) / 1000)
      if (diff <= 0) {
        setCountdown(0)
        setPhase('reveal')
        loadMatch()
      } else {
        setCountdown(diff)
        setTimeout(tick, 500)
      }
    }
    tick()
  }

  async function loadMatch() {
    if (!session) return

    const { data: rows } = await supabase.rpc('get_my_match', {
      p_token:    session.token,
      p_event_id: session.eventId,
    })

    const list = (rows ?? []) as { partner_name: string | null; score: number }[]
    if (!list.length) { setMatch('none'); return }
    // Trío = 2 filas: mostrar ambos nombres y promediar
    const names = list.map(r => r.partner_name ?? 'Alguien')
    const avg = list.reduce((s, r) => s + r.score, 0) / list.length
    setMatch({ name: names.join(' y '), score: Math.round(avg * 100), trio: list.length > 1 })
  }

  if (phase === 'waiting') return <WaitingScreen />
  if (phase === 'matching') return <MatchingScreen />

  if (phase === 'funnel') {
    if (funnelView === 'countdown') {
      return (
        <div className="countdown-screen">
          <p className="countdown-label">{roundLabel(funnelRound)} — tu grupo en</p>
          <AnimatePresence mode="wait">
            <motion.div
              key={countdown}
              className="countdown-number"
              initial={{ scale: 1.5, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
              exit={{ scale: 0.5, opacity: 0 }}
              transition={{ duration: 0.28 }}
            >
              {countdown ?? FUNNEL_COUNTDOWN_SECONDS}
            </motion.div>
          </AnimatePresence>
        </div>
      )
    }
    if (group === null) {
      return <div className="page-center"><div className="card text-center"><p className="muted">Cargando...</p></div></div>
    }
    if (group === 'none') {
      return (
        <div className="page-center">
          <div className="card text-center">
            <h2>{roundLabel(funnelRound)}</h2>
            <p className="muted">No quedaste en esta ronda. Llegaste tarde al cuestionario — habla con el admin.</p>
          </div>
        </div>
      )
    }
    const color = groupColor(group.group_idx)
    return (
      <div className="reveal-screen">
        <motion.p className="reveal-label" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.2 }}>
          {roundLabel(group.round)} · tu grupo
        </motion.p>
        <motion.h1
          className="reveal-name"
          style={{ color }}
          initial={{ scale: 0.72, opacity: 0 }}
          animate={{ scale: 1, opacity: 1 }}
          transition={{ type: 'spring', stiffness: 170, damping: 11, delay: 0.4 }}
        >
          {groupName(group.round, group.group_idx)}
        </motion.h1>
        <motion.div
          className="funnel-members"
          initial={{ opacity: 0, y: 16 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.9 }}
        >
          <p className="reveal-label">Búscalos</p>
          <ul>
            {group.members.map((m, i) => (
              <motion.li key={m + i} initial={{ opacity: 0, x: -10 }} animate={{ opacity: 1, x: 0 }} transition={{ delay: 1.0 + i * 0.12 }}>
                {m}
              </motion.li>
            ))}
          </ul>
        </motion.div>
        <motion.div
          className="compatibility-badge"
          style={{ borderColor: color }}
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 1.2 + group.members.length * 0.12 }}
        >
          {Math.round(group.score * 100)}% afinidad de grupo
        </motion.div>
      </div>
    )
  }

  if (phase === 'countdown') {
    return (
      <div className="countdown-screen">
        <p className="countdown-label">Tu persona se revela en</p>
        <AnimatePresence mode="wait">
          <motion.div
            key={countdown}
            className="countdown-number"
            initial={{ scale: 1.5, opacity: 0 }}
            animate={{ scale: 1, opacity: 1 }}
            exit={{ scale: 0.5, opacity: 0 }}
            transition={{ duration: 0.28 }}
          >
            {countdown ?? COUNTDOWN_SECONDS}
          </motion.div>
        </AnimatePresence>
      </div>
    )
  }

  if (phase === 'reveal') {
    if (match === null) {
      return <div className="page-center"><div className="card text-center"><p className="muted">Cargando...</p></div></div>
    }

    if (match === 'none') {
      return (
        <div className="reveal-screen">
          <motion.p
            className="reveal-label"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ delay: 0.4 }}
          >
            Esta noche
          </motion.p>
          <motion.h1
            className="reveal-name"
            initial={{ scale: 0.7, opacity: 0 }}
            animate={{ scale: 1, opacity: 1 }}
            transition={{ type: 'spring', stiffness: 160, damping: 12, delay: 0.6 }}
          >
            Lobo solitario
          </motion.h1>
          <motion.div
            className="compatibility-badge"
            style={{ background: 'transparent', borderColor: 'var(--muted)', color: 'var(--muted)' }}
            initial={{ opacity: 0, y: 16 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 1.1 }}
          >
            Esta noche vas por libre
          </motion.div>
        </div>
      )
    }

    return (
      <div className="reveal-screen">
        <motion.p
          className="reveal-label"
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.3 }}
        >
          {match.trio ? 'Tu trío esta noche' : 'Tu persona esta noche'}
        </motion.p>
        <motion.h1
          className="reveal-name"
          initial={{ scale: 0.72, opacity: 0 }}
          animate={{ scale: 1, opacity: 1 }}
          transition={{ type: 'spring', stiffness: 170, damping: 11, delay: 0.5 }}
        >
          {match.name}
        </motion.h1>
        <motion.div
          className="compatibility-badge"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 1.0 }}
        >
          {match.score}% afinidad
        </motion.div>
      </div>
    )
  }

  return null
}
