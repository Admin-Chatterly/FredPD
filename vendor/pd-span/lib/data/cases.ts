import { cache } from "react"
import type { Tables, Views } from "@/lib/database.types"
import { EVIDENCE_SELECT, signEvidence, type EvidenceRow } from "@/lib/data/evidence"
import { NOTE_SELECT, type NoteRow } from "@/lib/data/notes"
import type { Client } from "@/lib/supabase/types"

export type CaseSummary = {
  id: string
  title: string
  description: string | null
  status: string
  createdAt: string
  updatedAt: string
  peopleCount: number
  organizationCount: number
  lastNoteAt: string | null
  noteCount: number
}

export function toCaseSummary(row: Views<"cases_overview">): CaseSummary {
  if (!row.id) throw new Error("cases_overview row without id")
  return {
    id: row.id,
    title: row.title ?? "",
    description: row.description,
    status: row.status ?? "open",
    createdAt: row.created_at ?? new Date(0).toISOString(),
    updatedAt: row.updated_at ?? row.created_at ?? new Date(0).toISOString(),
    peopleCount: row.people_count ?? 0,
    organizationCount: row.organization_count ?? 0,
    lastNoteAt: row.last_note_at,
    noteCount: row.note_count ?? 0,
  }
}

export type CasesListResult = { ok: true; cases: CaseSummary[] } | { ok: false; error: string }

export async function listCases(supabase: Client): Promise<CasesListResult> {
  const { data, error } = await supabase
    .from("cases_overview")
    .select("*")
    .order("status", { ascending: false })
    .order("updated_at", { ascending: false })
    .limit(500)
  if (error) return { ok: false, error: error.message }
  return { ok: true, cases: (data ?? []).map(toCaseSummary) }
}

export type CaseLinkedRow = {
  id: string
  role: string | null
  person: { id: string; name: string | null; alias: string | null; description: string | null; status: string } | null
  organization: { id: string; name: string; type: string | null; status: string } | null
}

export type CaseDetail = {
  caseRecord: Tables<"cases">
  people: CaseLinkedRow[]
  organizations: CaseLinkedRow[]
  notes: NoteRow[]
  evidence: EvidenceRow[]
  /** Everything on file, so the link dialog can offer what is not linked yet. */
  organizationOptions: { id: string; name: string }[]
  createdBy: string | null
}

export const getCaseDetail = cache(async (supabase: Client, id: string): Promise<CaseDetail | null> => {
  if (!/^[0-9a-f-]{36}$/i.test(id)) return null

  const { data: caseRecord, error: caseError } = await supabase
    .from("cases")
    .select("*")
    .eq("id", id)
    .maybeSingle()
  if (caseError) throw new Error(caseError.message)
  if (!caseRecord) return null

  const [links, notes, evidence, organizationOptions, creator] = await Promise.all([
    supabase
      .from("case_links")
      .select(
        "id, role, person:people(id, name, alias, description, status), organization:organizations(id, name, type, status)"
      )
      .eq("case_id", id)
      .order("created_at", { ascending: true }),
    supabase.from("notes").select(NOTE_SELECT).eq("case_id", id).order("created_at", { ascending: false }),
    supabase.from("evidence").select(EVIDENCE_SELECT).eq("case_id", id).order("created_at", { ascending: false }),
    supabase.from("organizations").select("id, name").order("name").limit(500),
    caseRecord.created_by
      ? supabase.from("profiles").select("callsign").eq("id", caseRecord.created_by).maybeSingle()
      : Promise.resolve({ data: null, error: null }),
  ])

  const failure = [links, notes, evidence, organizationOptions].find((r) => r.error)
  if (failure?.error) throw new Error(failure.error.message)

  const rows = (links.data ?? []) as unknown as CaseLinkedRow[]
  return {
    caseRecord,
    people: rows.filter((r) => r.person),
    organizations: rows.filter((r) => r.organization),
    notes: (notes.data ?? []) as unknown as NoteRow[],
    evidence: await signEvidence(supabase, (evidence.data ?? []) as unknown as EvidenceRow[]),
    organizationOptions: organizationOptions.data ?? [],
    createdBy: creator.data?.callsign ?? null,
  }
})
