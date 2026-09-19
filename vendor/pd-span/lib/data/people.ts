import { cache } from "react"
import type { Tables, Views } from "@/lib/database.types"
import { EVIDENCE_SELECT, signEvidence, type EvidenceRow } from "@/lib/data/evidence"
import { isUuid, likePattern, uuidList } from "@/lib/data/filters"
import { idsTaggedWith, NOTE_SELECT, type NoteRow } from "@/lib/data/notes"
import { signPaths } from "@/lib/data/storage"
import { parseAffiliations, type OrganizationAffiliation } from "@/lib/format"
import type { Client } from "@/lib/supabase/types"

/** A row of the people_overview view with the nullability the view cannot express removed. */
export type PersonSummary = {
  id: string
  name: string | null
  alias: string | null
  description: string | null
  status: string
  photoPath: string | null
  photoUrl: string | null
  createdAt: string
  updatedAt: string
  organizations: OrganizationAffiliation[]
  lastNoteAt: string | null
  noteCount: number
  plates: string[]
}

export function toPersonSummary(row: Views<"people_overview">): PersonSummary {
  if (!row.id) throw new Error("people_overview row without id")
  return {
    id: row.id,
    name: row.name,
    alias: row.alias,
    description: row.description,
    status: row.status ?? "unknown",
    photoPath: row.photo_path,
    photoUrl: null,
    createdAt: row.created_at ?? new Date(0).toISOString(),
    updatedAt: row.updated_at ?? row.created_at ?? new Date(0).toISOString(),
    organizations: parseAffiliations(row.organizations),
    lastNoteAt: row.last_note_at,
    noteCount: row.note_count ?? 0,
    plates: row.plates ?? [],
  }
}

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

export const PEOPLE_SORTS = ["updated", "name", "added", "last_note"] as const
export type PeopleSort = (typeof PEOPLE_SORTS)[number]

export type PeopleListParams = {
  q?: string
  status?: string
  sort?: PeopleSort
  /** Everyone with at least one note carrying this tag. */
  tag?: string
}

export type PeopleListResult =
  | { ok: true; people: PersonSummary[]; total: number }
  | { ok: false; error: string }

function normalizePlate(term: string): string {
  return term.replace(/[^A-Za-z0-9]/g, "").toUpperCase()
}

export async function listPeople(supabase: Client, params: PeopleListParams): Promise<PeopleListResult> {
  const term = params.q?.trim() ?? ""

  let query = supabase.from("people_overview").select("*", { count: "exact" })

  if (term) {
    const pattern = likePattern(term)
    const filters = [`name.ilike.${pattern}`, `alias.ilike.${pattern}`, `description.ilike.${pattern}`]

    // Partial plates: look up owners of matching vehicles and include them.
    const plate = normalizePlate(term)
    if (plate.length >= 2) {
      const { data: vehicles } = await supabase
        .from("vehicles")
        .select("person_id")
        .not("person_id", "is", null)
        .ilike("plate", `%${plate}%`)
        .limit(200)
      const ids = uuidList((vehicles ?? []).map((v) => v.person_id))
      if (ids.length > 0) filters.push(`id.in.(${ids.join(",")})`)
    }
    query = query.or(filters.join(","))
  }

  if (params.status) {
    query = query.eq("status", params.status)
  }

  if (params.tag) {
    const ids = await idsTaggedWith(supabase, params.tag, "person_id")
    if (ids.length === 0) return { ok: true, people: [], total: 0 }
    query = query.in("id", ids)
  }

  switch (params.sort ?? "updated") {
    case "name":
      query = query.order("display_name", { ascending: true }).order("created_at", { ascending: false })
      break
    case "added":
      query = query.order("created_at", { ascending: false })
      break
    case "last_note":
      query = query
        .order("last_note_at", { ascending: false, nullsFirst: false })
        .order("updated_at", { ascending: false })
      break
    default:
      query = query.order("updated_at", { ascending: false })
  }

  const { data, error, count } = await query.limit(500)
  if (error) return { ok: false, error: error.message }

  const people = (data ?? []).map(toPersonSummary)
  // One storage call for the whole page, and none at all when nobody has a photo.
  const byPath = await signPaths(supabase, people.map((p) => p.photoPath))
  return {
    ok: true,
    people: people.map((p) => (p.photoPath ? { ...p, photoUrl: byPath.get(p.photoPath) ?? null } : p)),
    total: count ?? data?.length ?? 0,
  }
}

// ---------------------------------------------------------------------------
// Picker search (associates, merge)
// ---------------------------------------------------------------------------

export type PersonPick = {
  id: string
  name: string | null
  alias: string | null
  description: string | null
  status: string
}

