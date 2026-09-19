"use server"

import { requireUser } from "@/lib/auth"
import { createClient } from "@/lib/supabase/server"

export type SearchHit = {
  kind: string
  id: string
  title: string
  subtitle: string | null
  status: string | null
  score: number
  /** The record a result belongs to, for kinds with no page of their own. */
  parentKind: string | null
  parentId: string | null
}

/**
 * One round trip across people, organizations, vehicles, notes and cases. The
 * ranking and the per-kind caps live in the search_all function, so the client
 * only has to group what comes back.
 */
export async function globalSearch(term: string): Promise<SearchHit[]> {
  await requireUser()
  const clean = term.trim()
  if (clean.length < 2) return []

  const supabase = await createClient()
  const { data, error } = await supabase.rpc("search_all", { term: clean, per_type: 6 })
  if (error) return []

  return (data ?? []).map((row) => ({
    kind: row.kind,
    id: row.id,
    title: row.title,
    subtitle: row.subtitle,
    status: row.status,
    score: row.score,
    parentKind: row.parent_kind,
    parentId: row.parent_id,
  }))
}
