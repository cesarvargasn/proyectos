import { useEffect, useState } from 'react'
import { motion } from 'framer-motion'
import type { GameCtx, GameDefinition, GameState } from '../../engine/types'
import { HowToPlay } from '../../engine/HowToPlay'
import { Button } from '../../ui/Button'
import { Card } from '../../ui/Card'
import { AvatarBlock } from '../../ui/Avatar'

const REGLAS_DC = [
  '🎩 Un equipo AZUL (con el Presidente) y uno ROJO (con la Bomba). Nadie sabe quién es quién.',
  '🚪 La app sortea dos cuartos AL AZAR, sin importar el equipo: en cada cuarto hay azules y rojos mezclados. Se separan FÍSICAMENTE. 3 rondas: 3:00, 2:00 y 1:00.',
  '🤝 Durante la ronda muestras tu carta EN PERSONA a quien quieras (solo el color, o el rol 5s).',
  '👑 Al final de cada ronda, el líder de cada cuarto manda rehenes al otro (cuántos depende de cuánta gente haya).',
  '💥 Final: si la Bomba queda EN EL MISMO cuarto que el Presidente, gana el ROJO. Si quedan separados, gana el AZUL.',
]

/**
 * Dos Cuartos y la Bomba (018): 6–20. Dos cuartos FÍSICOS, 3 rondas
 * sincronizadas (3:00/2:00/1:00). El celular es tu carta (compartir =
 * mostrarla en persona: solo color o rol completo, 5s), tu cuarto, y
 * la mesa del líder (rehenes + motín). Bomba con Presidente = gana ROJO.
 */
interface DcState extends GameState {
  round?: number
  rooms?: Record<string, 1 | 2>
  leaders?: Record<string, string | null>
  hostages?: Record<string, string[]>
  h_count?: number
  usurp?: Record<string, string>
  ready?: Record<string, boolean>
  winner?: 'azul' | 'rojo' | null
  bomba?: string | null
  presidente?: string | null
  offline?: boolean
}

const ROLE: Record<string, { name: string; emoji: string; color: string; team: string }> = {
  presidente: { name: 'PRESIDENTE', emoji: '🎩', color: '#5CB8FF', team: 'azul' },
  azul: { name: 'EQUIPO AZUL', emoji: '🛡', color: '#5CB8FF', team: 'azul' },
  bomba: { name: 'LA BOMBA', emoji: '💣', color: 'var(--coral)', team: 'rojo' },
  rojo: { name: 'EQUIPO ROJO', emoji: '🔥', color: 'var(--coral)', team: 'rojo' },
}

/** Overlay 5s para el card-share en persona. */
function ShareOverlay({ role, full, onDone }: { role: string; full: boolean; onDone: () => void }) {
  const r = ROLE[role]
  const [left, setLeft] = useState(5)
  useEffect(() => {
    const id = setInterval(() => setLeft((s) => {
      if (s <= 1) { clearInterval(id); onDone() }
      return s - 1
    }), 1000)
    return () => clearInterval(id)
  }, []) // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <div style={{
      position: 'fixed', inset: 0, zIndex: 100, display: 'grid', placeItems: 'center',
      background: r?.team === 'rojo' ? '#8a1f12' : '#123c8a',
    }}>
      <div style={{ display: 'grid', gap: 10, textAlign: 'center' }}>
        <p style={{ fontSize: '4rem' }}>{full ? r?.emoji : r?.team === 'rojo' ? '🔴' : '🔵'}</p>
        <p style={{ fontFamily: 'var(--font-display)', fontSize: '2rem', color: '#fff' }}>
          {full ? r?.name : r?.team === 'rojo' ? 'ROJO' : 'AZUL'}
        </p>
        <p style={{ fontWeight: 700, color: '#fff', opacity: 0.8 }}>{left}s</p>
      </div>
    </div>
  )
}

