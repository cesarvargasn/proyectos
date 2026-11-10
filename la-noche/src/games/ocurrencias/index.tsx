import { useState } from 'react'
import { motion } from 'framer-motion'
import type { GameCtx, GameDefinition, GameState } from '../../engine/types'
import { Podium } from '../../engine/Podium'
import { Button } from '../../ui/Button'
import { Card } from '../../ui/Card'
import { Input } from '../../ui/Input'
import { AvatarBlock } from '../../ui/Avatar'

/**
 * Ocurrencias (010): estilo Quiplash. Cada jugador escribe respuestas a
 * 2 prompts; cada prompt lo escriben exactamente 2. Duelos: todos menos
 * los autores votan la mejor respuesta. +100/voto, APLASTADA +100 si te
 * llevas todos. El celular aquí SÍ aporta: escritura secreta simultánea
 * y voto anónimo.
 */
interface OcState extends GameState {
  timer_s?: number
  players?: string[]
  prompts?: { text: string }[]
  answers?: Record<string, Record<string, string>>
  duel_idx?: number
  votes?: Record<string, string>
  scores?: Record<string, number>
}

const PENSANDO = '[se quedó pensando]'

function authorsOf(st: OcState, idx: number): [string, string] {
  const ps = st.players ?? []
  return [ps[idx], ps[(idx + 1) % ps.length]]
}

function PromptWriter({ ctx, idx }: { ctx: GameCtx<OcState>; idx: number }) {
  const { state: st, me, act } = ctx
  const [text, setText] = useState('')
  const sent = st.answers?.[String(idx)]?.[me.id]
  return (
    <Card accent="var(--amber)" style={{ display: 'grid', gap: 10 }}>
      <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.05rem', lineHeight: 1.3 }}>
        {st.prompts?.[idx]?.text}
      </p>
      {sent ? (
        <p style={{ color: 'var(--muted)', fontWeight: 700 }}>Tu ocurrencia: “{sent}” ✓</p>
      ) : (
        <>
          <Input placeholder="Tu mejor ocurrencia…" maxLength={120} value={text}
            onChange={(e) => setText(e.target.value)} />
          <Button onClick={() => text.trim() && void act('answer', { prompt_idx: idx, text: text.trim() })}
            disabled={!text.trim()} style={!text.trim() ? { opacity: 0.4 } : undefined}>
            Enviar ✓
          </Button>
        </>
      )}
    </Card>
  )
}

