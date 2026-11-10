import { useState } from 'react'
import { useNavigate, Link } from 'react-router-dom'
import { motion } from 'framer-motion'

export default function Home() {
  const navigate = useNavigate()
  const [code, setCode] = useState('')

  function handleJoin(e: React.FormEvent) {
    e.preventDefault()
    const c = code.trim().toUpperCase()
    if (!c) return
    navigate(`/e/${c}`)
  }

  return (
    <div className="home-page">
      <div className="home-inner">
        <motion.div
          className="home-hero"
          initial={{ opacity: 0, y: 24 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5 }}
        >
          <p className="home-eyebrow">Afinidad</p>
          <h1 className="home-title">
            ¿Quién es<br />tu gente?
          </h1>
          <p className="home-sub">
            Una noche. Un algoritmo.<br />Tu gente.
          </p>
        </motion.div>

        <motion.div
          initial={{ opacity: 0, y: 16 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.2 }}
        >
          <form onSubmit={handleJoin} className="home-form">
            <div className="field">
              <label htmlFor="event-code">Código del evento</label>
              <input
                id="event-code"
                type="text"
                value={code}
                onChange={e => setCode(e.target.value.toUpperCase())}
                placeholder="ABC123"
                maxLength={6}
                autoFocus
                autoCapitalize="characters"
                autoComplete="off"
                className="home-code-input"
              />
            </div>
            <button
              type="submit"
              className="btn-primary"
              disabled={code.trim().length < 4}
            >
              Entrar →
            </button>
          </form>
        </motion.div>

        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 0.5 }}
        >
          <Link to="/admin" className="home-admin-link">administrar</Link>
        </motion.div>
      </div>

      <div className="home-deco" aria-hidden="true">
        <span className="home-deco-line" />
        <span className="home-deco-dot" />
        <span className="home-deco-line" />
      </div>
    </div>
  )
}