export async function searchPeople(supabase: Client, term: string, excludeIds: string[] = []): Promise<PersonPick[]> {
  const clean = term.trim()
  let query = supabase
    .from("people")
    .select("id, name, alias, description, status")
    .order("updated_at", { ascending: false })
    .limit(12)

  if (clean) {
    const pattern = likePattern(clean)
    query = query.or(`name.ilike.${pattern},alias.ilike.${pattern},description.ilike.${pattern}`)
  }
  const valid = uuidList(excludeIds)
  if (valid.length > 0) {
    query = query.not("id", "in", `(${valid.join(",")})`)
  }

  const { data, error } = await query
  if (error) return []
  return data ?? []
}

// ---------------------------------------------------------------------------
// Detail
// ---------------------------------------------------------------------------

export type MembershipRow = {
  role: string | null
  is_confirmed: boolean
  created_at: string
  organization: { id: string; name: string; type: string | null; status: string }
}

export type AssociateRow = {
  relationship: string | null
  is_confirmed: boolean
  created_at: string
  other: { id: string; name: string | null; alias: string | null; description: string | null; status: string }
}

export type CaseLinkRow = {
  id: string
  role: string | null
  case: { id: string; title: string; status: string }
}

export type OrganizationOption = { id: string; name: string; type: string | null }

export type PersonDetail = {
  person: Tables<"people">
  /** Signed for this request; null when there is no photo or signing failed. */
  photoUrl: string | null
  memberships: MembershipRow[]
  associates: AssociateRow[]
  vehicles: Tables<"vehicles">[]
  notes: NoteRow[]
  caseLinks: CaseLinkRow[]
  evidence: EvidenceRow[]
  organizationOptions: OrganizationOption[]
  createdBy: string | null
}

type RawAssociate = {
  person_id: string
  associate_id: string
  relationship: string | null
  is_confirmed: boolean
  created_at: string
  a: AssociateRow["other"] | null
  b: AssociateRow["other"] | null
}

/** Everything the person page needs. Memoised per request so metadata and page share one fetch. */
export const getPersonDetail = cache(async (supabase: Client, id: string): Promise<PersonDetail | null> => {
  if (!isUuid(id)) return null

  const { data: person, error: personError } = await supabase
    .from("people")
    .select("*")
    .eq("id", id)
    .maybeSingle()
  if (personError) throw new Error(personError.message)
  if (!person) return null

  const [memberships, associates, vehicles, notes, caseLinks, evidence, organizations, creator] =
    await Promise.all([
      supabase
        .from("memberships")
        .select("role, is_confirmed, created_at, organization:organizations(id, name, type, status)")
        .eq("person_id", id)
        .order("created_at", { ascending: true }),
      supabase
        .from("associates")
        .select(
          "person_id, associate_id, relationship, is_confirmed, created_at, a:people!associates_person_id_fkey(id, name, alias, description, status), b:people!associates_associate_id_fkey(id, name, alias, description, status)"
        )
        .or(`person_id.eq.${id},associate_id.eq.${id}`),
      supabase.from("vehicles").select("*").eq("person_id", id).order("created_at", { ascending: true }),
      supabase
        .from("notes")
        .select(NOTE_SELECT)
        .eq("person_id", id)
        .order("created_at", { ascending: false }),
      supabase
        .from("case_links")
        .select("id, role, case:cases(id, title, status)")
        .eq("person_id", id),
      supabase
        .from("evidence")
        .select(EVIDENCE_SELECT)
        .eq("person_id", id)
        .order("created_at", { ascending: false }),
      supabase.from("organizations").select("id, name, type").order("name"),
      person.created_by
        ? supabase.from("profiles").select("callsign").eq("id", person.created_by).maybeSingle()
        : Promise.resolve({ data: null, error: null }),
    ])

  const failure = [memberships, associates, vehicles, notes, caseLinks, evidence, organizations].find(
    (r) => r.error
  )
  if (failure?.error) throw new Error(failure.error.message)

  const associateRows: AssociateRow[] = ((associates.data ?? []) as unknown as RawAssociate[]).flatMap(
    (row) => {
      const other = row.person_id === id ? row.b : row.a
      if (!other) return []
      return [
        {
          relationship: row.relationship,
          is_confirmed: row.is_confirmed,
          created_at: row.created_at,
          other,
        },
      ]
    }
  )

  const photoUrl = person.photo_path
    ? ((await signPaths(supabase, [person.photo_path])).get(person.photo_path) ?? null)
    : null

  return {
    person,
    photoUrl,
    memberships: ((memberships.data ?? []) as unknown as MembershipRow[]).filter((m) => m.organization),
    associates: associateRows,
    vehicles: vehicles.data ?? [],
    notes: (notes.data ?? []) as unknown as NoteRow[],
    caseLinks: ((caseLinks.data ?? []) as unknown as CaseLinkRow[]).filter((l) => l.case),
    evidence: await signEvidence(supabase, (evidence.data ?? []) as unknown as EvidenceRow[]),
    organizationOptions: organizations.data ?? [],
    createdBy: creator.data?.callsign ?? null,
  }
})
