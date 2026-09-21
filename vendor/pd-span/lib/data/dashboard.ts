import type { Client } from "@/lib/supabase/types"
import { toPersonSummary, type PersonSummary } from "@/lib/data/people"

export type RecentNote = {
  id: string
  body: string
  tags: string[]
  source: string | null
  confidence: string
  created_at: string
  person: { id: string; name: string | null; alias: string | null } | null
  organization: { id: string; name: string } | null
  case: { id: string; title: string } | null
  author: { callsign: string | null } | null
}

export type DashboardData =
  | {
      ok: true
      counts: { people: number; organizations: number; openCases: number; notesThisWeek: number }
      recentPeople: PersonSummary[]
      recentNotes: RecentNote[]
    }
  | { ok: false; error: string }

/**
 * Everything the landing page shows, in one parallel batch. Failures are
 * returned rather than thrown so the page can explain them (a missing
 * migration is the usual cause right after setup).
 */
export async function getDashboardData(supabase: Client): Promise<DashboardData> {
  const weekAgo = new Date(Date.now() - 7 * 86_400_000).toISOString()

  const [people, organizations, openCases, notesThisWeek, recentPeople, recentNotes] =
    await Promise.all([
      supabase.from("people").select("id", { count: "exact", head: true }),
      supabase.from("organizations").select("id", { count: "exact", head: true }),
      supabase.from("cases").select("id", { count: "exact", head: true }).eq("status", "open"),
      supabase.from("notes").select("id", { count: "exact", head: true }).gte("created_at", weekAgo),
      supabase
        .from("people_overview")
        .select("*")
        .order("created_at", { ascending: false })
        .limit(6),
      supabase
        .from("notes")
        .select(
          "id, body, tags, source, confidence, created_at, person:people(id, name, alias), organization:organizations(id, name), case:cases(id, title), author:profiles(callsign)"
        )
        .order("created_at", { ascending: false })
        .limit(6),
    ])

  const failure = [people, organizations, openCases, notesThisWeek, recentPeople, recentNotes].find(
    (r) => r.error
  )
  if (failure?.error) {
    return { ok: false, error: failure.error.message }
  }

  return {
    ok: true,
    counts: {
      people: people.count ?? 0,
      organizations: organizations.count ?? 0,
      openCases: openCases.count ?? 0,
      notesThisWeek: notesThisWeek.count ?? 0,
    },
    recentPeople: (recentPeople.data ?? []).map(toPersonSummary),
    recentNotes: (recentNotes.data ?? []) as RecentNote[],
  }
}
