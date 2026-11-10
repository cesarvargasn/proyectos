import { useState } from 'react'
import { motion } from 'framer-motion'
import type { GameCtx, GameDefinition, GameState } from '../../engine/types'
import { Podium } from '../../engine/Podium'
import { Button } from '../../ui/Button'
import { Card } from '../../ui/Card'
import { Input } from '../../ui/Input'
import { AvatarBlock } from '../../ui/Avatar'

/**
 * La Manada (011): estilo Herd Mentality. Todos responden el MISMO prompt
 * con texto libre; ganan +100 los que quedaron en el grupo más grande (la
 * manada). Como es texto libre, el HOST agrupa a mano las respuestas
 * equivalentes antes de revelar. Oveja Negra: el que queda solo carga la 🐑
 * y no puede ganar (se pasa de ronda en ronda).
 */
interface MnGroup { label: string; members: string[] }
interface MnState extends GameState {
  timer_s?: number
  deck?: { text: string }[]
  round_idx?: number
  answers?: Record<string, string>
  groups?: MnGroup[] | null
  oveja?: string | null
  scores?: Record<string, number>
}

function PromptBanner({ st }: { st: MnState }) {
  const r = st.round_idx ?? 0
  return (
    <div style={{ display: 'grid', gap: 10 }}>
      <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase' }}>
        Ronda {r + 1} de {st.deck?.length ?? 0}
      </p>
      <motion.div key={r} initial={{ scale: 0.92, rotate: -1 }} animate={{ scale: 1, rotate: 0 }}
        transition={{ type: 'spring', stiffness: 300, damping: 18 }}>
        <Card accent="#7ED957">
          <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.2rem', lineHeight: 1.3 }}>
            {st.deck?.[r]?.text}
          </p>
        </Card>
      </motion.div>
      <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.85rem' }}>
        Responde igual que la mayoría. Quien quede solo, carga la 🐑
      </p>
    </div>
  )
}

