"use server"

import { revalidatePath } from "next/cache"
import { z } from "zod"
import type { ActionResult, FormState } from "@/lib/action-types"
import { requireUser } from "@/lib/auth"
import { STORAGE_BUCKET } from "@/lib/constants"
import { firstIssue, optionalText, readFields, uuid } from "@/lib/form"
import { isSafeStoragePath } from "@/lib/upload"
import { revalidateCase, revalidateOrganization, revalidatePerson } from "@/lib/revalidate"
import { createClient } from "@/lib/supabase/server"

const targets = {
  person_id: uuid.optional(),
  organization_id: uuid.optional(),
  case_id: uuid.optional(),
}

const linkSchema = z.object({
  ...targets,
  url: z
    .string()
    .trim()
    .max(2000)
    .refine((v) => /^https?:\/\/\S+$/i.test(v), "Klistra in en fullständig http(s)-länk."),
  caption: optionalText,
})

/** Written by the browser upload; the file is already in the bucket by then. */
const fileSchema = z.object({
  ...targets,
  storage_path: z
    .string()
    .trim()
    .min(1)
    .max(500)
    .refine(isSafeStoragePath, "Den uppladdningssökvägen är inte en som appen skriver till."),
  caption: optionalText,
})

type Targets = {
  person_id?: string | null
  organization_id?: string | null
  case_id?: string | null
}

function revalidateTargets(t: Targets) {
  if (t.person_id) revalidatePerson(t.person_id)
  if (t.organization_id) revalidateOrganization(t.organization_id)
  if (t.case_id) revalidateCase(t.case_id)
}

function hasTarget(t: Targets): boolean {
  return Boolean(t.person_id || t.organization_id || t.case_id)
}

/** Attach an external link (Medal.tv clip, YouTube, Streamable, image URL) as evidence. */
export async function addEvidenceLink(_prev: FormState, formData: FormData): Promise<FormState> {
  await requireUser()
  const parsed = linkSchema.safeParse(
    readFields(formData, ["person_id", "organization_id", "case_id", "url", "caption"])
  )
  if (!parsed.success) return { error: firstIssue(parsed.error, "Ogiltig länk.") }
  if (!hasTarget(parsed.data)) return { error: "Det finns inget att bifoga beviset till." }

  const supabase = await createClient()
  const { error } = await supabase.from("evidence").insert({
    person_id: parsed.data.person_id ?? null,
    organization_id: parsed.data.organization_id ?? null,
    case_id: parsed.data.case_id ?? null,
    url: parsed.data.url,
    caption: parsed.data.caption,
  })
  if (error) return { error: error.message }

  revalidateTargets(parsed.data)
  return { ok: true, version: Date.now() }
}

/**
 * Records a file the browser has already uploaded straight to Storage. The file
 * never passes through the server, which keeps large images clear of the
 * request body limit.
 */
export async function addEvidenceFile(_prev: FormState, formData: FormData): Promise<FormState> {
  await requireUser()
  const parsed = fileSchema.safeParse(
    readFields(formData, ["person_id", "organization_id", "case_id", "storage_path", "caption"])
  )
  if (!parsed.success) return { error: firstIssue(parsed.error, "Ogiltig uppladdning.") }
  if (!hasTarget(parsed.data)) return { error: "Det finns inget att bifoga beviset till." }

  const supabase = await createClient()
  const { error } = await supabase.from("evidence").insert({
    person_id: parsed.data.person_id ?? null,
    organization_id: parsed.data.organization_id ?? null,
    case_id: parsed.data.case_id ?? null,
    storage_path: parsed.data.storage_path,
    caption: parsed.data.caption,
  })
  if (error) {
    // The row is what makes the file findable, so an orphan is worse than none.
    await supabase.storage.from(STORAGE_BUCKET).remove([parsed.data.storage_path])
    return { error: error.message }
  }

  revalidateTargets(parsed.data)
  return { ok: true, version: Date.now() }
}

export async function deleteEvidence(evidenceId: string): Promise<ActionResult> {
  await requireUser()
  const id = uuid.safeParse(evidenceId)
  if (!id.success) return { ok: false, error: "Ogiltigt id." }

  const supabase = await createClient()
  const { data: row } = await supabase
    .from("evidence")
    .select("person_id, organization_id, case_id, storage_path")
    .eq("id", id.data)
    .maybeSingle()
  const { error } = await supabase.from("evidence").delete().eq("id", id.data)
  if (error) return { ok: false, error: error.message }

  // Drop the file too, so deleted evidence does not linger in the bucket.
  if (row?.storage_path) {
    await supabase.storage.from(STORAGE_BUCKET).remove([row.storage_path])
  }
  if (row) revalidateTargets(row)
  revalidatePath("/")
  return { ok: true }
}
