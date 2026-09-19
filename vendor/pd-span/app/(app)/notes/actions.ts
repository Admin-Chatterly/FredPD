"use server"

import { revalidatePath } from "next/cache"
import { z } from "zod"
import type { ActionResult, FormState } from "@/lib/action-types"
import { requireUser } from "@/lib/auth"
import { CONFIDENCES, NOTE_SOURCES } from "@/lib/constants"
import { listNoteTargets, listTagSuggestions, type NoteTargetOptions } from "@/lib/data/notes"
import { firstIssue, readFields, uuid } from "@/lib/form"
import { revalidateCase, revalidateOrganization, revalidatePerson } from "@/lib/revalidate"
import { createClient } from "@/lib/supabase/server"

/**
 * A note can hang off a person, an organization, a case, any combination, or
 * nothing at all. The last case is the point: a tip arrives before anyone knows
 * who it is about, and it still has to be recorded somewhere.
 */
const noteSchema = z.object({
  person_id: uuid.optional(),
  organization_id: uuid.optional(),
  case_id: uuid.optional(),
  body: z.string().trim().min(1, "Skriv uppgiften först.").max(10000),
  source: z.enum(NOTE_SOURCES).optional(),
  confidence: z.enum(CONFIDENCES).default("medium"),
})

type NoteTargets = {
  person_id?: string | null
  organization_id?: string | null
  case_id?: string | null
}

function revalidateTargets(targets: NoteTargets) {
  if (targets.person_id) revalidatePerson(targets.person_id)
  if (targets.organization_id) revalidateOrganization(targets.organization_id)
  if (targets.case_id) revalidateCase(targets.case_id)
  revalidatePath("/intel")
  revalidatePath("/")
}

/** Tags are free text, but normalised so the filters actually match. */
function parseTags(value: string | undefined): string[] {
  if (!value) return []
  return Array.from(
    new Set(
      value
        .split(/[,\n]/)
        .map((t) => t.trim().toLowerCase().replace(/^#/, ""))
        .filter(Boolean)
    )
  )
}

export async function addNote(_prev: FormState, formData: FormData): Promise<FormState> {
  await requireUser()
  const fields = readFields(formData, [
    "person_id",
    "organization_id",
    "case_id",
    "body",
    "source",
    "confidence",
    "tags",
  ])
  // "none" is the placeholder every optional select submits; it is not a value
  // the database knows about.
  const pick = (value: string | undefined) => (value && value !== "none" ? value : undefined)
  const parsed = noteSchema.safeParse({
    person_id: pick(fields.person_id),
    organization_id: pick(fields.organization_id),
    case_id: pick(fields.case_id),
    body: fields.body ?? "",
    source: pick(fields.source),
    confidence: fields.confidence ?? undefined,
  })
  if (!parsed.success) return { error: firstIssue(parsed.error) }

  const targets: NoteTargets = {
    person_id: parsed.data.person_id ?? null,
    organization_id: parsed.data.organization_id ?? null,
    case_id: parsed.data.case_id ?? null,
  }

  const supabase = await createClient()
  const { error } = await supabase.from("notes").insert({
    ...targets,
    body: parsed.data.body,
    tags: parseTags(fields.tags),
    source: parsed.data.source ?? null,
    confidence: parsed.data.confidence,
  })
  if (error) return { error: error.message }

  revalidateTargets(targets)
  return { ok: true, version: Date.now() }
}

export async function deleteNote(noteId: string): Promise<ActionResult> {
  await requireUser()
  const id = uuid.safeParse(noteId)
  if (!id.success) return { ok: false, error: "Ogiltigt id." }

  const supabase = await createClient()
  // Read the targets first so the pages the note appeared on are refreshed too.
  const { data: note } = await supabase
    .from("notes")
    .select("person_id, organization_id, case_id")
    .eq("id", id.data)
    .maybeSingle()
  const { error } = await supabase.from("notes").delete().eq("id", id.data)
  if (error) return { ok: false, error: error.message }

  revalidateTargets(note ?? {})
  return { ok: true }
}

export type ComposerOptions = NoteTargetOptions & { tagSuggestions: string[] }

/**
 * Fetched when the quick-add dialog opens rather than on every page render, so
 * the header costs nothing until it is used.
 */
export async function getComposerOptions(): Promise<ComposerOptions> {
  await requireUser()
  const supabase = await createClient()
  const [targets, tagSuggestions] = await Promise.all([
    listNoteTargets(supabase),
    listTagSuggestions(supabase),
  ])
  return { ...targets, tagSuggestions }
}
