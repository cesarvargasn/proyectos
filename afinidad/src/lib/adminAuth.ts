import { useEffect, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from './supabase'

// Module-level cache so synchronous callers (e.g. the questionnaire's
// "return to admin" guard) can check auth without awaiting.
let cachedSession: Session | null = null
supabase.auth.getSession().then(({ data }) => { cachedSession = data.session })
supabase.auth.onAuthStateChange((_e, session) => { cachedSession = session })

// Synchronous best-effort check. By the time an admin navigates around the
// panel the session is already loaded, so this is reliable there.
export function isAdminAuthed(): boolean {
  return cachedSession !== null
}

export async function signInAdmin(email: string, password: string): Promise<string | null> {
  const { error } = await supabase.auth.signInWithPassword({
    email: email.trim(),
    password,
  })
  return error ? error.message : null
}

export async function signOutAdmin(): Promise<void> {
  await supabase.auth.signOut()
}

// React hook for the admin pages. Returns:
//   null  → still resolving the session (show loading)
//   false → not logged in (show login form)
//   true  → logged in (show panel)
export function useAdminAuth(): boolean | null {
  const [authed, setAuthed] = useState<boolean | null>(null)
  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setAuthed(!!data.session))
    const { data } = supabase.auth.onAuthStateChange((_e, session) => setAuthed(!!session))
    return () => data.subscription.unsubscribe()
  }, [])
  return authed
}