function DosCuartosView({ ctx }: { ctx: GameCtx<DcState> }) {
  const { state: st, players, me, act, secret } = ctx
  const [share, setShare] = useState<null | 'color' | 'rol'>(null)
  const nameOf = (pid?: string | null) => players.find((p) => p.id === pid)?.name ?? '?'
  const myRole = String(secret?.role ?? '')
  const myRoom = st.rooms?.[me.id]
  const roomMates = players.filter((p) => st.rooms?.[p.id] === myRoom)
  const leader = myRoom ? st.leaders?.[String(myRoom)] : null
  const soyLider = leader === me.id
  const hostages = myRoom ? (st.hostages?.[String(myRoom)] ?? []) : []

  const roomBanner = myRoom && (
    <Card accent={myRoom === 1 ? 'var(--amber)' : '#C792EA'} style={{ textAlign: 'center' }}>
      <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.6rem' }}>🚪 CUARTO {myRoom}</p>
      <p style={{ fontWeight: 700, color: 'var(--muted)', fontSize: '0.85rem' }}>
        Vete físicamente con tu cuarto. Aquí hay gente de LOS DOS equipos — no sabes quién es quién.
      </p>
    </Card>
  )

  if (st.phase === 'reparto') {
    const r = ROLE[myRole]
    const listo = !!st.ready?.[me.id]
    const done = Object.keys(st.ready ?? {}).length
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        {share && <ShareOverlay role={myRole} full={share === 'rol'} onDone={() => setShare(null)} />}
        <HowToPlay title="Cómo se juega Dos Cuartos" lines={REGLAS_DC} startOpen />
        {roomBanner}
        {secret == null || !r ? (
          <Card><p style={{ fontWeight: 700, color: 'var(--muted)', textAlign: 'center' }}>Repartiendo cartas…</p></Card>
        ) : (
          <Card accent={r.color} style={{ display: 'grid', gap: 8, textAlign: 'center' }}>
            <p style={{ fontSize: '2.4rem' }}>{r.emoji}</p>
            <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.4rem', color: r.color }}>{r.name}</p>
            <p style={{ fontWeight: 700, color: 'var(--muted)', fontSize: '0.9rem' }}>
              {myRole === 'presidente' ? 'El equipo azul gana si terminas LEJOS de la Bomba.'
                : myRole === 'bomba' ? 'El equipo rojo gana si terminas EN EL MISMO CUARTO que el Presidente.'
                : myRole === 'azul' ? 'Protege al Presidente: que la Bomba no termine con él.'
                : 'Ayuda a que la Bomba termine junto al Presidente.'}
            </p>
          </Card>
        )}
        {st.offline ? (
          <>
            <Card><p style={{ fontWeight: 700, textAlign: 'center', color: 'var(--muted)' }}>
              🪑 Modo en vivo: rondas, líderes y rehenes se manejan HABLANDO. Comparte tu carta cuando quieras:
            </p></Card>
            <div style={{ display: 'flex', gap: 8 }}>
              <Button variant="secondary" style={{ flex: 1 }} onClick={() => setShare('color')}>Mostrar COLOR 5s</Button>
              <Button variant="secondary" style={{ flex: 1 }} onClick={() => setShare('rol')}>Mostrar ROL 5s</Button>
            </div>
          </>
        ) : (
          <>
            <Button big onClick={() => void act('ready')} disabled={listo} style={listo ? { opacity: 0.4 } : undefined}>
              {listo ? 'Listo ✓' : 'Ya vi mi carta 👀'}
            </Button>
            <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>{done}/{players.length} listos</p>
          </>
        )}
      </div>
    )
  }

  if (st.phase === 'ronda') {
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        {share && <ShareOverlay role={myRole} full={share === 'rol'} onDone={() => setShare(null)} />}
        {roomBanner}
        <Card style={{ display: 'grid', gap: 8 }}>
          <p style={{ fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase', color: 'var(--muted)' }}>
            Ronda {st.round}/3 · compartir carta EN PERSONA
          </p>
          <div style={{ display: 'flex', gap: 8 }}>
            <Button variant="secondary" style={{ flex: 1 }} onClick={() => setShare('color')}>Mostrar COLOR 5s</Button>
            <Button variant="secondary" style={{ flex: 1 }} onClick={() => setShare('rol')}>Mostrar ROL 5s</Button>
          </div>
        </Card>

        <section style={{ display: 'grid', gap: 8 }}>
          <p style={{ fontWeight: 700 }}>
            En tu cuarto {soyLider ? `— eres el líder 👑, elige ${st.h_count} rehén${(st.h_count ?? 1) > 1 ? 'es' : ''}:` : `— líder: ${nameOf(leader)} 👑`}
          </p>
          <div style={{ display: 'grid', gap: 8, gridTemplateColumns: 'repeat(auto-fill, minmax(140px, 1fr))' }}>
            {roomMates.map((p) => {
              const esRehen = hostages.includes(p.id)
              const clickable = soyLider && p.id !== me.id
              return (
                <motion.button key={p.id} whileTap={clickable ? { scale: 0.95 } : undefined}
                  onClick={clickable ? () => {
                    const next = esRehen ? hostages.filter((x) => x !== p.id) : [...hostages, p.id].slice(0, st.h_count ?? 1)
                    void act('hostages', { pids: next })
                  } : undefined}
                  style={{
                    display: 'flex', alignItems: 'center', gap: 8, padding: 10,
                    cursor: clickable ? 'pointer' : 'default',
                    background: esRehen ? 'var(--amber)' : 'var(--surface)',
                    color: esRehen ? '#000' : 'var(--ink)',
                    border: 'var(--border)', boxShadow: esRehen ? 'var(--shadow)' : 'none',
                  }}>
                  <AvatarBlock avatar={p.avatar} size={26} />
                  <span style={{ fontWeight: 700, overflow: 'hidden', textOverflow: 'ellipsis' }}>
                    {p.id === leader ? '👑 ' : ''}{p.name}{esRehen ? ' →' : ''}
                  </span>
                </motion.button>
              )
            })}
          </div>
          {hostages.length > 0 && !soyLider && (
            <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.85rem' }}>
              Rehenes elegidos: {hostages.map(nameOf).join(', ')}
            </p>
          )}
        </section>

        <section style={{ display: 'grid', gap: 8 }}>
          <p style={{ fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase', color: 'var(--muted)' }}>
            🏴 Motín: vota por un nuevo líder (mayoría del cuarto)
          </p>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            {roomMates.filter((p) => p.id !== leader).map((p) => {
              const votes = Object.entries(st.usurp ?? {}).filter(([voter, t]) =>
                t === p.id && st.rooms?.[voter] === myRoom).length
              const myPick = st.usurp?.[me.id] === p.id
              return (
                <button key={p.id} onClick={() => void act('usurpar', { target: p.id })}
                  style={{
                    padding: '6px 10px', fontWeight: 700, fontSize: '0.8rem', cursor: 'pointer',
                    border: 'var(--border-thin)',
                    background: myPick ? 'var(--coral)' : 'var(--surface)',
                    color: myPick ? '#000' : 'var(--ink)',
                  }}>
                  {p.name}{votes > 0 ? ` (${votes})` : ''}
                </button>
              )
            })}
          </div>
        </section>
      </div>
    )
  }

  if (st.phase === 'intercambio') {
    const h1 = st.hostages?.['1'] ?? []
    const h2 = st.hostages?.['2'] ?? []
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <Card accent="var(--amber)" style={{ textAlign: 'center' }}>
          <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.3rem' }}>🔁 Intercambio de rehenes</p>
          <p style={{ fontWeight: 700, color: 'var(--muted)', fontSize: '0.85rem' }}>Caminen YA al otro cuarto</p>
        </Card>
        <Card style={{ display: 'grid', gap: 6 }}>
          <p style={{ fontWeight: 700 }}>Cuarto 1 → 2: {h1.length ? h1.map(nameOf).join(', ') : 'nadie'}</p>
          <p style={{ fontWeight: 700 }}>Cuarto 2 → 1: {h2.length ? h2.map(nameOf).join(', ') : 'nadie'}</p>
        </Card>
        {(h1.includes(me.id) || h2.includes(me.id)) && (
          <Card accent="var(--coral)">
            <p style={{ fontWeight: 700, textAlign: 'center' }}>¡TÚ CRUZAS! 🚶 Agarra tus cosas.</p>
          </Card>
        )}
      </div>
    )
  }

  if (st.phase === 'reveal') {
    // offline: winner null — la app solo revela quién era quién
    if (st.winner == null) {
      return (
        <div style={{ display: 'grid', gap: 14 }}>
          <motion.div initial={{ scale: 0.6 }} animate={{ scale: 1 }} transition={{ type: 'spring', stiffness: 260, damping: 14 }}>
            <Card accent="var(--amber)" style={{ textAlign: 'center', display: 'grid', gap: 6 }}>
              <p style={{ fontSize: '2.6rem' }}>💣</p>
              <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.4rem' }}>LA REVELACIÓN</p>
            </Card>
          </motion.div>
          <Card style={{ display: 'grid', gap: 6 }}>
            <p style={{ fontWeight: 700 }}>🎩 Presidente: {nameOf(st.presidente)}</p>
            <p style={{ fontWeight: 700 }}>💣 Bomba: {nameOf(st.bomba)}</p>
            <p style={{ fontWeight: 700, color: 'var(--muted)', fontSize: '0.85rem' }}>
              ¿Quedaron en el mismo cuarto? Ustedes saben — si sí, BOOM: gana el rojo.
            </p>
          </Card>
        </div>
      )
    }
    const rojo = st.winner === 'rojo'
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <motion.div initial={{ scale: 0.6 }} animate={{ scale: 1 }} transition={{ type: 'spring', stiffness: 260, damping: 14 }}>
          <Card accent={rojo ? 'var(--coral)' : '#5CB8FF'} style={{ textAlign: 'center', display: 'grid', gap: 6 }}>
            <p style={{ fontSize: '2.6rem' }}>{rojo ? '💥' : '🛡'}</p>
            <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.5rem' }}>
              {rojo ? 'BOOM — GANA EL ROJO' : 'GANA EL AZUL'}
            </p>
          </Card>
        </motion.div>
        <Card style={{ display: 'grid', gap: 6 }}>
          <p style={{ fontWeight: 700 }}>🎩 Presidente: {nameOf(st.presidente)} (cuarto {st.rooms?.[st.presidente ?? ''] ?? '?'})</p>
          <p style={{ fontWeight: 700 }}>💣 Bomba: {nameOf(st.bomba)} (cuarto {st.rooms?.[st.bomba ?? ''] ?? '?'})</p>
          <p style={{ fontWeight: 700, color: 'var(--muted)', fontSize: '0.85rem' }}>
            {rojo ? 'Terminaron en el mismo cuarto — la bomba explotó junto al Presidente.' : 'Cuartos distintos — el Presidente sobrevivió.'}
          </p>
        </Card>
      </div>
    )
  }

  return null
}

function DosCuartosHost({ ctx }: { ctx: GameCtx<DcState> }) {
  const { state: st, advance } = ctx
  if (st.offline && st.phase === 'reparto') {
    return <Button variant="ghost" onClick={() => void advance(true)}>Revelar presidente y bomba 💣</Button>
  }
  if (st.phase === 'intercambio') {
    return <Button big onClick={() => void advance(true)}>{(st.round ?? 1) >= 3 ? 'Ver el final 💣' : 'Ya cruzaron → siguiente ronda'}</Button>
  }
  if (st.phase === 'reveal') {
    return <Button big onClick={() => void advance(true)}>Terminar juego 🏁</Button>
  }
  return null
}

const PHASE_TITLE: Record<string, string> = {
  reparto: 'Tu carta y tu cuarto',
  ronda: 'La ronda corre',
  intercambio: 'Rehenes',
  reveal: '¿Boom?',
}

export const dosCuartosGame: GameDefinition<DcState> = {
  id: 'dos-cuartos',
  nameEs: 'Dos Cuartos y la Bomba',
  phaseTitle: (st) => PHASE_TITLE[st.phase] ?? st.phase,
  needsSecret: () => true,
  PlayerView: DosCuartosView,
  HostView: DosCuartosHost,
}
