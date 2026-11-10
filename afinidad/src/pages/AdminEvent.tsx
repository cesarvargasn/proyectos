import { useEffect, useState } from 'react'
import { Link, useParams, useNavigate } from 'react-router-dom'
import { QRCodeSVG } from 'qrcode.react'
import { supabase } from '../lib/supabase'
import { runFunnel } from '../lib/matching'
import { groupName, groupColor, roundLabel, FUNNEL_ROUNDS } from '../lib/funnel'
import AffinityGraph from '../components/AffinityGraph'
import QuestionEditor from '../components/QuestionEditor'
import FeedbackAdmin from '../components/FeedbackAdmin'
import { useAdminAuth, signInAdmin, signOutAdmin } from '../lib/adminAuth'
import { saveSession } from '../lib/session'
import type { Participant, EventState, Match } from '../lib/types'

interface MatchWithNames extends Match {
  participant_a_data: { first_name: string }
  participant_b_data: { first_name: string }
}

export default function AdminEvent() {
  const { eventId } = useParams<{ eventId: string }>()
  const navigate = useNavigate()
  const authed = useAdminAuth()
  const [emailInput, setEmailInput] = useState('')
  const [passwordInput, setPasswordInput] = useState('')
  const [loginError, setLoginError] = useState('')
  const [loggingIn, setLoggingIn] = useState(false)
  const [tab, setTab] = useState<'participants' | 'questions' | 'matches' | 'funnel' | 'map' | 'feedback'>('participants')

  const [eventName, setEventName] = useState('')
  const [eventCode, setEventCode] = useState('')
  const [participants, setParticipants] = useState<Participant[]>([])
  const [eventState, setEventState] = useState<EventState | null>(null)
  const [matchPairs, setMatchPairs] = useState<MatchWithNames[]>([])

  const [loading, setLoading] = useState(false)
  const [matchingLoading, setMatchingLoading] = useState(false)
  const [countdownLoading, setCountdownLoading] = useState(false)

  const [statusMsg, setStatusMsg] = useState('')
  const [errorMsg, setErrorMsg] = useState('')

  // Admin participation
  const [adminName, setAdminName] = useState('')
  const [joiningAdmin, setJoiningAdmin] = useState(false)

  const [copied, setCopied] = useState(false)

  // Rondas embudo
  const [funnel, setFunnel] = useState<{ round: number; group_idx: number; score: number; name: string }[]>([])
  const [funnelLoading, setFunnelLoading] = useState(false)
  const [showQR, setShowQR] = useState(false)

  useEffect(() => {
    if (authed && eventId) loadAll()
  }, [authed, eventId])

  const eventUrl = eventCode ? `${window.location.origin}/e/${eventCode}` : ''

  async function loadAll() {
    setLoading(true)
    const [evRes, pRes, esRes, mRes] = await Promise.all([
      supabase.from('events').select('name, code').eq('id', eventId!).single(),
      supabase.from('participants').select('*').eq('event_id', eventId!).order('created_at'),
      supabase.from('event_state').select('*').eq('event_id', eventId!).order('id').limit(1),
      supabase
        .from('matches')
        .select('*, participant_a_data:participants!matches_participant_a_fkey(first_name), participant_b_data:participants!matches_participant_b_fkey(first_name)')
        .eq('event_id', eventId!),
    ])
    if (evRes.data) { setEventName(evRes.data.name); setEventCode(evRes.data.code) }
    if (pRes.data) setParticipants(pRes.data)
    const esRow = Array.isArray(esRes.data) ? esRes.data[0] : esRes.data
    if (esRow) setEventState(esRow as EventState)
    else setEventState(null)
    if (mRes.data) setMatchPairs(mRes.data as MatchWithNames[])
    const fRes = await supabase
      .from('funnel_groups')
      .select('round, group_idx, score, participants(first_name)')
      .eq('event_id', eventId!)
    if (fRes.data) {
      setFunnel(fRes.data.map(r => ({
        round: r.round, group_idx: r.group_idx, score: r.score,
        name: (r.participants as unknown as { first_name: string } | null)?.first_name ?? '—',
      })))
    } else setFunnel([])
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
  }

  function logout() { signOutAdmin() }

  // ── Admin participation ──

  // Guarantees exactly one event_state row exists for this event; returns it.
  // Computes the id in code (no DB sequence needed).
  async function ensureEventState(): Promise<EventState | null> {
    const { data } = await supabase
      .from('event_state').select('*').eq('event_id', eventId!).order('id').limit(1)
    const row = data?.[0]
    if (row) return row as EventState

    // Next id = current max + 1 (handled here so the DB needs no sequence default)
    const { data: maxRows } = await supabase
      .from('event_state').select('id').order('id', { ascending: false }).limit(1)
    const nextId = (maxRows?.[0]?.id ?? 0) + 1

    const { data: inserted, error } = await supabase
      .from('event_state')
      .insert({ id: nextId, event_id: eventId!, phase: 'waiting', admin_participates: false })
      .select('*')
      .single()
    if (error) { setErrorMsg(`No pude crear el estado del evento: ${error.message}`); return null }
    return inserted as EventState
  }

  async function joinAsAdmin() {
    if (!adminName.trim() || joiningAdmin) return
    if (adminParticipants.length > 0) {
      setErrorMsg('Ya estás unido como admin. Refresca la página.')
      return
    }
    setJoiningAdmin(true)
    setErrorMsg('')

    // Make sure there is an event_state row to update
    const es = await ensureEventState()
    if (!es) { setJoiningAdmin(false); return }

    const { data, error } = await supabase
      .from('participants')
      .insert({
        event_id: eventId!,
        first_name: adminName.trim(),
        email: `admin-${Date.now()}@matchnight.local`,
        completed_at: new Date().toISOString(),
      })
      .select('id')
      .single()

    if (error || !data) {
      setErrorMsg(`Error al unirte: ${error?.message ?? 'desconocido'}`)
      setJoiningAdmin(false)
      return
    }

    const { error: esErr } = await supabase.from('event_state').update({
      admin_participates: true,
      admin_participant_id: data.id,
    }).eq('event_id', eventId!)

    if (esErr) {
      setErrorMsg(`Te registré pero no pude marcarte como admin: ${esErr.message}`)
      setJoiningAdmin(false)
      loadAll()
      return
    }

    setAdminName('')
    setStatusMsg('Te uniste como admin ✓')
    setJoiningAdmin(false)
    loadAll()
  }

  // Deletes ALL admin participants for this event (cleans duplicates too) + resets event_state.
  async function cleanupAdmins() {
    const ids = adminParticipants.map(p => p.id)
    if (ids.length === 0) return
    for (const id of ids) {
      await supabase.from('matches').delete().eq('event_id', eventId!)
        .or(`participant_a.eq.${id},participant_b.eq.${id}`)
    }
    await supabase.from('participants').delete().in('id', ids)
    await supabase.from('event_state').update({
      admin_participates: false,
      admin_participant_id: null,
      admin_partner_id: null,
    }).eq('event_id', eventId!)
    setStatusMsg('Registros de admin limpiados ✓')
    loadAll()
  }

  async function setAdminPartner(partnerId: string) {
    setErrorMsg('')
    await ensureEventState()
    const { error } = await supabase
      .from('event_state')
      .update({ admin_partner_id: partnerId || null })
      .eq('event_id', eventId!)
    if (error) {
      setErrorMsg(`No se pudo guardar tu dupla: ${error.message}. ¿Corriste migration_admin.sql en Supabase?`)
      return
    }
    setStatusMsg('Dupla del admin guardada ✓')
    loadAll()
  }

  async function leaveAsAdmin() {
    if (!confirm('¿Salir de participar? Se borrará tu registro de admin.')) return
    await cleanupAdmins()
    setStatusMsg('Saliste de participar')
  }

  function adminAnswerQuestionnaire() {
    if (!adminParticipant) return
    saveSession({
      participantId: adminParticipant.id,
      token: adminParticipant.token,
      firstName: adminParticipant.first_name,
      eventId: eventId!,
      eventCode,
    })
    navigate(`/e/${eventCode}/q?return=admin`)
  }

  async function handleRunMatching() {
    setMatchingLoading(true)
    setErrorMsg('')
    setStatusMsg('')
    try {
      // Mismo cálculo que "Armar embudo": un solo resultado para toda la noche
      const st = await ensureEventState()
      if (!st) return
      const r = await runFunnel(eventId!)
      setStatusMsg(funnelSummary(r))
      await supabase.from('event_state').update({ phase: 'matching', funnel_round: 0 }).eq('event_id', eventId!)
      loadAll()
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : 'Error calculando afinidad')
    } finally {
      setMatchingLoading(false)
    }
  }

  // ── Rondas embudo ──
  function funnelSummary(r: Awaited<ReturnType<typeof runFunnel>>): string {
    const name = (id: string) => participants.find(p => p.id === id)?.first_name ?? id
    const trio = r.trios.length ? ' + trío: ' + r.trios.map(t => t.map(name).join(', ')).join(' / ') : ''
    const solos = r.unmatchedIds.length ? ' — sin dupla: ' + r.unmatchedIds.map(name).join(', ') : ''
    return '✓ Listo: grupos ' + r.rounds.map(x => x.groups.length).join(' → ') + ' → '
      + r.matchCount + ' duplas' + trio + solos + '. Las rondas son opcionales; puedes revelar duplas directo.'
  }

  async function handleRunFunnel() {
    setFunnelLoading(true)
    setErrorMsg('')
    setStatusMsg('')
    try {
      const st = await ensureEventState()
      if (!st) return
      const r = await runFunnel(eventId!)
      setStatusMsg(funnelSummary(r))
      await supabase.from('event_state').update({ phase: 'matching', funnel_round: 0 }).eq('event_id', eventId!)
      loadAll()
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : 'Error armando el embudo')
    } finally {
      setFunnelLoading(false)
    }
  }

  async function revealRound(round: number) {
    setErrorMsg('')
    const revealAt = new Date(Date.now() + 5_000).toISOString()
    const { error } = await supabase.from('event_state')
      .update({ phase: 'funnel', funnel_round: round, reveal_at: revealAt })
      .eq('event_id', eventId!)
    if (error) { setErrorMsg('No pude revelar: ' + error.message); return }
    const ch = supabase.channel('reveal-room-' + eventId)
    await ch.subscribe()
    await ch.send({ type: 'broadcast', event: 'FUNNEL', payload: { round, reveal_at: revealAt } })
    setStatusMsg(roundLabel(round) + ' revelada (5s de cuenta regresiva)')
    loadAll()
  }

  async function resetToWaiting() {
    await supabase.from('event_state').update({ phase: 'waiting', funnel_round: 0, reveal_at: null }).eq('event_id', eventId!)
    const ch = supabase.channel('reveal-room-' + eventId)
    await ch.subscribe()
    await ch.send({ type: 'broadcast', event: 'RESET', payload: {} })
    setStatusMsg('Todos volvieron a la pantalla de espera')
    loadAll()
  }

  async function triggerCountdown() {
    setCountdownLoading(true)
    const revealAt = new Date(Date.now() + 15_000).toISOString()
    await supabase.from('event_state').update({ phase: 'countdown', reveal_at: revealAt }).eq('event_id', eventId!)
    const ch = supabase.channel(`reveal-room-${eventId}`)
    await ch.subscribe()
    await ch.send({ type: 'broadcast', event: 'COUNTDOWN', payload: { reveal_at: revealAt } })
    setStatusMsg('Countdown iniciado — 15s')
    setTimeout(async () => {
      await supabase.from('event_state').update({ phase: 'reveal' }).eq('event_id', eventId!)
      await ch.send({ type: 'broadcast', event: 'REVEAL', payload: {} })
      setCountdownLoading(false)
      loadAll()
    }, 16_000)
  }

  // ── CSV export (admin-only; generated client-side) ──
  function csvCell(value: unknown): string {
    const s = value == null ? '' : String(value)
    // Escape per RFC 4180: wrap in quotes if it contains comma/quote/newline,
    // and double any embedded quotes.
    if (/[",\n\r]/.test(s)) return `"${s.replace(/"/g, '""')}"`
    return s
  }

  function exportCSV() {
    const headers = ['first_name', 'email', 'phone', 'birthday', 'respondio', 'match_name', 'score']

    const rows = participants.map(p => {
      // Tríos tienen 2 filas por persona → juntar nombres y promediar
      const ms = matchPairs.filter(mp => mp.participant_a === p.id || mp.participant_b === p.id)
      let matchName = ''
      let score = ''
      if (ms.length) {
        matchName = ms.map(m => (m.participant_a === p.id
          ? m.participant_b_data?.first_name
          : m.participant_a_data?.first_name) ?? '').join(' + ')
        score = String(Math.round(ms.reduce((s, m) => s + m.score, 0) / ms.length * 100))
      }
      const isAdmin = p.id === adminId
      return [
        p.first_name,
        isAdmin ? '' : (p.email ?? ''),
        p.phone ?? '',
        p.birthday ?? '',
        p.completed_at ? 'si' : 'no',
        matchName,
        score,
      ]
    })

    const csv = [headers, ...rows].map(r => r.map(csvCell).join(',')).join('\r\n')
    // Prepend UTF-8 BOM so Excel reads accents (José, etc.) correctly
    const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8;' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    const safeName = (eventName || 'evento').replace(/[^\w-]+/g, '_')
    a.href = url
    a.download = `${safeName}_participantes.csv`
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
    URL.revokeObjectURL(url)
  }

  function copyEventLink() {
    navigator.clipboard.writeText(`${window.location.origin}/e/${eventCode}`)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  const completed = participants.filter(p => p.completed_at).length
  const total = participants.length
  const hasMatches = matchPairs.length > 0
  const completedParticipants = participants.filter(p => p.completed_at)

  // Admin participants are detected by their internal email marker (robust even if event_state is broken)
  const adminParticipants = participants.filter(p => (p.email ?? '').includes('@matchnight.local'))
  const adminParticipant =
    adminParticipants.find(p => p.id === eventState?.admin_participant_id) ?? adminParticipants[0] ?? null
  const adminId = adminParticipant?.id ?? null
  const adminPartnerId = eventState?.admin_partner_id ?? ''
  const hasDuplicateAdmins = adminParticipants.length > 1

  if (authed === null) {
    return <div className="page-center"><p className="muted">Cargando...</p></div>
  }

  if (!authed) {
    return (
      <div className="page-center">
        <div className="card">
          <div className="login-header"><p>Afinidad</p><h1 className="title">Admin</h1></div>
          <form onSubmit={login} className="form">
            <div className="field">
              <label>Email</label>
              <input type="email" value={emailInput} onChange={e => setEmailInput(e.target.value)} autoComplete="email" autoFocus />
            </div>
            <div className="field">
              <label>Contraseña</label>
              <input type="password" value={passwordInput} onChange={e => setPasswordInput(e.target.value)} autoComplete="current-password" />
            </div>
            {loginError && <p className="error">{loginError}</p>}
            <button type="submit" className="btn-primary" disabled={loggingIn}>
              {loggingIn ? 'Entrando...' : 'Entrar'}
            </button>
          </form>
        </div>
      </div>
    )
  }

  return (
    <div className="admin-layout">
      {showQR && (
        <div className="qr-overlay" onClick={() => setShowQR(false)}>
          <div className="qr-box" onClick={e => e.stopPropagation()}>
            <p className="qr-event-name">{eventName}</p>
            <div className="qr-code-wrap">
              <QRCodeSVG value={eventUrl} size={240} level="M" />
            </div>
            <p className="qr-code-text">{eventCode}</p>
            <p className="qr-url">{eventUrl}</p>
            <button className="btn-primary" onClick={() => setShowQR(false)} style={{ marginTop: '8px' }}>
              Cerrar
            </button>
          </div>
        </div>
      )}

      <header className="admin-topbar">
        <div style={{ display: 'flex', alignItems: 'center', gap: '16px' }}>
          <Link to="/admin" className="admin-back-btn">←</Link>
          <div>
            <h1>{eventName || 'Evento'}</h1>
            {eventCode && (
              <p style={{ color: 'var(--muted)', fontFamily: 'Space Mono, monospace', fontSize: '0.68rem', letterSpacing: '0.15em', marginTop: '2px' }}>
                {eventCode}
              </p>
            )}
          </div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: '12px', flexWrap: 'wrap' }}>
          {statusMsg && <span className="status-msg">{statusMsg}</span>}
          {eventCode && (
            <button className="btn-ghost" onClick={() => setShowQR(true)}
              style={{ width: 'auto', padding: '8px 14px', fontSize: '0.72rem' }}>
              QR
            </button>
          )}
          {eventCode && (
            <button className="btn-ghost" onClick={copyEventLink}
              style={{ width: 'auto', padding: '8px 14px', fontSize: '0.72rem' }}>
              {copied ? '✓ Copiado' : 'Copiar link'}
            </button>
          )}
          {participants.length > 0 && (
            <button className="btn-ghost" onClick={exportCSV}
              style={{ width: 'auto', padding: '8px 14px', fontSize: '0.72rem' }}>
              Exportar CSV
            </button>
          )}
          <button onClick={logout} className="btn-ghost"
            style={{ width: 'auto', padding: '6px 14px', fontSize: '0.68rem', color: 'var(--muted)', borderColor: 'var(--black2)' }}>
            Salir
          </button>
        </div>
      </header>

      <div className="admin-content">
        <div className="admin-tabs">
          <button className={tab === 'participants' ? 'tab active' : 'tab'} onClick={() => setTab('participants')}>
            Participantes ({completed}/{total})
          </button>
          <button className={tab === 'questions' ? 'tab active' : 'tab'} onClick={() => setTab('questions')}>
            Preguntas
          </button>
          <button className={tab === 'matches' ? 'tab active' : 'tab'} onClick={() => setTab('matches')}>
            Duplas ({matchPairs.length})
          </button>
          <button className={tab === 'funnel' ? 'tab active' : 'tab'} onClick={() => setTab('funnel')}>
            Embudo
          </button>
          <button className={tab === 'map' ? 'tab active' : 'tab'} onClick={() => setTab('map')}>
            Mapa
          </button>
          <button className={tab === 'feedback' ? 'tab active' : 'tab'} onClick={() => setTab('feedback')}>
            Feedback
          </button>
        </div>

        {loading && <p className="admin-loading">Cargando...</p>}

        {/* ── PARTICIPANTS TAB ── */}
        {tab === 'participants' && (
          <div className="admin-section">

            {/* Admin participation box */}
            <div className="admin-join-box">
              <h3 className="force-match-title">Participar como admin</h3>

              {hasDuplicateAdmins && (
                <div className="odd-warning" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '14px' }}>
                  <span>⚠️ Hay {adminParticipants.length} registros de admin duplicados.</span>
                  <button className="btn-secondary" onClick={cleanupAdmins}
                    style={{ width: 'auto', padding: '8px 16px', fontSize: '0.74rem' }}>
                    Limpiar duplicados
                  </button>
                </div>
              )}

              {!adminParticipant ? (
                <>
                  <p className="muted" style={{ marginBottom: '14px', fontSize: '0.78rem' }}>
                    Únete con solo tu nombre. Eliges tu propia dupla y el algoritmo arma el resto.
                  </p>
                  <div className="force-match-row">
                    <input
                      type="text"
                      value={adminName}
                      onChange={e => setAdminName(e.target.value)}
                      placeholder="Tu nombre"
                      className="force-match-select"
                      style={{ backgroundImage: 'none' }}
                    />
                    <button className="btn-primary" onClick={joinAsAdmin}
                      disabled={!adminName.trim() || joiningAdmin}
                      style={{ width: 'auto', padding: '10px 20px', fontSize: '0.78rem', flexShrink: 0 }}>
                      {joiningAdmin ? '...' : 'Unirme'}
                    </button>
                  </div>
                </>
              ) : (
                <>
                  <p style={{ marginBottom: '14px', fontSize: '0.85rem' }}>
                    Participas como <strong>{adminParticipant.first_name}</strong>
                  </p>
                  <div className="force-match-row">
                    <label className="force-match-name" style={{ minWidth: 'auto' }}>Mi dupla:</label>
                    <select
                      value={adminPartnerId}
                      onChange={e => setAdminPartner(e.target.value)}
                      className="force-match-select"
                    >
                      <option value="">Sin elegir (que decida el algoritmo)</option>
                      {completedParticipants
                        .filter(p => p.id !== adminId)
                        .map(p => <option key={p.id} value={p.id}>{p.first_name}</option>)}
                    </select>
                  </div>
                  <div style={{ display: 'flex', gap: '10px', marginTop: '12px', flexWrap: 'wrap' }}>
                    <button className="btn-ghost" onClick={adminAnswerQuestionnaire}
                      style={{ width: 'auto', padding: '8px 16px', fontSize: '0.72rem' }}>
                      Responder cuestionario (opcional)
                    </button>
                    <button className="btn-ghost" onClick={leaveAsAdmin}
                      style={{ width: 'auto', padding: '8px 16px', fontSize: '0.72rem', color: 'var(--danger)', borderColor: 'var(--danger)' }}>
                      Salir de participar
                    </button>
                  </div>
                </>
              )}
            </div>

            <table className="participants-table">
              <thead>
                <tr><th>Nombre</th><th>Email</th><th>Teléfono</th><th>Cumpleaños</th><th>Estado</th></tr>
              </thead>
              <tbody>
                {participants.map(p => (
                  <tr key={p.id}>
                    <td>{p.first_name}{p.id === adminId ? ' (admin)' : ''}</td>
                    <td>{p.id === adminId ? '—' : p.email}</td>
                    <td>{p.phone ?? '—'}</td>
                    <td>{p.birthday ?? '—'}</td>
                    <td>
                      {p.completed_at
                        ? <span className="badge-done">✓ Completó</span>
                        : <span className="badge-pending">Pendiente</span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>

            {errorMsg && <p className="error">{errorMsg}</p>}

            <div className="admin-actions">
              <button className="btn-secondary" onClick={handleRunMatching}
                disabled={matchingLoading || completed < 2}>
                {matchingLoading ? 'Calculando...' : `🧮 Calcular afinidad (${completed} listos)`}
              </button>
              <button className="btn-primary" onClick={triggerCountdown}
                disabled={!hasMatches || countdownLoading}
                title={!hasMatches ? 'Primero calcula la afinidad' : ''}>
                {countdownLoading ? '⏳ Countdown activo...' : '🚀 Iniciar countdown (15s)'}
              </button>
            </div>
          </div>
        )}

        {/* ── QUESTIONS TAB (editor banco ↔ evento) ── */}
        {tab === 'questions' && <QuestionEditor eventId={eventId!} />}

        {/* ── MATCHES TAB ── */}
        {tab === 'matches' && (
          <div className="admin-section">
            {matchPairs.length === 0 ? (
              <p className="muted">Aún no hay duplas. Ve a Participantes → Calcular afinidad.</p>
            ) : (
              <table className="participants-table">
                <thead>
                  <tr><th>#</th><th>Persona A</th><th>Persona B</th><th>Afinidad</th></tr>
                </thead>
                <tbody>
                  {[...matchPairs].sort((a, b) => b.score - a.score).map((m, i) => {
                    const apId = eventState?.admin_participant_id
                    const aptId = eventState?.admin_partner_id
                    const isForced = !!apId && !!aptId && (
                      (m.participant_a === apId && m.participant_b === aptId) ||
                      (m.participant_b === apId && m.participant_a === aptId)
                    )
                    return (
                      <tr key={m.id}>
                        <td>{i + 1}</td>
                        <td>{m.participant_a_data?.first_name ?? '—'}</td>
                        <td>{m.participant_b_data?.first_name ?? '—'}</td>
                        <td>
                          <span className="badge-done">{Math.round(m.score * 100)}%</span>
                          {isForced && <span className="muted" style={{ marginLeft: '8px', fontSize: '0.7rem' }}>(admin)</span>}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            )}
          </div>
        )}

        {/* ── FUNNEL TAB (rondas embudo) ── */}
        {tab === 'funnel' && (() => {
          const rounds = Array.from({ length: FUNNEL_ROUNDS }, (_, i) => i + 1).map(r => {
            const rows = funnel.filter(f => f.round === r)
            const idxs = [...new Set(rows.map(f => f.group_idx))].sort((a, b) => a - b)
            return { round: r, groups: idxs.map(gi => ({
              gi, score: rows.find(f => f.group_idx === gi)?.score ?? 0,
              names: rows.filter(f => f.group_idx === gi).map(f => f.name).sort(),
            })) }
          })
          const hasFunnel = funnel.length > 0
          // Con pocos invitados la ronda 3 sale igual a la 2 → se salta
          const skip3 = hasFunnel && rounds[2].groups.length === rounds[1].groups.length
          const current = eventState?.phase === 'funnel' ? (eventState.funnel_round ?? 0) : 0
          return (
            <div className="admin-section">
              <p className="muted" style={{ marginBottom: '14px', fontSize: '0.8rem' }}>
                La noche por etapas: 2 grupos → 4 grupos → grupos de 3-4 → duplas. Cada ronda parte los grupos
                de la anterior según afinidad. Funciona mejor con 12+ personas. Es el mismo cálculo que
                "Calcular afinidad" en Participantes — las rondas son opcionales.
              </p>

              {errorMsg && <p className="error">{errorMsg}</p>}
              {statusMsg && <p className="status-msg">{statusMsg}</p>}

              <div className="admin-actions" style={{ flexWrap: 'wrap' }}>
                <button className="btn-secondary" onClick={handleRunFunnel} disabled={funnelLoading || completed < 4}>
                  {funnelLoading ? 'Armando...' : '🧮 ' + (hasFunnel ? 'Rearmar' : 'Armar') + ' embudo (' + completed + ' listos)'}
                </button>
                {[1, 2, 3].filter(r => !(r === 3 && skip3)).map(r => (
                  <button key={r} className={current === r ? 'btn-primary' : 'btn-ghost'} onClick={() => revealRound(r)}
                    disabled={!hasFunnel} style={{ width: 'auto' }}>
                    {current === r ? '● ' : ''}Revelar {roundLabel(r)}
                  </button>
                ))}
                <button className="btn-primary" onClick={triggerCountdown} disabled={!hasFunnel || countdownLoading}>
                  {countdownLoading ? '⏳ Countdown activo...' : '🚀 Revelar duplas (15s)'}
                </button>
                <button className="btn-ghost" onClick={resetToWaiting} style={{ width: 'auto' }}>
                  Volver a espera
                </button>
              </div>
              {skip3 && <p className="muted" style={{ fontSize: '0.75rem' }}>Ronda 3 saltada: con este número de personas sale igual a la ronda 2.</p>}

              {hasFunnel && rounds.filter(r => !(r.round === 3 && skip3)).map(r => (
                <div key={r.round} className="funnel-round">
                  <h3>{roundLabel(r.round)}</h3>
                  <div className="funnel-groups">
                    {r.groups.map(g => (
                      <div key={g.gi} className="funnel-group" style={{ borderLeftColor: groupColor(g.gi) }}>
                        <strong>{groupName(r.round, g.gi)} · {Math.round(g.score * 100)}%</strong>
                        {g.names.join(', ')}
                      </div>
                    ))}
                  </div>
                </div>
              ))}
            </div>
          )
        })()}

        {/* ── MAP TAB (afinidad) ── */}
        {tab === 'map' && (
          <AffinityGraph eventId={eventId!} participants={participants} matchPairs={matchPairs} />
        )}

        {/* ── FEEDBACK TAB ── */}
        {tab === 'feedback' && <FeedbackAdmin eventId={eventId!} />}
      </div>
    </div>
  )
}
