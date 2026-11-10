import { useState } from 'react'
import { motion } from 'framer-motion'
import type { GameCtx, GameDefinition, GameState } from '../../engine/types'
import { StaggerReveal } from '../../engine/primitives'
import { HowToPlay } from '../../engine/HowToPlay'
import { Button } from '../../ui/Button'
import { Card } from '../../ui/Card'
import { AvatarBlock } from '../../ui/Avatar'
import type { Player } from '../../lib/types'

/**
 * Lobos (016): Werewolf 6–20. Roles en player_secrets (leak-proof).
 * ANTI-TELL: en cada fase de noche TODOS los vivos tocan a alguien —
 * los sin rol nocturno hacen un tap de mentira, así nadie deduce roles
 * mirando pantallas ajenas. Los muertos no hablan 🤫 (espectadores).
 */
interface LbState extends GameState {
  night_no?: number
  ready?: Record<string, boolean>
  acted?: Record<string, boolean>
  votes?: Record<string, string>
  vote_round?: number
  vote_pool?: string[] | null
  dead?: Record<string, boolean>
  revealed?: Record<string, string>
  morning?: { pid: string; role?: string; niebla?: boolean }[]
  executed?: string | null
  hunter?: string | null
  hunter_from?: string | null
  hunter_kill?: { pid: string; role: string } | null
  winner?: 'lobos' | 'aldea' | null
  roles_pub?: Record<string, string> | null
  comp?: { lobos: number; vidente?: boolean; protector?: boolean; bruja: boolean; cazador: boolean }
  offline?: boolean
}

const ROLE: Record<string, { name: string; emoji: string; color: string; desc: string }> = {
  lobo: { name: 'LOBO', emoji: '🐺', color: 'var(--coral)', desc: 'Cada noche, tu manada elige a quién devorar. De día, finge ser gente decente.' },
  vidente: { name: 'VIDENTE', emoji: '🔮', color: '#C792EA', desc: 'Cada noche descubres si alguien es lobo. Guarda el secreto… o no.' },
  protector: { name: 'PROTECTOR', emoji: '🛡', color: '#5CB8FF', desc: 'Cada noche proteges a alguien (puedes protegerte a ti). Si los lobos lo atacan, se salva.' },
  bruja: { name: 'BRUJA', emoji: '🧪', color: '#7ED957', desc: 'Tienes DOS pociones para todo el juego: una salva a la víctima de la noche, otra mata a quien quieras.' },
  cazador: { name: 'CAZADOR', emoji: '🏹', color: 'var(--amber)', desc: 'Si mueres, disparas: te llevas a alguien contigo.' },
  aldeano: { name: 'ALDEANO', emoji: '🌾', color: 'var(--ink)', desc: 'No tienes poderes. Tienes ojos, oídos y un voto. Úsalos.' },
  moderador: { name: 'MODERADOR', emoji: '🎙', color: 'var(--amber)', desc: 'Tú narras la noche y el día. Abajo tienes TODOS los roles — cara de póker.' },
  niebla: { name: 'NIEBLA', emoji: '🌫', color: 'var(--muted)', desc: '' },
}

const REGLAS_LOBOS = [
  '🐺 Hay lobos escondidos entre ustedes. De noche eligen a quién devorar; de día fingen ser gente decente.',
  '🌙 De NOCHE todos tocan la pantalla (aunque no tengan poder) — así nadie sabe quién es quién.',
  '☀️ De DÍA se revela quién murió, debaten y VOTAN a quién linchar.',
  '🌾 La aldea gana cuando caen TODOS los lobos. 🐺 Los lobos ganan cuando son tantos como el resto.',
  '🔮 Vidente: investiga uno por noche · 🛡 Protector: salva a uno · 🧪 Bruja: 2 pociones · 🏹 Cazador: al morir dispara.',
]

const NIGHT_HINT: Record<string, { lobo?: string; vidente?: string; protector?: string; otros: string }> = {
  noche_lobos: { lobo: '🐺 Elige a quién atacar esta noche', otros: 'Toca a cualquiera (para disimular)' },
  noche_vidente: { vidente: '🔮 Elige a quién investigar', otros: 'Toca a cualquiera (para disimular)' },
  noche_protector: { protector: '🛡 Elige a quién proteger esta noche', otros: 'Toca a cualquiera (para disimular)' },
  noche_bruja: { otros: 'Toca a cualquiera (para disimular)' },
}

function alivePlayers(players: Player[], st: LbState) {
  return players.filter((p) => !st.dead?.[p.id])
}

