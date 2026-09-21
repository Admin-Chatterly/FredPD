/**
 * Public Supabase connection settings.
 *
 * The property accesses are literal so Next.js can inline the NEXT_PUBLIC_
 * ones into client bundles. The plain SUPABASE_* names are server-side
 * fallbacks for deployments that used the Supabase Vercel integration or a
 * different naming convention.
 */
export const SUPABASE_URL_VARIABLES = ["NEXT_PUBLIC_SUPABASE_URL", "SUPABASE_URL"] as const
export const SUPABASE_KEY_VARIABLES = [
  "NEXT_PUBLIC_SUPABASE_ANON_KEY",
  "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY",
  "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY",
  "SUPABASE_ANON_KEY",
  "SUPABASE_PUBLISHABLE_KEY",
] as const

function readEnv() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL || process.env.SUPABASE_URL
  const key =
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ||
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ||
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY ||
    process.env.SUPABASE_ANON_KEY ||
    process.env.SUPABASE_PUBLISHABLE_KEY
  return { url: url?.trim() || undefined, key: key?.trim() || undefined }
}

/** True when both the project URL and a public key are present. */
export function isSupabaseConfigured(): boolean {
  const { url, key } = readEnv()
  return Boolean(url && key)
}

/** Host of the configured project, for display. Null when unset or unparseable. */
export function getSupabaseHost(): string | null {
  const { url } = readEnv()
  if (!url) return null
  try {
    return new URL(url).host
  } catch {
    return url
  }
}

export function getSupabaseEnv() {
  const { url, key } = readEnv()
  if (!url || !key) {
    throw new Error(
      "Supabase är inte konfigurerat. Sätt NEXT_PUBLIC_SUPABASE_URL och NEXT_PUBLIC_SUPABASE_ANON_KEY (se README)."
    )
  }
  return { url, key }
}
