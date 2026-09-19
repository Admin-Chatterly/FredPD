import { cache } from "react"
import { redirect } from "next/navigation"
import { createClient } from "@/lib/supabase/server"

export type CurrentUser = {
  id: string
  email: string | null
}

/** The signed-in user for this request, or null. Memoised per request. */
export const getCurrentUser = cache(async (): Promise<CurrentUser | null> => {
  const supabase = await createClient()
  const { data, error } = await supabase.auth.getClaims()
  if (error || !data?.claims?.sub) return null
  const email = typeof data.claims.email === "string" ? data.claims.email : null
  return { id: data.claims.sub, email }
})

/** Use at the top of every Server Action and protected page. */
export async function requireUser(): Promise<CurrentUser> {
  const user = await getCurrentUser()
  if (!user) redirect("/login")
  return user
}

export type CurrentProfile = CurrentUser & { callsign: string }

/** The signed-in user plus their callsign from the profiles table. */
export const getCurrentProfile = cache(async (): Promise<CurrentProfile | null> => {
  const user = await getCurrentUser()
  if (!user) return null
  const supabase = await createClient()
  const { data } = await supabase
    .from("profiles")
    .select("callsign")
    .eq("id", user.id)
    .maybeSingle()
  const fallback = user.email?.split("@")[0] ?? "Polis"
  return { ...user, callsign: data?.callsign?.trim() || fallback }
})

/** Only paths on this site are allowed as post-login destinations. */
export function safeNextPath(value: unknown): string {
  if (typeof value !== "string") return "/"
  if (!value.startsWith("/") || value.startsWith("//") || value.startsWith("/\\")) return "/"
  return value
}
