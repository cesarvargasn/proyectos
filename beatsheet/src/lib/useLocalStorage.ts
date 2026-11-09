import { useCallback, useEffect, useState } from 'react'

const PREFIX = 'beatsheet:'

export function readStored<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(PREFIX + key)
    return raw === null ? fallback : (JSON.parse(raw) as T)
  } catch {
    return fallback
  }
}

/** useState persistido en localStorage bajo el prefijo `beatsheet:`. */
export function useLocalStorage<T>(key: string, fallback: T) {
  const [value, setValue] = useState<T>(() => readStored(key, fallback))

  useEffect(() => {
    try {
      localStorage.setItem(PREFIX + key, JSON.stringify(value))
    } catch {
      /* almacenamiento lleno o bloqueado: no es crítico */
    }
  }, [key, value])

  const reset = useCallback(() => setValue(fallback), [fallback])

  return [value, setValue, reset] as const
}
