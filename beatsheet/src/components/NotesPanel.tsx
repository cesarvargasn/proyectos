import { useState } from 'react'
import { useLocalStorage } from '../lib/useLocalStorage'

/** Panel colapsable de notas personales, persistido por módulo. */
export function NotesPanel({ moduleId }: { moduleId: string }) {
  const [open, setOpen] = useLocalStorage(`notes-open:${moduleId}`, false)
  const [text, setText] = useLocalStorage(`notes:${moduleId}`, '')
  const [saved, setSaved] = useState(false)

  return (
    <div className="panel">
      <button
        type="button"
        onClick={() => setOpen(!open)}
        className="w-full flex items-center justify-between px-4 py-2.5 text-left"
      >
        <span className="label">
          Mis notas {text.trim() ? <span className="text-lime">•</span> : null}
        </span>
        <span className="font-mono text-muted text-xs">{open ? '−' : '+'}</span>
      </button>
      {open && (
        <div className="px-4 pb-4">
          <textarea
            value={text}
            onChange={(e) => {
              setText(e.target.value)
              setSaved(true)
            }}
            rows={6}
            placeholder="Trucos tuyos, cosas que probaste, qué funcionó…"
            className="w-full bg-bg border border-grid rounded-md p-3 font-mono text-sm
                       text-ink placeholder:text-muted/60 focus:outline-none focus:border-lime/60"
          />
          <p className="text-[11px] text-muted mt-1">
            {saved ? 'Guardado automáticamente en este navegador.' : 'Se guarda solo, en este navegador.'}
          </p>
        </div>
      )}
    </div>
  )
}