function PickGrid({ players, onPick, picked, allowSelf, meId }: {
  players: Player[]; onPick: (id: string) => void; picked: string | null; allowSelf: boolean; meId: string
}) {
  return (
    <div style={{ display: 'grid', gap: 8, gridTemplateColumns: 'repeat(auto-fill, minmax(140px, 1fr))' }}>
      {players.filter((p) => allowSelf || p.id !== meId).map((p) => (
        <motion.button key={p.id} whileTap={{ scale: 0.95 }} onClick={() => onPick(p.id)}
          style={{
            display: 'flex', alignItems: 'center', gap: 8, padding: 10, cursor: 'pointer',
            background: picked === p.id ? 'var(--amber)' : 'var(--surface)',
            color: picked === p.id ? '#000' : 'var(--ink)',
            border: 'var(--border)', boxShadow: picked === p.id ? 'var(--shadow)' : 'none',
          }}>
          <AvatarBlock avatar={p.avatar} size={26} />
          <span style={{ fontWeight: 700, overflow: 'hidden', textOverflow: 'ellipsis' }}>{p.name}</span>
        </motion.button>
      ))}
    </div>
  )
}

function RoleCard({ role, wolves }: { role: string; wolves?: string }) {
  const r = ROLE[role] ?? ROLE.aldeano
  return (
    <Card accent={r.color} style={{ display: 'grid', gap: 8, textAlign: 'center' }}>
      <p style={{ fontSize: '2.4rem' }}>{r.emoji}</p>
      <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.5rem', color: r.color }}>{r.name}</p>
      <p style={{ fontWeight: 700, color: 'var(--muted)', fontSize: '0.9rem' }}>{r.desc}</p>
      {role === 'lobo' && wolves && (
        <p style={{ fontWeight: 700, color: 'var(--coral)' }}>Tu manada: {wolves}</p>
      )}
    </Card>
  )
}

