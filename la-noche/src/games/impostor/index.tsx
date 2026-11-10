import { useState } from 'react'
import { motion } from 'framer-motion'
import type { GameCtx, GameDefinition, GameState } from '../../engine/types'
import { Podium } from '../../engine/Podium'
import { Button } from '../../ui/Button'
import { Card } from '../../ui/Card'
import { Input } from '../../ui/Input'
import { AvatarBlock } from '../../ui/Avatar'

/**
 * Impostor (012): estilo Chameleon. Categoría pública + palabra secreta
 * que todos reciben MENOS el impostor. Pistas habladas EN PERSONA (el
 * celular solo muestra el orden — principio de diseño: no duplicar lo que
 * pasa en vivo), voto simultáneo, y si lo cazan tiene UNA chance de
 * adivinar la palabra (host confirma). La palabra y el rol viven en
 * player_secrets: abrir devtools no ayuda.
 */
interface ImState extends GameState {
  timer_s?: number
  deck?: { id: string; cat: string }[]
  round_idx?: number
  turn_order?: string[]
  ready?: Record<string, boolean>
  votes?: Record<string, string>
  guess?: string | null
  word?: string | null
  impostor?: string | null
  outcome?: 'escapo' | 'adivino' | 'fallo' | null
  accused?: string | null
  hunts?: number
  offline?: boolean
  n_impostors?: number
  scores?: Record<string, number>
}

const norm = (s: string) =>
  s.toLowerCase().trim().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]/g, '')

