import type { Metadata } from "next"
import { LoginForm } from "@/components/auth/login-form"
import { SupabaseNotConfigured } from "@/components/setup-help"
import { safeNextPath } from "@/lib/auth"
import { getSupabaseHost, isSupabaseConfigured } from "@/lib/supabase/env"

export const metadata: Metadata = { title: "Logga in" }

export default async function LoginPage(props: PageProps<"/login">) {
  const searchParams = await props.searchParams
  const next = safeNextPath(searchParams.next)
  // Endast fasta koder; texten bor här, aldrig i adressen.
  const notice =
    searchParams.reason === "session"
      ? "Din session kunde inte verifieras, så du loggades ut. Logga in igen."
      : null

  if (!isSupabaseConfigured()) {
    return (
      <div className="flex flex-1 items-center justify-center p-4">
        <SupabaseNotConfigured />
      </div>
    )
  }

  return (
    <div className="flex flex-1 flex-col items-center justify-center gap-3 p-4">
      <LoginForm next={next} notice={notice} />
      <p className="text-xs text-muted-foreground">Ansluten till {getSupabaseHost()}</p>
    </div>
  )
}