function LobosView({ ctx }: { ctx: GameCtx<LbState> }) {
  const { state: st, players, me, act, secret } = ctx
  const [picked, setPicked] = useState<string | null>(null)
  const [brujaKill, setBrujaKill] = useState<string | null>(null)
  const nameOf = (pid?: string | null) => players.find((p) => p.id === pid)?.name ?? '?'
  const alive = alivePlayers(players, st)
  const soyMuerto = !!st.dead?.[me.id]
  const myRole = String(secret?.role ?? '')

  // 🔮 visiones acumuladas de la vidente — SIEMPRE visibles para ella
  // (fix 022: antes solo salían un instante en noche_vidente)
  const misVisiones = (secret?.seen ?? []) as { name: string; lobo: boolean }[]
  const visiones = myRole === 'vidente' && misVisiones.length > 0 && (
    <Card accent="#C792EA" style={{ display: 'grid', gap: 4 }}>
      <p style={{ fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase', color: 'var(--muted)' }}>
        🔮 Tus visiones (solo tú las ves)
      </p>
      {misVisiones.map((v, i) => (
        <p key={i} style={{ fontWeight: 700, fontSize: '0.9rem', color: v.lobo ? 'var(--coral)' : '#7ED957' }}>
          {v.name} {v.lobo ? 'ES LOBO 🐺' : 'no es lobo 🌾'}
        </p>
      ))}
    </Card>
  )

  const deadList = Object.entries(st.revealed ?? {}).length > 0 && (
    <Card style={{ display: 'grid', gap: 4 }}>
      <p style={{ fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase', color: 'var(--muted)' }}>Caídos</p>
      {Object.entries(st.revealed ?? {}).map(([pid, role]) => (
        <p key={pid} style={{ fontWeight: 700, fontSize: '0.9rem' }}>
          💀 {nameOf(pid)} — {role === 'niebla' ? 'se lo llevó la niebla 🌫' : `era ${ROLE[role]?.name ?? role} ${ROLE[role]?.emoji ?? ''}`}
        </p>
      ))}
    </Card>
  )

  if (st.phase === 'reparto') {
    const listo = !!st.ready?.[me.id]
    const done = Object.keys(st.ready ?? {}).length
    // 028: array {pid,name,role} (una fila por jugador); antes era objeto por nombre
    // y los bots con nombre repetido se pisaban
    const rawRoles = secret?.admin_roles as { pid: string; name: string; role: string }[] | Record<string, string> | undefined
    const adminRoles = rawRoles == null ? undefined
      : Array.isArray(rawRoles) ? rawRoles
      : Object.entries(rawRoles).map(([name, role]) => ({ pid: name, name, role }))
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <HowToPlay title="Cómo se juega Lobos" lines={REGLAS_LOBOS} startOpen={false} />
        {secret == null
          ? <Card><p style={{ fontWeight: 700, color: 'var(--muted)', textAlign: 'center' }}>Repartiendo roles…</p></Card>
          : <RoleCard role={myRole} wolves={secret.wolves as string | undefined} />}
        {adminRoles && (
          <Card accent="var(--amber)" style={{ display: 'grid', gap: 4 }}>
            <p style={{ fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase', color: 'var(--muted)' }}>
              👁 Solo tú ves esto · {adminRoles.length} jugadores
            </p>
            {adminRoles.map(({ pid, name, role }) => (
              <p key={pid} style={{ fontWeight: 700, fontSize: '0.9rem' }}>
                {ROLE[role]?.emoji ?? ''} {name} — {ROLE[role]?.name ?? role}
              </p>
            ))}
          </Card>
        )}
        <Card style={{ display: 'grid', gap: 4 }}>
          <p style={{ fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase', color: 'var(--muted)' }}>En esta aldea hay</p>
          <p style={{ fontWeight: 700 }}>
            🐺 ×{st.comp?.lobos ?? 2}
            {(st.comp?.vidente ?? true) && ' · 🔮 Vidente'}
            {(st.comp?.protector ?? true) && ' · 🛡 Protector'}
            {st.comp?.bruja && ' · 🧪 Bruja'}{st.comp?.cazador && ' · 🏹 Cazador'} · 🌾 el resto
          </p>
        </Card>
        {st.offline ? (
          <Card><p style={{ fontWeight: 700, textAlign: 'center', color: 'var(--muted)' }}>
            🪑 Modo en vivo: el moderador narra noches y días. La app solo repartió los roles.
          </p></Card>
        ) : (
          <>
            <Button big onClick={() => void act('ready')} disabled={listo} style={listo ? { opacity: 0.4 } : undefined}>
              {listo ? 'Listo ✓' : 'Ya vi mi rol 👀'}
            </Button>
            <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>{done}/{alive.length} listos</p>
          </>
        )}
      </div>
    )
  }

  // espectador: muertos (o los que entraron tarde, sin rol)
  if (soyMuerto || (secret != null && !myRole)) {
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <Card accent="var(--muted)" style={{ textAlign: 'center', display: 'grid', gap: 6 }}>
          <p style={{ fontSize: '2rem' }}>🤫</p>
          <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.2rem' }}>Los muertos no hablan</p>
          <p style={{ fontWeight: 700, color: 'var(--muted)' }}>Mira, sufre en silencio y no hagas caras.</p>
        </Card>
        {deadList}
      </div>
    )
  }

  if (st.phase.startsWith('noche_')) {
    const acted = !!st.acted?.[me.id]
    const done = Object.keys(st.acted ?? {}).length
    const hint = NIGHT_HINT[st.phase]
    const myHint = (hint as Record<string, string>)[myRole] ?? hint.otros
    const esBrujaTurno = st.phase === 'noche_bruja' && myRole === 'bruja'
    const potions = (secret?.potions ?? {}) as { salvar?: boolean; matar?: boolean }
    const victima = secret?.victima as string | null | undefined

    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <Card accent="#C792EA" style={{ textAlign: 'center' }}>
          <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.2rem' }}>🌙 La aldea duerme</p>
          <p style={{ fontWeight: 700, color: 'var(--muted)', fontSize: '0.85rem' }}>Noche {st.night_no}. Nadie mira la pantalla de nadie.</p>
        </Card>

        {esBrujaTurno && !acted ? (
          <div style={{ display: 'grid', gap: 10 }}>
            <Card accent="#7ED957" style={{ display: 'grid', gap: 6 }}>
              <p style={{ fontWeight: 700 }}>🧪 Esta noche los lobos atacaron a: <span style={{ color: 'var(--coral)' }}>{victima ?? 'nadie'}</span></p>
              <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.85rem' }}>
                Pociones: {potions.salvar ? '💚 salvar' : '—'} · {potions.matar ? '☠ matar' : '—'}
              </p>
            </Card>
            {potions.salvar && victima && (
              <Button big onClick={() => void act('bruja', { accion: 'salvar' })}>💚 Salvar a {victima}</Button>
            )}
            {potions.matar && (
              <div style={{ display: 'grid', gap: 8 }}>
                <p style={{ fontWeight: 700, fontSize: '0.85rem', color: 'var(--muted)' }}>☠ O matar a alguien:</p>
                <PickGrid players={alive} meId={me.id} allowSelf={false} picked={brujaKill}
                  onPick={(id) => setBrujaKill(id)} />
                {brujaKill && (
                  <Button big variant="danger" onClick={() => void act('bruja', { accion: 'matar', target: brujaKill })}>
                    ☠ Matar a {nameOf(brujaKill)}
                  </Button>
                )}
              </div>
            )}
            <Button variant="secondary" onClick={() => void act('bruja', { accion: 'nada' })}>Esta noche no hago nada 😴</Button>
          </div>
        ) : (
          <>
            <p style={{ fontWeight: 700, textAlign: 'center' }}>{myHint}</p>
            {visiones}
            {!acted ? (
              <PickGrid players={alive} meId={me.id}
                allowSelf={st.phase === 'noche_protector' && myRole === 'protector'}
                picked={picked}
                onPick={(id) => { setPicked(id); void act('night_pick', { target: id }) }} />
            ) : (
              <Card><p style={{ fontWeight: 700, textAlign: 'center' }}>Hecho ✓ La noche sigue…</p></Card>
            )}
          </>
        )}
        <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>{done}/{alive.length}</p>
      </div>
    )
  }

  if (st.phase === 'amanecer') {
    const morning = st.morning ?? []
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <Card accent="var(--amber)" style={{ textAlign: 'center' }}>
          <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.3rem' }}>☀️ Amanece en la aldea</p>
        </Card>
        {morning.length === 0 ? (
          <Card><p style={{ fontWeight: 700, textAlign: 'center' }}>Nadie murió esta noche 🙏</p></Card>
        ) : (
          <StaggerReveal items={morning.map((m) => ({
            key: m.pid,
            node: (
              <Card accent="var(--coral)">
                <p style={{ fontWeight: 700 }}>
                  💀 {nameOf(m.pid)} {m.niebla
                    ? '— se lo llevó la niebla 🌫'
                    : `amaneció muerto — era ${ROLE[m.role ?? '']?.name ?? m.role} ${ROLE[m.role ?? '']?.emoji ?? ''}`}
                </p>
              </Card>
            ),
          }))} />
        )}
      </div>
    )
  }

  if (st.phase === 'debate') {
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <Card accent="var(--coral)" style={{ textAlign: 'center', display: 'grid', gap: 6 }}>
          <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.3rem' }}>🗣 ¡Hablen!</p>
          <p style={{ fontWeight: 700, color: 'var(--muted)' }}>¿Quién es lobo? Acusen, defiéndanse, mientan.</p>
        </Card>
        {visiones}
        {deadList}
      </div>
    )
  }

  if (st.phase === 'voto') {
    const pool = st.vote_pool
    const candidates = pool ? alive.filter((p) => pool.includes(p.id)) : alive
    const myVote = st.votes?.[me.id]
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        {st.vote_round === 2 && (
          <Card accent="var(--coral)"><p style={{ fontWeight: 700, textAlign: 'center' }}>⚖️ EMPATE — revoto entre los empatados</p></Card>
        )}
        {visiones}
        <p style={{ fontWeight: 700, textAlign: 'center' }}>¿A quién lincha la aldea?</p>
        <PickGrid players={candidates} meId={me.id} allowSelf={false} picked={myVote ?? null}
          onPick={(id) => void act('vote', { target: id })} />
        <p style={{ color: 'var(--muted)', fontWeight: 700, textAlign: 'center' }}>
          {myVote ? 'Voto puesto (puedes cambiarlo)' : 'Vota ya'} · {Object.keys(st.votes ?? {}).length}/{alive.length}
        </p>
      </div>
    )
  }

  if (st.phase === 'linchado') {
    const role = st.executed ? st.revealed?.[st.executed] : null
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <motion.div initial={{ scale: 0.7 }} animate={{ scale: 1 }} transition={{ type: 'spring', stiffness: 300, damping: 14 }}>
          <Card accent={role === 'lobo' ? '#7ED957' : 'var(--coral)'} style={{ textAlign: 'center', display: 'grid', gap: 6 }}>
            {st.executed ? (
              <>
                <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.3rem' }}>⚖️ La aldea linchó a {nameOf(st.executed)}</p>
                <p style={{ fontWeight: 700 }}>Era {ROLE[role ?? '']?.name ?? role} {ROLE[role ?? '']?.emoji ?? ''}{role === 'lobo' ? ' — ¡bien hecho!' : ' — ups.'}</p>
              </>
            ) : (
              <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.2rem' }}>Nadie fue linchado hoy 😮‍💨</p>
            )}
          </Card>
        </motion.div>
      </div>
    )
  }

  if (st.phase === 'caza') {
    const soyCazador = st.hunter === me.id
    if (!soyCazador) {
      return <Card accent="var(--amber)"><p style={{ fontWeight: 700, textAlign: 'center' }}>🏹 El cazador cayó… y apunta a alguien. Nadie respire.</p></Card>
    }
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <Card accent="var(--amber)"><p style={{ fontWeight: 700, textAlign: 'center' }}>🏹 Caíste, cazador. Te llevas a alguien contigo:</p></Card>
        <PickGrid players={alive} meId={me.id} allowSelf={false} picked={null}
          onPick={(id) => void act('shoot', { target: id })} />
      </div>
    )
  }

  if (st.phase === 'caza_fin') {
    const k = st.hunter_kill
    return (
      <Card accent="var(--amber)" style={{ textAlign: 'center', display: 'grid', gap: 6 }}>
        {k ? (
          <p style={{ fontWeight: 700 }}>🏹 El cazador disparó: {nameOf(k.pid)} cayó — era {ROLE[k.role]?.name ?? k.role} {ROLE[k.role]?.emoji ?? ''}</p>
        ) : (
          <p style={{ fontWeight: 700 }}>🏹 El cazador bajó el arma. Nadie más murió.</p>
        )}
      </Card>
    )
  }

  if (st.phase === 'fin') {
    const lobosWin = st.winner === 'lobos'
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <motion.div initial={{ scale: 0.6 }} animate={{ scale: 1 }} transition={{ type: 'spring', stiffness: 260, damping: 14 }}>
          <Card accent={lobosWin ? 'var(--coral)' : '#7ED957'} style={{ textAlign: 'center', display: 'grid', gap: 6 }}>
            <p style={{ fontSize: '2.4rem' }}>{lobosWin ? '🐺' : '🌾'}</p>
            <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.6rem' }}>
              {lobosWin ? 'GANAN LOS LOBOS' : 'GANA LA ALDEA'}
            </p>
          </Card>
        </motion.div>
        <Card style={{ display: 'grid', gap: 4 }}>
          <p style={{ fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase', color: 'var(--muted)' }}>Los roles eran</p>
          {Object.entries(st.roles_pub ?? {}).filter(([, role]) => role !== 'moderador').map(([pid, role]) => (
            <p key={pid} style={{ fontWeight: 700, fontSize: '0.9rem' }}>
              {ROLE[role]?.emoji ?? ''} {nameOf(pid)} — {ROLE[role]?.name ?? role}{st.dead?.[pid] ? ' 💀' : ''}
            </p>
          ))}
        </Card>
      </div>
    )
  }

  return null
}

function LobosHost({ ctx }: { ctx: GameCtx<LbState> }) {
  const { state: st, advance } = ctx
  if (st.offline) {
    if (st.phase === 'reparto') {
      return <Button variant="ghost" onClick={() => void advance(true)}>Revelar roles y cerrar 🏁</Button>
    }
    if (st.phase === 'fin') {
      return <Button big onClick={() => void advance(true)}>Terminar juego 🏁</Button>
    }
    return null
  }
  if (st.phase === 'amanecer') {
    return <Button big onClick={() => void advance(true)}>{st.winner ? 'Ver final 🏁' : st.hunter && !st.hunter_kill ? 'El cazador dispara 🏹' : 'A debatir 🗣'}</Button>
  }
  if (st.phase === 'debate') {
    return <Button big onClick={() => void advance(true)}>Ir a votar 🗳</Button>
  }
  if (st.phase === 'linchado') {
    return <Button big onClick={() => void advance(true)}>{st.winner ? 'Ver final 🏁' : 'Cae la noche 🌙'}</Button>
  }
  if (st.phase === 'caza_fin') {
    return <Button big onClick={() => void advance(true)}>{st.winner ? 'Ver final 🏁' : 'Continuar →'}</Button>
  }
  if (st.phase === 'fin') {
    return <Button big onClick={() => void advance(true)}>Terminar juego 🏁</Button>
  }
  return null
}

const PHASE_TITLE: Record<string, string> = {
  reparto: 'Tu rol',
  noche_lobos: 'La aldea duerme',
  noche_vidente: 'La aldea duerme',
  noche_protector: 'La aldea duerme',
  noche_bruja: 'La aldea duerme',
  amanecer: 'Amanecer',
  debate: 'El juicio del pueblo',
  voto: 'El voto',
  linchado: 'La sentencia',
  caza: 'El último disparo',
  caza_fin: 'El último disparo',
  fin: 'Se acabó',
}

export const lobosGame: GameDefinition<LbState> = {
  id: 'lobos',
  nameEs: 'Lobos',
  phaseTitle: (st) => PHASE_TITLE[st.phase] ?? st.phase,
  needsSecret: (st) => st.phase !== 'fin',
  PlayerView: LobosView,
  HostView: LobosHost,
}
