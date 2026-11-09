import { createContext, useCallback, useContext, useEffect, useMemo } from 'react'
import type { ReactNode } from 'react'
import type { Mode, NoteName } from '../types'
import { keyLabel as fmtKey } from '../lib/theory'
import { useLocalStorage } from '../lib/useLocalStorage'
import { engine } from '../audio/engine'

/**
 * Estado global mínimo: tonalidad (root + modo) y BPM.
 * Cambiar la tonalidad en el círculo de quintas la cambia en todos los módulos.
 */
interface MusicState {
  root: NoteName
  mode: Mode
  bpm: number
  setKey: (root: NoteName, mode: Mode) => void
  setBpm: (bpm: number) => void
  /** 'F#m' / 'Bb' */
  label: string
}

const Ctx = createContext<MusicState | null>(null)

export function MusicProvider({ children }: { children: ReactNode }) {
  const [key, setKeyState] = useLocalStorage<{ root: NoteName; mode: Mode }>('key', {
    root: 'F#',
    mode: 'minor',
  })
  const [bpm, setBpmState] = useLocalStorage<number>('bpm', 95)

  // El transport siempre refleja el BPM global.
  useEffect(() => {
    if (engine.isStarted) engine.setBpm(bpm)
  }, [bpm])

  const setKey = useCallback(
    (root: NoteName, mode: Mode) => setKeyState({ root, mode }),
    [setKeyState],
  )

  const setBpm = useCallback(
    (next: number) => {
      const clamped = Math.min(220, Math.max(40, Math.round(next)))
      setBpmState(clamped)
      if (engine.isStarted) engine.setBpm(clamped)
    },
    [setBpmState],
  )

  const value = useMemo<MusicState>(
    () => ({
      root: key.root,
      mode: key.mode,
      bpm,
      setKey,
      setBpm,
      label: fmtKey(key.root, key.mode),
    }),
    [key.root, key.mode, bpm, setKey, setBpm],
  )

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export function useMusic(): MusicState {
  const ctx = useContext(Ctx)
  if (!ctx) throw new Error('useMusic debe usarse dentro de <MusicProvider>')
  return ctx
}