function CatBanner({ st }: { st: ImState }) {
  const r = st.round_idx ?? 0
  return (
    <div style={{ display: 'grid', gap: 10 }}>
      <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase' }}>
        Ronda {r + 1} de {st.deck?.length ?? 0}
      </p>
      <motion.div key={r} initial={{ scale: 0.92, rotate: -1 }} animate={{ scale: 1, rotate: 0 }}
        transition={{ type: 'spring', stiffness: 300, damping: 18 }}>
        <Card accent="#5CB8FF">
          <p style={{ fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase', color: 'var(--muted)' }}>Categoría</p>
          <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.4rem' }}>{st.deck?.[r]?.cat}</p>
        </Card>
      </motion.div>
    </div>
  )
}

function ImpostorView({ ctx }: { ctx: GameCtx<ImState> }) {
  const { state: st, players, me, act, secret } = ctx
  const [text, setText] = useState('')
  const nameOf = (pid?: string | null) => players.find((p) => p.id === pid)?.name ?? '?'

  if (st.phase === 'secreto') {
    // ANTI-TELL: misma pantalla y mismo botón para todos
    const esImpostor = secret?.role === 'impostor'
    const listo = !!st.ready?.[me.id]
    const done = Object.keys(st.ready ?? {}).length
    const admin = secret?.admin as { impostor?: string; impostores?: string[]; word?: string } | undefined
    const nImp = st.n_impostors ?? 1
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <CatBanner st={st} />
        <Card accent={esImpostor ? 'var(--coral)' : 'var(--amber)'} style={{ minHeight: 110, display: 'grid', alignContent: 'center' }}>
          {secret == null ? (
            <p style={{ fontWeight: 700, color: 'var(--muted)', textAlign: 'center' }}>Repartiendo…</p>
          ) : esImpostor ? (
            <div style={{ display: 'grid', gap: 6, textAlign: 'center' }}>
              <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.4rem', color: 'var(--coral)' }}>ERES EL IMPOSTOR 🕵️</p>
              <p style={{ fontWeight: 700, color: 'var(--muted)' }}>
                No sabes la palabra. Finge que sí. Nadie puede ver tu pantalla.
                {nImp > 1 && ` Ojo: hay ${nImp} impostores y no sabes quiénes son los otros.`}
              </p>
            </div>
          ) : (
            <div style={{ display: 'grid', gap: 6, textAlign: 'center' }}>
              <p style={{ fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase', color: 'var(--muted)' }}>La palabra secreta es</p>
              <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.6rem', color: 'var(--amber)' }}>{String(secret.word ?? '')}</p>
              <p style={{ fontWeight: 700, color: 'var(--muted)', fontSize: '0.85rem' }}>
                {nImp > 1 ? `Hay ${nImp} impostores que NO la saben 🤫` : 'Hay un impostor que NO la sabe 🤫'}
              </p>
            </div>
          )}
        </Card>
        {admin && (
          <Card accent="#C792EA" style={{ display: 'grid', gap: 4 }}>
            <p style={{ fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase', color: 'var(--muted)' }}>👁 Solo tú (admin)</p>
            <p style={{ fontWeight: 700 }}>
              {(admin.impostores?.length ?? 1) > 1 ? 'Impostores' : 'Impostor'}:{' '}
              <span style={{ color: 'var(--coral)' }}>{admin.impostores?.join(', ') ?? admin.impostor}</span>
              {' '}· Palabra: <span style={{ color: 'var(--amber)' }}>{admin.word}</span>
            </p>
          </Card>
        )}
        {st.offline ? (
          <Card><p style={{ fontWeight: 700, textAlign: 'center', color: 'var(--muted)' }}>
            🪑 Modo en vivo: pistas, voto y adivinanza se hacen HABLANDO. El admin pasa de ronda.
          </p></Card>
        ) : (
          <>
            <Button big onClick={() => void act('ready')} disabled={listo}
              style={listo ? { opacity: 0.4 } : undefined}>
              {listo ? 'Listo ✓' : 'Ya la vi 👀'}
            </Button>
            <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>{done}/{players.length} listos</p>
          </>
        )}
      </div>
    )
  }

  if (st.phase === 'cazeria') {
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <CatBanner st={st} />
        <motion.div initial={{ scale: 0.8 }} animate={{ scale: 1 }}
          transition={{ type: 'spring', stiffness: 300, damping: 16 }}>
          <Card accent="var(--coral)" style={{ display: 'grid', gap: 6, textAlign: 'center' }}>
            <p style={{ fontSize: '2rem' }}>🕵️</p>
            <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.2rem' }}>
              {st.accused ? `${nameOf(st.accused)} era INOCENTE` : 'EMPATE — nadie cayó'}
            </p>
            <p style={{ fontWeight: 700 }}>El impostor sigue entre ustedes… (intento {st.hunts ?? 1})</p>
            <p style={{ fontWeight: 700, color: 'var(--muted)', fontSize: '0.85rem' }}>Misma palabra. Otra vuelta de pistas. Afinen el ojo.</p>
          </Card>
        </motion.div>
      </div>
    )
  }

  if (st.phase === 'pistas') {
    const order = (st.turn_order ?? [])
      .map((pid) => players.find((p) => p.id === pid))
      .filter((p): p is typeof players[number] => !!p)
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <CatBanner st={st} />
        <Card>
          <p style={{ fontWeight: 700 }}>🗣 Cada quien dice UNA pista de la palabra, en voz alta y en este orden:</p>
        </Card>
        <div style={{ display: 'grid', gap: 6 }}>
          {order.map((p, i) => (
            <motion.div key={p.id} initial={{ opacity: 0, x: -14 }} animate={{ opacity: 1, x: 0 }}
              transition={{ delay: 0.12 * i, type: 'spring', stiffness: 300, damping: 20 }}
              style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 10px',
                background: 'var(--surface)', border: 'var(--border-thin)' }}>
              <span style={{ fontFamily: 'var(--font-display)', minWidth: 24 }}>{i + 1}.</span>
              <AvatarBlock avatar={p.avatar} size={26} />
              <span style={{ fontWeight: 700 }}>{p.name}</span>
            </motion.div>
          ))}
        </div>
        <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center', fontSize: '0.85rem' }}>
          Pista muy obvia = el impostor la caza. Muy rara = pareces TÚ el impostor.
        </p>
      </div>
    )
  }

  if (st.phase === 'voto') {
    const votes = st.votes ?? {}
    const myVote = votes[me.id]
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <CatBanner st={st} />
        <p style={{ fontWeight: 700, textAlign: 'center' }}>¿Quién es el impostor?</p>
        <div style={{ display: 'grid', gap: 8, gridTemplateColumns: 'repeat(auto-fill, minmax(140px, 1fr))' }}>
          {players.filter((p) => p.id !== me.id).map((p) => (
            <motion.button key={p.id} whileTap={{ scale: 0.95 }}
              onClick={() => void act('vote', { target: p.id })}
              style={{
                display: 'flex', alignItems: 'center', gap: 8, padding: 10, cursor: 'pointer',
                background: myVote === p.id ? 'var(--amber)' : 'var(--surface)',
                color: myVote === p.id ? '#000' : 'var(--ink)',
                border: 'var(--border)', boxShadow: myVote === p.id ? 'var(--shadow)' : 'none',
              }}>
              <AvatarBlock avatar={p.avatar} size={26} />
              <span style={{ fontWeight: 700, overflow: 'hidden', textOverflow: 'ellipsis' }}>{p.name}</span>
            </motion.button>
          ))}
        </div>
        <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>
          {myVote ? 'Voto puesto (puedes cambiarlo)' : 'Vota ya'} · {Object.keys(votes).length}/{players.length}
        </p>
      </div>
    )
  }

  if (st.phase === 'adivinar') {
    const soyImpostor = st.accused === me.id
    if (!soyImpostor) {
      return (
        <div style={{ display: 'grid', gap: 14 }}>
          <CatBanner st={st} />
          <Card accent="var(--coral)">
            <p style={{ fontWeight: 700, textAlign: 'center' }}>
              🎯 ¡Cazaron a {nameOf(st.accused)}! Tiene UNA chance de adivinar la palabra…
            </p>
          </Card>
        </div>
      )
    }
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <CatBanner st={st} />
        <Card accent="var(--coral)">
          <p style={{ fontWeight: 700 }}>Te cazaron 🕵️ Última jugada: ¿cuál era la palabra?</p>
        </Card>
        <Input placeholder="La palabra era…" maxLength={40} value={text}
          onChange={(e) => setText(e.target.value)} />
        <Button big onClick={() => { if (text.trim()) void act('guess', { text: text.trim() }) }}
          disabled={!text.trim()} style={!text.trim() ? { opacity: 0.4 } : undefined}>
          Esa es 🎲
        </Button>
      </div>
    )
  }

  if (st.phase === 'confirmar') {
    const parecidas = st.word != null && st.guess != null && norm(st.word) === norm(st.guess)
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <CatBanner st={st} />
        <Card style={{ display: 'grid', gap: 8 }}>
          <p style={{ fontWeight: 700 }}>La palabra era: <span style={{ color: 'var(--amber)', fontFamily: 'var(--font-display)' }}>{st.word}</span></p>
          <p style={{ fontWeight: 700 }}>{nameOf(st.accused)} dijo: <span style={{ color: 'var(--coral)', fontFamily: 'var(--font-display)' }}>{st.guess}</span></p>
          <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.85rem' }}>
            {parecidas ? '🤖 Se ven iguales — el anfitrión decide.' : '🤖 No se ven iguales — el anfitrión decide.'}
          </p>
        </Card>
      </div>
    )
  }

  if (st.phase === 'reveal') {
    const imp = players.find((p) => p.id === st.impostor)
    const msg = st.outcome === 'escapo'
      ? `¡Se les escapó! ${st.accused ? `Señalaron a ${nameOf(st.accused)} y no era.` : 'Nadie fue señalado.'} Impostor +3`
      : st.outcome === 'adivino'
        ? '¡Lo cazaron… pero ADIVINÓ la palabra! Impostor +1 · resto +1'
        : '¡Cazado y sin la palabra! Resto +2'
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <CatBanner st={st} />
        <motion.div initial={{ scale: 0.7 }} animate={{ scale: 1 }}
          transition={{ type: 'spring', stiffness: 300, damping: 14 }}>
          <Card accent={st.outcome === 'escapo' ? 'var(--coral)' : '#7ED957'} style={{ display: 'grid', gap: 8 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              {imp && <AvatarBlock avatar={imp.avatar} size={32} />}
              <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.2rem' }}>
                El impostor era {imp?.name ?? '?'} 🕵️
              </p>
            </div>
            <p style={{ fontWeight: 700 }}>{msg}</p>
            <p style={{ fontWeight: 700, color: 'var(--muted)' }}>
              La palabra era: <span style={{ color: 'var(--amber)' }}>{st.word}</span>
            </p>
          </Card>
        </motion.div>
      </div>
    )
  }

  if (st.phase === 'podio') {
    return <Podium players={players} scores={st.scores ?? {}} />
  }

  return null
}

