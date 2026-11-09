import { Suspense, useEffect } from 'react'
import { Header } from './components/Header'
import { MODULES } from './modules/registry'
import { MusicProvider } from './state/MusicContext'
import { useLocalStorage } from './lib/useLocalStorage'
import { engine } from './audio/engine'
import { validateRhythms } from './data/rhythms'

function Tabs({ active, onChange }: { active: string; onChange: (id: string) => void }) {
  return (
    <nav className="border-b border-grid bg-bg sticky top-[53px] z-20">
      <div className="max-w-[1400px] mx-auto px-4 flex gap-1 overflow-x-auto">
        {MODULES.map((m) => {
          const on = m.id === active
          return (
            <button
              key={m.id}
              type="button"
              onClick={() => onChange(m.id)}
              className={`px-4 py-2.5 text-sm whitespace-nowrap border-b-2 transition-colors ${
                on
                  ? 'border-lime text-lime'
                  : 'border-transparent text-muted hover:text-ink hover:border-grid'
              }`}
            >
              {m.label}
              <span className="block text-[10px] text-muted/70 font-mono">{m.hint}</span>
            </button>
          )
        })}
      </div>
    </nav>
  )
}

export default function App() {
  const [active, setActive] = useLocalStorage('tab', MODULES[0].id)

  // Cambiar de módulo detiene lo que estuviera sonando.
  const changeTab = (id: string) => {
    engine.stopAll()
    setActive(id)
  }

  // Chequeo de integridad del contenido: ruido en consola solo en dev.
  useEffect(() => {
    if (!import.meta.env.DEV) return
    const errs = validateRhythms()
    if (errs.length) console.error('[BEATSHEET] patrones inválidos:\n' + errs.join('\n'))
  }, [])

  const current = MODULES.find((m) => m.id === active) ?? MODULES[0]
  const Current = current.Component

  return (
    <MusicProvider>
      <div className="min-h-full flex flex-col">
        <Header />
        <Tabs active={current.id} onChange={changeTab} />
        <main className="flex-1 max-w-[1400px] w-full mx-auto px-4 py-5">
          <Suspense
            fallback={<div className="panel p-8 text-center text-muted text-sm">Cargando…</div>}
          >
            <Current />
          </Suspense>
        </main>
        <footer className="border-t border-grid px-4 py-3 text-[11px] text-muted text-center">
          BEATSHEET — contenido en{' '}
          <span className="font-mono text-ink/70">src/data/</span>. Agregar una progresión, un ritmo
          o un truco es agregar un objeto a un array.
        </footer>
      </div>
    </MusicProvider>
  )
}
