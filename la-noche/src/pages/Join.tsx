import { useEffect, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { motion } from 'framer-motion'
import { Button } from '../ui/Button'
import { Input } from '../ui/Input'
import { AvatarBlock, AVATAR_SYMBOLS, AVATAR_COLORS, textSymbol } from '../ui/Avatar'
import { createParty, joinParty } from '../lib/api'
import { saveSession, loadSession } from '../lib/session'
import { supabase } from '../lib/supabase'

const ERROR_MSG: Record<string, string> = {
  CODIGO_INVALIDO: 'Ese código no existe (o la noche ya terminó).',
  SALA_LLENA: 'La sala está llena (máx 20).',
  EXPULSADO: 'Te sacaron de esta noche.',
  SOLO_ADMIN: 'Solo el admin puede crear la noche.',
}

/** /crear (host) y /j/:code (invitado): nombre + avatar → lobby. */
export function Join({ mode }: { mode: 'create' | 'join' }) {
  const nav = useNavigate()
  const { code } = useParams()
  const [name, setName] = useState('')
  const [symbol, setSymbol] = useState<string>(AVATAR_SYMBOLS[0])
  const [color, setColor] = useState<string>(AVATAR_COLORS[0])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  // Gate de admin para /crear: null=verificando, false=pedir login, true=listo.
  const [adminReady, setAdminReady] = useState<boolean | null>(mode === 'create' ? null : true)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')

  useEffect(() => {
    if (mode !== 'create') return
    void supabase.auth.getSession().then(({ data }) => {
      setAdminReady(!!data.session && !data.session.user.is_anonymous)
    })
  }, [mode])

  // Reconnection-first: mismo QR/link de una noche donde ya estoy →
  // directo a la sala, sin re-llenar nombre/avatar.
  useEffect(() => {
    if (mode !== 'join') return
    const stored = loadSession()
    if (stored && stored.code === (code ?? '').toUpperCase()) nav('/sala')
  }, [mode, code]) // eslint-disable-line react-hooks/exhaustive-deps

  async function login(e: React.FormEvent) {
    e.preventDefault()
    if (busy) return
    setBusy(true)
    setError('')
    // si había sesión anónima, se reemplaza por la real
    const { error: err } = await supabase.auth.signInWithPassword({ email: email.trim(), password })
    setBusy(false)
    if (err) {
      setError('Email o contraseña incorrectos.')
      return
    }
    setAdminReady(true)
  }

  async function go() {
    if (!name.trim() || busy) return
    setBusy(true)
    setError('')
    try {
      const avatar = { symbol, color }
      const res =
        mode === 'create'
          ? await createParty(name.trim(), avatar)
          : await joinParty(code ?? '', name.trim(), avatar)
      saveSession({ partyId: res.party_id, playerId: res.player_id, code: res.code })
      nav('/sala')
    } catch (e) {
      const msg = e instanceof Error ? e.message : ''
      setError(ERROR_MSG[msg] ?? `Algo falló: ${msg || 'intenta de nuevo'}`)
      setBusy(false)
    }
  }

  if (mode === 'create' && adminReady === null) return null

  if (mode === 'create' && !adminReady) {
    return (
      <main style={{ maxWidth: 480, margin: '0 auto', padding: '48px 24px 60px' }}>
        <form onSubmit={(e) => void login(e)} style={{ display: 'grid', gap: 18 }}>
          <div>
            <p style={{ color: 'var(--muted)', fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.12em' }}>
              zona del admin
            </p>
            <h2>¿Eres César?</h2>
          </div>
          <Input
            autoFocus
            type="email"
            placeholder="Email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
          <Input
            type="password"
            placeholder="Contraseña"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
          {error && <p style={{ color: 'var(--coral)', fontWeight: 700 }}>{error}</p>}
          <Button big type="submit" disabled={busy || !email.trim() || !password} style={busy || !email.trim() || !password ? { opacity: 0.4 } : undefined}>
            {busy ? '…' : 'Entrar'}
          </Button>
          <Button variant="ghost" type="button" onClick={() => nav('/')}>
            Volver
          </Button>
        </form>
      </main>
    )
  }

  return (
    <main style={{ maxWidth: 480, margin: '0 auto', padding: '48px 24px 60px', display: 'grid', gap: 24 }}>
      <div>
        <p style={{ color: 'var(--muted)', fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.12em' }}>
          {mode === 'create' ? 'crear noche' : `código ${code}`}
        </p>
        <h2>¿Quién eres?</h2>
      </div>

      <Input
        autoFocus
        placeholder="Tu nombre"
        maxLength={20}
        value={name}
        onChange={(e) => setName(e.target.value)}
      />

      <div style={{ display: 'grid', gap: 10 }}>
        <p style={{ fontWeight: 700, textTransform: 'uppercase', fontSize: '0.85rem', color: 'var(--muted)' }}>Tu símbolo</p>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          {AVATAR_SYMBOLS.map((s) => (
            <motion.button
              key={s}
              whileTap={{ scale: 0.85 }}
              onClick={() => setSymbol(s)}
              style={{
                width: 52,
                height: 52,
                fontSize: 24,
                background: symbol === s ? 'var(--amber)' : 'var(--surface)',
                color: symbol === s ? '#000' : 'var(--ink)',
                border: 'var(--border)',
                boxShadow: symbol === s ? 'var(--shadow)' : 'none',
              }}
            >
              {textSymbol(s)}
            </motion.button>
          ))}
        </div>
        <p style={{ fontWeight: 700, textTransform: 'uppercase', fontSize: '0.85rem', color: 'var(--muted)' }}>Tu color</p>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          {AVATAR_COLORS.map((c) => (
            <motion.button
              key={c}
              whileTap={{ scale: 0.85 }}
              onClick={() => setColor(c)}
              style={{
                width: 52,
                height: 52,
                background: c,
                border: color === c ? '4px solid var(--ink)' : '3px solid #000',
                boxShadow: color === c ? 'var(--shadow)' : 'none',
              }}
            />
          ))}
        </div>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
        <AvatarBlock avatar={{ symbol, color }} size={56} />
        <span style={{ fontFamily: 'var(--font-display)', fontSize: '1.2rem', textTransform: 'uppercase' }}>
          {name.trim() || '···'}
        </span>
      </div>

      {error && (
        <p style={{ color: 'var(--coral)', fontWeight: 700 }}>{error}</p>
      )}

      <Button big onClick={() => void go()} disabled={!name.trim() || busy} style={!name.trim() || busy ? { opacity: 0.4 } : undefined}>
        {busy ? '…' : mode === 'create' ? 'Crear la noche' : 'Entrar'}
      </Button>
    </main>
  )
}
