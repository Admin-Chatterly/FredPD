import { createBrowserClient } from "@supabase/ssr"
import type { Database } from "@/lib/database.types"
import { getSupabaseEnv } from "@/lib/supabase/env"

/** Browser-side client. Used for direct-to-storage uploads and realtime later. */
export function createClient() {
  const { url, key } = getSupabaseEnv()
  return createBrowserClient<Database>(url, key)
}
