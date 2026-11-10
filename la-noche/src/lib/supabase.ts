import { createClient } from '@supabase/supabase-js'

export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY,
)

/** Garantiza sesión anónima antes de cualquier RPC. */
export async function ensureAuth(): Promise<string> {
  const { data } = await supabase.auth.getSession()
  if (data.session) return data.session.user.id
  const { data: anon, error } = await supabase.auth.signInAnonymously()
  if (error || !anon.user) throw error ?? new Error('No se pudo iniciar sesión anónima')
  return anon.user.id
}
