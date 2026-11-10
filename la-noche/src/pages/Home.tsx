import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { motion } from 'framer-motion'
import { Button } from '../ui/Button'
import { Input } from '../ui/Input'
import { ensureAuth } from '../lib/supabase'
import { fetchPartyState } from '../lib/api'
import { loadSession, clearSession } from '../lib/session'

export function Home() {
  const nav = useNavigate()
  const [code, setCode] = useState('')
  const [showJoin, setShowJoin] = useState(false)
  const [resumeCode, setResumeCode] = useState<string | null>(null)

  // Reconnection-first: si hay sesión guardada y sigo activo en la
  // party, ofrezco volver de una (sin re-meter código).
  useEffect(() => {
    const stored = loadSession()
    if (!stored) return
    void ensureAuth()
      .then(() => fetchPartyState(stored.partyId))
      .then(({ players }) => {
        if (players.some((p) => p.id === stored.playerId)) setResumeCode(stored.code)
        else clearSession()
      })
      .catch(() => clearSession())
  }, [])

  return (
    <main style={{ maxWidth: 480, margin: '0 auto', padding: '15vh 24px 60px', display: 'grid', gap: 28 }}>
      <motion.div initial={{ y: 20, opacity: 0 }} animate={{ y: 0, opacity: 1 }} transition={{ type: 'spring', stiffness: 200, damping: 20 }}>
        <p style={{ color: 'var(--muted)', fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.12em' }}>
          bienvenido a
        </p>
        <h1 style={{ color: 'var(--amber)' }}>La Noche</h1>
        <p style={{ marginTop: 10, fontSize: '1.1rem' }}>Un celular. Toda la noche.</p>
      </motion.div>

      {!showJoin ? (
        <div style={{ display: 'grid', gap: 14 }}>
          {resumeCode && (
            <motion.div initial={{ scale: 0.9, opacity: 0 }} animate={{ scale: 1, opacity: 1 }}>
              <Button big variant="danger" style={{ width: '100%' }} onClick={() => nav('/sala')}>
                Seguir en la noche {resumeCode} →
              </Button>
            </motion.div>
          )}
          <Button big onClick={() => setShowJoin(true)}>
            Tengo un código
          </Button>
          <Button variant="secondary" onClick={() => nav('/crear')}>
            Soy el host — crear noche
          </Button>
          <button onClick={() => nav('/cartas')}
            style={{ background: 'none', border: 'none', color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem', cursor: 'pointer', justifySelf: 'center', marginTop: 8 }}>
            cartas (admin)
          </button>
        </div>
      ) : (
        <form
          style={{ display: 'grid', gap: 14 }}
          onSubmit={(e) => {
            e.preventDefault()
            if (code.trim().length === 4) nav(`/j/${code.trim().toUpperCase()}`)
          }}
        >
          <Input
            autoFocus
            placeholder="CÓDIGO"
            maxLength={4}
            value={code}
            onChange={(e) => setCode(e.target.value.toUpperCase().replace(/[^A-Z]/g, ''))}
            style={{ textTransform: 'uppercase', textAlign: 'center', fontFamily: 'var(--font-display)', fontSize: '2rem', letterSpacing: '0.3em' }}
          />
          <Button big type="submit" disabled={code.length !== 4} style={code.length !== 4 ? { opacity: 0.4 } : undefined}>
            Entrar
          </Button>
          <Button variant="ghost" type="button" onClick={() => setShowJoin(false)}>
            Volver
          </Button>
        </form>
      )}
    </main>
  )
}