function ManadaView({ ctx }: { ctx: GameCtx<MnState> }) {
  const { state: st, players, me, isHost, act } = ctx
  const [text, setText] = useState('')
  const [sel, setSel] = useState<number | null>(null)

  const nameOf = (pid: string) => players.find((p) => p.id === pid)?.name ?? '?'
  const membersOf = (pids: string[]) =>
    pids.map((pid) => players.find((p) => p.id === pid)).filter((p): p is typeof players[number] => !!p)

  if (st.phase === 'responder') {
    const mine = st.answers?.[me.id]
    const done = Object.keys(st.answers ?? {}).length
    const submit = async () => {
      if (!text.trim()) return
      await act('answer', { text: text.trim() })
      setText('')
    }
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <PromptBanner st={st} />
        {mine && (
          <Card><p style={{ fontWeight: 700 }}>Tu respuesta: “{mine}” ✓ <span style={{ color: 'var(--muted)' }}>(puedes cambiarla)</span></p></Card>
        )}
        <Input placeholder="Escribe lo que crees que pondrá la mayoría…" maxLength={60} value={text}
          onChange={(e) => setText(e.target.value)} />
        <Button big onClick={() => void submit()} disabled={!text.trim()}
          style={!text.trim() ? { opacity: 0.4 } : undefined}>
          {mine ? 'Cambiar respuesta' : 'Responder 🐾'}
        </Button>
        <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>{done}/{players.length} respondieron</p>
      </div>
    )
  }

  if (st.phase === 'agrupar') {
    // solo el host agrupa; el resto espera
    if (!isHost) {
      return (
        <div style={{ display: 'grid', gap: 14 }}>
          <PromptBanner st={st} />
          <Card><p style={{ fontWeight: 700, textAlign: 'center' }}>🧑‍🔧 El anfitrión está juntando las respuestas parecidas…</p></Card>
        </div>
      )
    }
    const groups = st.groups ?? []
    const tap = (i: number) => {
      if (sel === null) { setSel(i); return }
      if (sel === i) { setSel(null); return }
      void act('merge', { a: sel, b: i })
      setSel(null)
    }
    return (
      <div style={{ display: 'grid', gap: 12 }}>
        <PromptBanner st={st} />
        <Card accent="var(--amber)">
          <p style={{ fontWeight: 700 }}>Junta las respuestas que significan lo mismo.</p>
          <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.85rem' }}>
            Toca una, luego otra, y se fusionan. Cuando estén bien, dale “Revelar”.
          </p>
        </Card>
        <div style={{ display: 'grid', gap: 8 }}>
          {groups.map((g, i) => (
            <motion.button key={i} layout whileTap={{ scale: 0.97 }} onClick={() => tap(i)}
              style={{
                textAlign: 'left', padding: '10px 12px', display: 'grid', gap: 6,
                background: sel === i ? 'var(--amber)' : 'var(--surface)',
                color: sel === i ? '#000' : 'var(--ink)',
                border: 'var(--border)', boxShadow: sel === i ? 'var(--shadow)' : 'none',
              }}>
              <span style={{ fontFamily: 'var(--font-display)', fontSize: '1.05rem' }}>
                {g.label} <span style={{ fontSize: '0.85rem' }}>· {g.members.length}</span>
              </span>
              <span style={{ display: 'grid', gap: 2 }}>
                {membersOf(g.members).map((p) => (
                  <span key={p.id} style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                    <AvatarBlock avatar={p.avatar} size={20} />
                    <span style={{ fontWeight: 700, fontSize: '0.8rem' }}>
                      {p.name}: “{st.answers?.[p.id] ?? '?'}”
                    </span>
                  </span>
                ))}
              </span>
            </motion.button>
          ))}
        </div>
        {sel !== null && (
          <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>
            Toca otra para fusionar con “{groups[sel]?.label}” · o tócala de nuevo pa' cancelar
          </p>
        )}
      </div>
    )
  }

  if (st.phase === 'reveal') {
    const groups = [...(st.groups ?? [])].sort((a, b) => b.members.length - a.members.length)
    const max = groups.reduce((m, g) => Math.max(m, g.members.length), 0)
    return (
      <div style={{ display: 'grid', gap: 12 }}>
        <PromptBanner st={st} />
        {groups.map((g, k) => {
          const isManada = max >= 2 && g.members.length === max
          const isSolo = g.members.length === 1
          const hasOveja = isSolo && g.members[0] === st.oveja
          return (
            <motion.div key={k} initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }}
              transition={{ delay: 0.5 * k, type: 'spring', stiffness: 300, damping: 20 }}>
              <Card accent={isManada ? '#7ED957' : hasOveja ? 'var(--coral)' : undefined}
                style={{ display: 'grid', gap: 6 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                  <span style={{ fontFamily: 'var(--font-display)', fontSize: '1.1rem', flex: 1 }}>{g.label}</span>
                  {isManada && (
                    <span style={{ fontFamily: 'var(--font-display)', fontSize: '0.8rem', color: '#000',
                      background: '#7ED957', border: '2px solid #000', padding: '2px 8px' }}>
                      LA MANADA +100
                    </span>
                  )}
                  {hasOveja && (
                    <span style={{ fontFamily: 'var(--font-display)', fontSize: '0.8rem', color: '#000',
                      background: 'var(--coral)', border: '2px solid #000', padding: '2px 8px' }}>
                      🐑 OVEJA NEGRA
                    </span>
                  )}
                </div>
                <div style={{ display: 'grid', gap: 3 }}>
                  {membersOf(g.members).map((p) => {
                    const original = st.answers?.[p.id]
                    const distinta = original != null
                      && original.trim().toLowerCase() !== g.label.trim().toLowerCase()
                    return (
                      <span key={p.id} style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                        <AvatarBlock avatar={p.avatar} size={22} />
                        <span style={{ fontWeight: 700, fontSize: '0.85rem' }}>
                          {p.name}
                          {distinta && (
                            <span style={{ color: 'var(--muted)' }}> dijo “{original}”</span>
                          )}
                        </span>
                      </span>
                    )
                  })}
                </div>
              </Card>
            </motion.div>
          )
        })}
        {max < 2 && (
          <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>
            Nadie coincidió — ronda sin manada 🤷
          </p>
        )}
      </div>
    )
  }

  if (st.phase === 'podio') {
    const oveja = st.oveja
    const ovejaName = oveja ? nameOf(oveja) : null
    return (
      <div style={{ display: 'grid', gap: 12 }}>
        {ovejaName && (
          <Card accent="var(--coral)">
            <p style={{ fontWeight: 700 }}>🐑 {ovejaName} carga la Oveja Negra: no puede ganar aunque tenga más puntos.</p>
          </Card>
        )}
        <Podium players={players} scores={st.scores ?? {}} />
      </div>
    )
  }

  return null
}

function ManadaHost({ ctx }: { ctx: GameCtx<MnState> }) {
  const { state: st, advance } = ctx
  if (st.phase === 'agrupar') {
    return <Button big onClick={() => void advance(true)}>Revelar la manada 👀</Button>
  }
  if (st.phase === 'reveal') {
    const last = (st.round_idx ?? 0) + 1 >= (st.deck?.length ?? 0)
    return <Button big onClick={() => void advance(true)}>{last ? 'Ver podio 🏆' : 'Siguiente ronda →'}</Button>
  }
  if (st.phase === 'podio') {
    return <Button big onClick={() => void advance(true)}>Terminar juego 🏁</Button>
  }
  return null
}

const PHASE_TITLE: Record<string, string> = {
  responder: 'Piensa como el grupo',
  agrupar: 'Agrupando…',
  reveal: '¿Quién pensó igual?',
  podio: 'El podio',
}

export const manadaGame: GameDefinition<MnState> = {
  id: 'la-manada',
  nameEs: 'La Manada',
  phaseTitle: (st) => PHASE_TITLE[st.phase] ?? st.phase,
  PlayerView: ManadaView,
  HostView: ManadaHost,
}
