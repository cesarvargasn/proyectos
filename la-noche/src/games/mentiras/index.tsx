import { useState } from 'react'
import { motion } from 'framer-motion'
import type { GameCtx, GameDefinition, GameState } from '../../engine/types'
import { Podium } from '../../engine/Podium'
import { Button } from '../../ui/Button'
import { Card } from '../../ui/Card'
import { Input } from '../../ui/Input'
import { AvatarBlock } from '../../ui/Avatar'

/**
 * Mentiras (010): estilo Fibbage. Todos inventan una respuesta falsa a
 * una pregunta real; luego cada quien elige la que cree verdadera entre
 * mentiras + verdad. Verdad +100; cada víctima de tu mentira +50.
 * Mentiras idénticas se fusionan; escribir la verdad se rechaza.
 */
interface MtOption { text: string; authors: string[]; is_truth?: boolean }
interface MtState extends GameState {
  timer_s?: number
  deck?: { text: string; answer: string }[]
  round_idx?: number
  lies?: Record<string, string>
  options?: MtOption[] | null
  picks?: Record<string, string>
  scores?: Record<string, number>
}

function QuestionBanner({ st }: { st: MtState }) {
  const r = st.round_idx ?? 0
  return (
    <div style={{ display: 'grid', gap: 10 }}>
      <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase' }}>
        Pregunta {r + 1} de {st.deck?.length ?? 0}
      </p>
      <motion.div key={r} initial={{ scale: 0.92, rotate: -1 }} animate={{ scale: 1, rotate: 0 }}
        transition={{ type: 'spring', stiffness: 300, damping: 18 }}>
        <Card accent="var(--coral)">
          <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.2rem', lineHeight: 1.3 }}>
            {st.deck?.[r]?.text}
          </p>
        </Card>
      </motion.div>
    </div>
  )
}

