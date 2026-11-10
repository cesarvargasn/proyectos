import { Button } from '../ui/Button'
import { Card } from '../ui/Card'
import { Input } from '../ui/Input'
import { CodeMarquee } from '../ui/CodeMarquee'

const tokens = [
  ['--bg', '#1A1614'],
  ['--surface', '#262019'],
  ['--ink', '#F5EFE6'],
  ['--amber', '#FFB224'],
  ['--coral', '#FF5C47'],
  ['--muted', '#A89C8C'],
]

/** Kitchen sink de fase 0 — se borra cuando exista el spine real. */
export function DesignDemo() {
  return (
    <main style={{ maxWidth: 480, margin: '0 auto', padding: '32px 20px 80px', display: 'grid', gap: 36 }}>
      <header>
        <p style={{ color: 'var(--muted)', fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.1em' }}>
          fase 0 · design system
        </p>
        <h1>La Noche</h1>
        <p style={{ marginTop: 8 }}>
          16 juegos. Un celular. Toda la noche.
        </p>
      </header>

      <section>
        <h3 style={{ marginBottom: 12 }}>Código de sala</h3>
        <CodeMarquee code="PMQZ" />
      </section>

      <section style={{ display: 'grid', gap: 12 }}>
        <h3>Botones</h3>
        <Button big>Lanzar juego</Button>
        <Button variant="secondary">Unirme</Button>
        <Button variant="danger">Forzar avance</Button>
        <Button variant="ghost">Salir</Button>
      </section>

      <section style={{ display: 'grid', gap: 12 }}>
        <h3>Input</h3>
        <Input placeholder="CÓDIGO" maxLength={4} style={{ textTransform: 'uppercase', textAlign: 'center', fontFamily: 'var(--font-display)', fontSize: '1.6rem', letterSpacing: '0.3em' }} />
      </section>

      <section style={{ display: 'grid', gap: 12 }}>
        <h3>Cards</h3>
        <Card>
          <h3 style={{ color: 'var(--amber)' }}>Yo Nunca</h3>
          <p style={{ color: 'var(--muted)' }}>3–20 jugadores</p>
        </Card>
        <Card accent="var(--coral)">
          <h3 style={{ color: 'var(--coral)' }}>Lobos</h3>
          <p style={{ color: 'var(--muted)' }}>6–20 jugadores</p>
        </Card>
      </section>

      <section>
        <h3 style={{ marginBottom: 12 }}>Tokens</h3>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          {tokens.map(([name, hex]) => (
            <div key={name} style={{ border: 'var(--border-thin)', padding: 10, display: 'flex', alignItems: 'center', gap: 10 }}>
              <span style={{ width: 28, height: 28, background: `var(${name})`, border: '2px solid var(--muted)', flexShrink: 0 }} />
              <span style={{ fontSize: '0.8rem' }}>
                <strong>{name}</strong>
                <br />
                <span style={{ color: 'var(--muted)' }}>{hex}</span>
              </span>
            </div>
          ))}
        </div>
      </section>
    </main>
  )
}
