import { cache } from "react"
import type { Tables, Views } from "@/lib/database.types"
import { EVIDENCE_SELECT, signEvidence, type EvidenceRow } from "@/lib/data/evidence"
import { idsTaggedWith, NOTE_SELECT, type NoteRow } from "@/lib/data/notes"
import type { Client } from "@/lib/supabase/types"

export type OrganizationSummary = {
  id: string
  name: string
  type: string | null
  territory: string | null
  status: string
  notes: string | null
  createdAt: string
  updatedAt: string
  memberCount: number
  confirmedMemberCount: number
  lastNoteAt: string | null
  noteCount: number
}

export function toOrganizationSummary(row: Views<"organizations_overview">): OrganizationSummary {
  if (!row.id) throw new Error("organizations_overview row without id")
  return {
    id: row.id,
    name: row.name ?? "",
    type: row.type,
    territory: row.territory,
    status: row.status ?? "active",
    notes: row.notes,
    createdAt: row.created_at ?? new Date(0).toISOString(),
    updatedAt: row.updated_at ?? row.created_at ?? new Date(0).toISOString(),
    memberCount: row.member_count ?? 0,
    confirmedMemberCount: row.confirmed_member_count ?? 0,
    lastNoteAt: row.last_note_at,
    noteCount: row.note_count ?? 0,
  }
}

export type OrganizationsListResult =
  | { ok: true; organizations: OrganizationSummary[] }
  | { ok: false; error: string }

export async function listOrganizations(
  supabase: Client,
  params: { tag?: string } = {}
): Promise<OrganizationsListResult> {
  let query = supabase
    .from("organizations_overview")
    .select("*")
    .order("status", { ascending: true })
    .order("name", { ascending: true })
    .limit(500)

  if (params.tag) {
    const ids = await idsTaggedWith(supabase, params.tag, "organization_id")
    if (ids.length === 0) return { ok: true, organizations: [] }
    query = query.in("id", ids)
  }

  const { data, error } = await query
  if (error) return { ok: false, error: error.message }
  return { ok: true, organizations: (data ?? []).map(toOrganizationSummary) }
}

export type MemberRow = {
  role: string | null
  is_confirmed: boolean
  created_at: string
  person: { id: string; name: string | null; alias: string | null; description: string | null; status: string }
}

export type OrganizationCaseLinkRow = {
  id: string
  role: string | null
  case: { id: string; title: string; status: string }
}

export type OrganizationDetail = {
  organization: Tables<"organizations">
  members: MemberRow[]
  notes: NoteRow[]
  caseLinks: OrganizationCaseLinkRow[]
  evidence: EvidenceRow[]
  createdBy: string | null
}

export const getOrganizationDetail = cache(
  async (supabase: Client, id: string): Promise<OrganizationDetail | null> => {
    if (!/^[0-9a-f-]{36}$/i.test(id)) return null

    const { data: organization, error: orgError } = await supabase
      .from("organizations")
      .select("*")
      .eq("id", id)
      .maybeSingle()
    if (orgError) throw new Error(orgError.message)
    if (!organization) return null

    const [members, notes, caseLinks, evidence, creator] = await Promise.all([
      supabase
        .from("memberships")
        .select("role, is_confirmed, created_at, person:people(id, name, alias, description, status)")
        .eq("organization_id", id)
        .order("is_confirmed", { ascending: false })
        .order("created_at", { ascending: true }),
      supabase
        .from("notes")
        .select(NOTE_SELECT)
        .eq("organization_id", id)
        .order("created_at", { ascending: false }),
      supabase.from("case_links").select("id, role, case:cases(id, title, status)").eq("organization_id", id),
      supabase
        .from("evidence")
        .select(EVIDENCE_SELECT)
        .eq("organization_id", id)
        .order("created_at", { ascending: false }),
      organization.created_by
        ? supabase.from("profiles").select("callsign").eq("id", organization.created_by).maybeSingle()
        : Promise.resolve({ data: null, error: null }),
    ])

    const failure = [members, notes, caseLinks, evidence].find((r) => r.error)
    if (failure?.error) throw new Error(failure.error.message)

    return {
      organization,
      members: ((members.data ?? []) as unknown as MemberRow[]).filter((m) => m.person),
      notes: (notes.data ?? []) as unknown as NoteRow[],
      caseLinks: ((caseLinks.data ?? []) as unknown as OrganizationCaseLinkRow[]).filter((l) => l.case),
      evidence: await signEvidence(supabase, (evidence.data ?? []) as unknown as EvidenceRow[]),
      createdBy: creator.data?.callsign ?? null,
    }
  }
)
