import { uuidList } from "@/lib/data/filters"
import type { Tables } from "@/lib/database.types"
import type { Client } from "@/lib/supabase/types"

/** A note with every relation the feed might link to. Embeds not selected come back undefined. */
export type NoteRow = Tables<"notes"> & {
  author: { callsign: string | null } | null
  person?: { id: string; name: string | null; alias: string | null } | null
  organization?: { id: string; name: string } | null
  case?: { id: string; title: string } | null
}

export const NOTE_SELECT =
  "*, author:profiles(callsign), person:people(id, name, alias), organization:organizations(id, name), case:cases(id, title)"

/**
 * Notes are the only place tags live, so every tag filter in the app resolves
 * through here.
 */
export async function listTags(supabase: Client): Promise<{ tag: string; uses: number }[]> {
  const { data, error } = await supabase.rpc("distinct_tags")
  if (error) return []
  return data ?? []
}

export async function listTagSuggestions(supabase: Client): Promise<string[]> {
  return (await listTags(supabase)).map((t) => t.tag).slice(0, 50)
}

/**
 * Ids of the people or organizations that have at least one note carrying a
 * tag. Both columns are selected so the row type stays concrete whichever one
 * is being filtered on.
 */
export async function idsTaggedWith(
  supabase: Client,
  tag: string,
  column: "person_id" | "organization_id"
): Promise<string[]> {
  const { data, error } = await supabase
    .from("notes")
    .select("person_id, organization_id")
    .contains("tags", [tag])
    .not(column, "is", null)
    .limit(1000)
  if (error) return []
  return uuidList((data ?? []).map((row) => row[column]))
}

/** "General intel" is a note tied to nobody: the tip that has not been placed yet. */
export const NOTE_ATTACHMENTS = ["any", "general", "attached"] as const
export type NoteAttachment = (typeof NOTE_ATTACHMENTS)[number]

export const NOTE_ATTACHMENT_LABELS: Record<NoteAttachment, string> = {
  any: "Allt",
  general: "Endast allmänna uppgifter",
  attached: "Kopplat till en post",
}

export type NotesListParams = {
  q?: string
  tag?: string
  source?: string
  confidence?: string
  attachment?: NoteAttachment
}

export type NotesListResult =
  | { ok: true; notes: NoteRow[]; total: number }
  | { ok: false; error: string }

export async function listNotes(
  supabase: Client,
  params: NotesListParams
): Promise<NotesListResult> {
  let query = supabase.from("notes").select(NOTE_SELECT, { count: "exact" })

  const term = params.q?.trim()
  if (term) query = query.ilike("body", `%${term}%`)
  if (params.tag) query = query.contains("tags", [params.tag])
  if (params.source) query = query.eq("source", params.source)
  if (params.confidence) query = query.eq("confidence", params.confidence)

  if (params.attachment === "general") {
    query = query.is("person_id", null).is("organization_id", null).is("case_id", null)
  } else if (params.attachment === "attached") {
    query = query.or(
      "person_id.not.is.null,organization_id.not.is.null,case_id.not.is.null"
    )
  }

  const { data, error, count } = await query
    .order("created_at", { ascending: false })
    .limit(200)
  if (error) return { ok: false, error: error.message }
  return { ok: true, notes: (data ?? []) as unknown as NoteRow[], total: count ?? data?.length ?? 0 }
}

export type NoteTargetOptions = {
  organizations: { id: string; name: string }[]
  cases: { id: string; title: string; status: string }[]
}

/** Options for the composer's optional person, organization and case pickers. */
export async function listNoteTargets(supabase: Client): Promise<NoteTargetOptions> {
  const [organizations, cases] = await Promise.all([
    supabase.from("organizations").select("id, name").order("name").limit(500),
    supabase
      .from("cases")
      .select("id, title, status")
      .order("status")
      .order("updated_at", { ascending: false })
      .limit(500),
  ])
  return {
    organizations: organizations.data ?? [],
    cases: cases.data ?? [],
  }
}
