const KEY = 'lanoche_session'

export interface StoredSession {
  partyId: string
  playerId: string
  code: string
}

export function saveSession(s: StoredSession) {
  localStorage.setItem(KEY, JSON.stringify(s))
}

export function loadSession(): StoredSession | null {
  try {
    const raw = localStorage.getItem(KEY)
    return raw ? (JSON.parse(raw) as StoredSession) : null
  } catch {
    return null
  }
}

export function clearSession() {
  localStorage.removeItem(KEY)
}