function MentirasView({ ctx }: { ctx: GameCtx<MtState> }) {
  const { state: st, players, me, act } = ctx
  const [text, setText] = useState('')
  const [err, setErr] = useState('')

  if (st.phase === 'mentir') {
    const myLie = st.lies?.[me.id]
    const done = Object.keys(st.lies ?? {}).length
    const submit = async () => {
      if (!text.trim()) return
      setErr('')
      try {
        await act('lie', { text: text.trim() })
        setText('')
      } catch (e) {
        setErr(String((e as Error).message ?? e).includes('ES_LA_VERDAD')
          ? '😏 ¡Esa ES la verdad! Inventa una mentira.'
          : 'No se pudo enviar, intenta de nuevo.')
      }
    }
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <QuestionBanner st={st} />
        {myLie && (
          <Card><p style={{ fontWeight: 700 }}>Tu mentira: “{myLie}” ✓ <span style={{ color: 'var(--muted)' }}>(puedes cambiarla)</span></p></Card>
        )}
        <Input placeholder="Inventa una respuesta creíble…" maxLength={80} value={text}
          onChange={(e) => { setText(e.target.value); setErr('') }} />
        {err && <p style={{ color: 'var(--coral)', fontWeight: 700 }}>{err}</p>}
        <Button big onClick={() => void submit()} disabled={!text.trim()}
          style={!text.trim() ? { opacity: 0.4 } : undefined}>
          {myLie ? 'Cambiar mentira' : 'Sembrar mentira 🤥'}
        </Button>
        <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>{done}/{players.length} mintieron</p>
      </div>
    )
  }

  if (st.phase === 'elegir') {
    const picks = st.picks ?? {}
    const myPick = picks[me.id] != null ? Number(picks[me.id]) : null
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <QuestionBanner st={st} />
        <div style={{ display: 'grid', gap: 10 }}>
          {(st.options ?? []).map((o, i) => {
            const mine = o.authors.includes(me.id)
            return (
              <motion.button key={i} whileTap={!mine ? { scale: 0.96 } : undefined}
                onClick={() => { if (!mine) void act('pick', { idx: i }) }}
                style={{
                  padding: 12, textAlign: 'left', fontWeight: 700,
                  background: myPick === i ? 'var(--amber)' : 'var(--surface)',
                  color: myPick === i ? '#000' : mine ? 'var(--muted)' : 'var(--ink)',
                  border: 'var(--border)', boxShadow: myPick === i ? 'var(--shadow)' : 'none',
                }}>
                {o.text}{mine && '  · tu mentira 🤫'}
              </motion.button>
            )
          })}
        </div>
        <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>
          {myPick != null ? '¿Verdad o trampa? (puedes cambiar)' : '¿Cuál es la verdad?'}
          {' · '}{Object.keys(picks).length}/{players.length}
        </p>
      </div>
    )
  }

  if (st.phase === 'reveal') {
    const picks = st.picks ?? {}
    const opts = (st.options ?? []).map((o, i) => ({
      ...o, i,
      victims: Object.entries(picks).filter(([, v]) => Number(v) === i).map(([pid]) => pid),
    }))
    // drumroll de eliminación: mentiras con menos víctimas primero, la verdad de última
    const lies = opts.filter((o) => !o.is_truth).sort((a, b) => a.victims.length - b.victims.length)
    const truth = opts.find((o) => o.is_truth)
    const ordered = [...lies, ...(truth ? [truth] : [])]
    return (
      <div style={{ display: 'grid', gap: 12 }}>
        <QuestionBanner st={st} />
        {ordered.map((o, k) => {
          const delay = 0.6 * k
          const authors = players.filter((p) => o.authors.includes(p.id))
          const victims = players.filter((p) => o.victims.includes(p.id))
          return (
            <motion.div key={o.i} initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }}
              transition={{ delay, type: 'spring', stiffness: 300, damping: 20 }}>
              <Card accent={o.is_truth ? 'var(--amber)' : undefined} style={{ display: 'grid', gap: 6 }}>
                <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.1rem' }}>{o.text}</p>
                {o.is_truth ? (
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                    <span style={{ fontFamily: 'var(--font-display)', fontSize: '0.8rem', color: '#000',
                      background: 'var(--amber)', border: '2px solid #000', padding: '2px 8px' }}>
                      LA VERDAD ✅
                    </span>
                    {victims.map((p) => <AvatarBlock key={p.id} avatar={p.avatar} size={22} />)}
                    <span style={{ color: 'var(--muted)', fontWeight: 700 }}>
                      {victims.length ? `+100 c/u` : 'nadie la vio 🙈'}
                    </span>
                  </div>
                ) : (
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                    <span style={{ color: 'var(--coral)', fontWeight: 700 }}>
                      MENTIRA de {authors.map((a) => a.name).join(' + ') || '?'}
                    </span>
                    {victims.length > 0 && (
                      <>
                        <span style={{ color: 'var(--muted)', fontWeight: 700 }}>cayeron:</span>
                        {victims.map((p) => <AvatarBlock key={p.id} avatar={p.avatar} size={22} />)}
                        <span style={{ fontFamily: 'var(--font-display)', color: 'var(--amber)' }}>
                          +{50 * victims.length}
                        </span>
                      </>
                    )}
                  </div>
                )}
              </Card>
            </motion.div>
          )
        })}
      </div>
    )
  }

  if (st.phase === 'podio') {
    return <Podium players={players} scores={st.scores ?? {}} />
  }

  return null
}

function MentirasHost({ ctx }: { ctx: GameCtx<MtState> }) {
  const { state: st, advance } = ctx
  if (st.phase === 'reveal') {
    const last = (st.round_idx ?? 0) + 1 >= (st.deck?.length ?? 0)
    return <Button big onClick={() => void advance(true)}>{last ? 'Ver podio 🏆' : 'Siguiente pregunta →'}</Button>
  }
  if (st.phase === 'podio') {
    return <Button big onClick={() => void advance(true)}>Terminar juego 🏁</Button>
  }
  return null
}

const PHASE_TITLE: Record<string, string> = {
  mentir: 'Inventa la mentira',
  elegir: '¿Cuál es la verdad?',
  reveal: 'Cayeron…',
  podio: 'El podio',
}

export const mentirasGame: GameDefinition<MtState> = {
  id: 'mentiras',
  nameEs: 'Mentiras',
  phaseTitle: (st) => PHASE_TITLE[st.phase] ?? st.phase,
  PlayerView: MentirasView,
  HostView: MentirasHost,
}
