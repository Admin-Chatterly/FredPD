import type { SupabaseClient } from "@supabase/supabase-js"
import type { Database } from "@/lib/database.types"

/** A typed Supabase client, whichever side (server, browser, or test) created it. */
export type Client = SupabaseClient<Database>