function OcurrenciasView({ ctx }: { ctx: GameCtx<OcState> }) {
  const { state: st, players, me, act } = ctx
  const n = st.players?.length ?? 0

  if (st.phase === 'escribir') {
    const myIdx = st.players?.indexOf(me.id) ?? -1
    if (myIdx === -1) {
      return <p style={{ color: 'var(--muted)', fontWeight: 700 }}>Llegaste tarde — espera el siguiente juego 👀</p>
    }
    const mine = [myIdx, (myIdx - 1 + n) % n]
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>
          Te tocaron 2 — nadie ve lo que escribes 🤫
        </p>
        {mine.map((i) => <PromptWriter key={i} ctx={ctx} idx={i} />)}
      </div>
    )
  }

  if (st.phase === 'duelo' || st.phase === 'resultado') {
    const d = st.duel_idx ?? 0
    const [a1, a2] = authorsOf(st, d)
    const votes = st.votes ?? {}
    const reveal = st.phase === 'resultado'
    const myVote = votes[me.id] ?? null
    const soyAutor = me.id === a1 || me.id === a2
    const counts: Record<string, number> = {}
    Object.values(votes).forEach((v) => { counts[v] = (counts[v] ?? 0) + 1 })

    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase' }}>
          Duelo {d + 1} de {st.prompts?.length ?? 0}
        </p>
        <Card accent="var(--coral)">
          <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.15rem', lineHeight: 1.3 }}>
            {st.prompts?.[d]?.text}
          </p>
        </Card>

        {[a1, a2].map((aid, k) => {
          const ans = st.answers?.[String(d)]?.[aid] ?? PENSANDO
          const author = players.find((p) => p.id === aid)
          const v = counts[aid] ?? 0
          const other = counts[k === 0 ? a2 : a1] ?? 0
          const aplastada = reveal && v > 0 && other === 0
          return (
            <motion.div key={aid} whileTap={!reveal && !soyAutor ? { scale: 0.97 } : undefined}
              onClick={() => { if (!reveal && !soyAutor) void act('vote', { author: aid }) }}
              initial={reveal ? { scale: 0.92 } : false} animate={{ scale: 1 }}
              style={{ cursor: !reveal && !soyAutor ? 'pointer' : 'default' }}>
              <Card accent={myVote === aid && !reveal ? 'var(--amber)' : undefined}
                style={{ display: 'grid', gap: 8, ...(myVote === aid && !reveal ? { boxShadow: 'var(--shadow)' } : {}) }}>
                <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.2rem', lineHeight: 1.3,
                  color: ans === PENSANDO ? 'var(--muted)' : 'var(--ink)' }}>
                  {ans}
                </p>
                {reveal && (
                  <motion.div initial={{ opacity: 0, x: -16 }} animate={{ opacity: 1, x: 0 }}
                    transition={{ delay: 0.5 + k * 0.7, type: 'spring', stiffness: 300, damping: 18 }}
                    style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                    {author && <AvatarBlock avatar={author.avatar} size={24} />}
                    <span style={{ fontWeight: 700 }}>{author?.name ?? '?'}</span>
                    <span style={{ fontFamily: 'var(--font-display)', color: 'var(--amber)' }}>
                      +{100 * v + (aplastada ? 100 : 0)}
                    </span>
                    <span style={{ color: 'var(--muted)', fontWeight: 700 }}>({v} {v === 1 ? 'voto' : 'votos'})</span>
                    {aplastada && (
                      <motion.span initial={{ scale: 0 }} animate={{ scale: 1 }}
                        transition={{ delay: 1 + k * 0.7, type: 'spring', stiffness: 400, damping: 12 }}
                        style={{ fontFamily: 'var(--font-display)', fontSize: '0.8rem', color: '#000',
                          background: 'var(--coral)', border: '2px solid #000', padding: '2px 8px' }}>
                        APLASTADA 💥
                      </motion.span>
                    )}
                  </motion.div>
                )}
              </Card>
            </motion.div>
          )
        })}

        {!reveal && (
          <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>
            {soyAutor ? 'Este duelo es tuyo — los demás votan 👀'
              : myVote ? 'Voto guardado (puedes cambiarlo)' : 'Vota la mejor…'}
          </p>
        )}
      </div>
    )
  }

  if (st.phase === 'podio') {
    return <Podium players={players} scores={st.scores ?? {}} />
  }

  return null
}

function OcurrenciasHost({ ctx }: { ctx: GameCtx<OcState> }) {
  const { state: st, advance } = ctx
  if (st.phase === 'resultado') {
    const last = (st.duel_idx ?? 0) + 1 >= (st.prompts?.length ?? 0)
    return <Button big onClick={() => void advance(true)}>{last ? 'Ver podio 🏆' : 'Siguiente duelo →'}</Button>
  }
  if (st.phase === 'podio') {
    return <Button big onClick={() => void advance(true)}>Terminar juego 🏁</Button>
  }
  return null
}

const PHASE_TITLE: Record<string, string> = {
  escribir: 'Suelta tu ocurrencia',
  duelo: '¿Cuál gana?',
  resultado: 'El veredicto',
  podio: 'El podio',
}

export const ocurrenciasGame: GameDefinition<OcState> = {
  id: 'ocurrencias',
  nameEs: 'Batalla de Frases',
  phaseTitle: (st) => PHASE_TITLE[st.phase] ?? st.phase,
  PlayerView: OcurrenciasView,
  HostView: OcurrenciasHost,
}
