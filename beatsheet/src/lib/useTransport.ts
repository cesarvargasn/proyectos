import { useEffect, useState } from 'react'
import { engine } from '../audio/engine'

/**
 * true si el módulo `owner` es quien tiene el transport.
 * Como solo un módulo suena a la vez, esto también sirve para resetear el
 * botón de play cuando otro módulo se roba el transport.
 */
export function useIsPlaying(owner: string): boolean {
  const [playing, setPlaying] = useState(() => engine.currentOwner === owner)
  useEffect(() => {
    const unsub = engine.subscribeOwner((o) => setPlaying(o === owner))
    setPlaying(engine.currentOwner === owner)
    return unsub
  }, [owner])
  return playing
}

/** Detiene el audio al desmontar el módulo (cambio de tab). */
export function useStopOnUnmount(owner: string) {
  useEffect(
    () => () => {
      if (engine.currentOwner === owner) engine.stopAll()
    },
    [owner],
  )
}
