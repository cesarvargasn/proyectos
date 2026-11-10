import { useEffect } from 'react'

/** Mantiene la pantalla encendida durante la noche (si el browser lo soporta). */
export function useWakeLock() {
  useEffect(() => {
    let lock: WakeLockSentinel | null = null
    let released = false

    async function acquire() {
      try {
        if ('wakeLock' in navigator && document.visibilityState === 'visible') {
          lock = await navigator.wakeLock.request('screen')
        }
      } catch {
        // sin soporte o sin permiso: no es crítico
      }
    }

    function onVisibility() {
      if (document.visibilityState === 'visible' && !released) void acquire()
    }

    void acquire()
    document.addEventListener('visibilitychange', onVisibility)
    return () => {
      released = true
      document.removeEventListener('visibilitychange', onVisibility)
      void lock?.release().catch(() => {})
    }
  }, [])
}
