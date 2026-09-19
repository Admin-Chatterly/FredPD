import { cache } from "react"
import { cookies } from "next/headers"
import { createServerClient } from "@supabase/ssr"
import type { Database } from "@/lib/database.types"
import { getSupabaseEnv } from "@/lib/supabase/env"

/**
 * Server-side client bound to the current request's cookies. Memoised per
 * request (React cache), never shared across requests.
 */
export const createClient = cache(async () => {
  const cookieStore = await cookies()
  const { url, key } = getSupabaseEnv()

  return createServerClient<Database>(url, key, {
    cookies: {
      getAll() {
        return cookieStore.getAll()
      },
      setAll(cookiesToSet) {
        try {
          cookiesToSet.forEach(({ name, value, options }) =>
            cookieStore.set(name, value, options)
          )
        } catch {
          // Called from a Server Component, where cookies are read-only.
          // The proxy refreshes sessions, so this is safe to ignore.
        }
      },
    },
  })
})