function ImpostorHost({ ctx }: { ctx: GameCtx<ImState> }) {
  const { state: st, advance, act } = ctx
  if (st.offline && st.phase === 'secreto') {
    const last = (st.round_idx ?? 0) + 1 >= (st.deck?.length ?? 0)
    return <Button big onClick={() => void advance(true)}>{last ? 'Terminar juego 🏁' : 'Siguiente ronda →'}</Button>
  }
  if (st.phase === 'cazeria') {
    return <Button big onClick={() => void advance(true)}>Otra vuelta de pistas 🔍</Button>
  }
  if (st.phase === 'pistas') {
    return <Button big onClick={() => void advance(true)}>Todos dieron pista → votar 🗳</Button>
  }
  if (st.phase === 'confirmar') {
    return (
      <div style={{ display: 'flex', gap: 8 }}>
        <Button big onClick={() => void act('confirm', { ok: true })}>Le atinó ✓</Button>
        <Button big variant="danger" onClick={() => void act('confirm', { ok: false })}>No era ✗</Button>
      </div>
    )
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
  secreto: 'Mira tu carta',
  pistas: 'Pistas en voz alta',
  voto: '¿Quién finge?',
  cazeria: 'Se les escapó',
  adivinar: 'Última jugada',
  confirmar: '¿Le atinó?',
  reveal: 'La verdad',
  podio: 'El podio',
}

export const impostorGame: GameDefinition<ImState> = {
  id: 'impostor',
  nameEs: 'Impostor',
  phaseTitle: (st) => PHASE_TITLE[st.phase] ?? st.phase,
  needsSecret: (st) => ['secreto', 'pistas', 'voto', 'cazeria', 'adivinar'].includes(st.phase),
  PlayerView: ImpostorView,
  HostView: ImpostorHost,
}
