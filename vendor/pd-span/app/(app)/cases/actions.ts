"use server"

import { revalidatePath } from "next/cache"
import { redirect } from "next/navigation"
import { z } from "zod"
import type { ActionResult, FormState } from "@/lib/action-types"
import { requireUser } from "@/lib/auth"
import { CASE_STATUSES } from "@/lib/constants"
import { firstIssue, optionalText, readFields, uuid } from "@/lib/form"
import { revalidateCase, revalidateOrganization, revalidatePerson } from "@/lib/revalidate"
import { createClient } from "@/lib/supabase/server"

const caseSchema = z.object({
  title: z.string().trim().min(1, "Ge ärendet en titel.").max(200),
  description: optionalText,
  status: z.enum(CASE_STATUSES).default("open"),
})

function parseCase(formData: FormData) {
  const fields = readFields(formData, ["title", "description", "status"])
  return caseSchema.safeParse({ ...fields, title: fields.title ?? "" })
}

export async function createCase(_prev: FormState, formData: FormData): Promise<FormState> {
  await requireUser()
  const parsed = parseCase(formData)
  if (!parsed.success) return { error: firstIssue(parsed.error) }

  const supabase = await createClient()
  const { data, error } = await supabase.from("cases").insert(parsed.data).select("id").single()
  if (error) return { error: error.message }

  revalidatePath("/cases")
  revalidatePath("/")
  redirect(`/cases/${data.id}`)
}

export async function updateCase(_prev: FormState, formData: FormData): Promise<FormState> {
  await requireUser()
  const id = uuid.safeParse(formData.get("id"))
  if (!id.success) return { error: "Ärende-id saknas." }
  const parsed = parseCase(formData)
  if (!parsed.success) return { error: firstIssue(parsed.error) }

  const supabase = await createClient()
  const { error } = await supabase.from("cases").update(parsed.data).eq("id", id.data)
  if (error) return { error: error.message }

  revalidateCase(id.data)
  return { ok: true, version: Date.now() }
}

export async function updateCaseStatus(caseId: string, status: string): Promise<ActionResult> {
  await requireUser()
  const parsed = z.object({ id: uuid, status: z.enum(CASE_STATUSES) }).safeParse({ id: caseId, status })
  if (!parsed.success) return { ok: false, error: "Ogiltig status." }

  const supabase = await createClient()
  const { error } = await supabase
    .from("cases")
    .update({ status: parsed.data.status })
    .eq("id", parsed.data.id)
  if (error) return { ok: false, error: error.message }

  revalidateCase(parsed.data.id)
  return { ok: true }
}

export async function deleteCase(caseId: string): Promise<ActionResult> {
  await requireUser()
  const id = uuid.safeParse(caseId)
  if (!id.success) return { ok: false, error: "Ogiltigt id." }

  const supabase = await createClient()
  // The people and organizations survive; only the links and the case itself go.
  // Notes detach rather than disappear, so the intel outlives the investigation.
  const { data: links } = await supabase
    .from("case_links")
    .select("person_id, organization_id")
    .eq("case_id", id.data)
  const { error } = await supabase.from("cases").delete().eq("id", id.data)
  if (error) return { ok: false, error: error.message }

  for (const link of links ?? []) {
    if (link.person_id) revalidatePath(`/people/${link.person_id}`)
    if (link.organization_id) revalidatePath(`/organizations/${link.organization_id}`)
  }
  revalidatePath("/cases")
  revalidatePath("/intel")
  revalidatePath("/")
  redirect("/cases")
}

/**
 * A case link points at exactly one of a person or an organization, which the
 * database enforces. Both sides show the link, so both are refreshed.
 */
const caseLinkSchema = z
  .object({
    case_id: uuid,
    person_id: uuid.optional(),
    organization_id: uuid.optional(),
    role: optionalText,
  })
  .refine((v) => Boolean(v.person_id) !== Boolean(v.organization_id), {
    message: "Välj antingen en person eller en organisation.",
  })

export async function addCaseLink(_prev: FormState, formData: FormData): Promise<FormState> {
  await requireUser()
  const parsed = caseLinkSchema.safeParse(
    readFields(formData, ["case_id", "person_id", "organization_id", "role"])
  )
  if (!parsed.success) return { error: firstIssue(parsed.error, "Välj något att koppla.") }

  const supabase = await createClient()
  const { error } = await supabase.from("case_links").insert({
    case_id: parsed.data.case_id,
    person_id: parsed.data.person_id ?? null,
    organization_id: parsed.data.organization_id ?? null,
    role: parsed.data.role,
  })
  if (error) {
    return { error: error.code === "23505" ? "Det är redan kopplat till ärendet." : error.message }
  }

  revalidateCase(parsed.data.case_id)
  if (parsed.data.person_id) revalidatePerson(parsed.data.person_id)
  if (parsed.data.organization_id) revalidateOrganization(parsed.data.organization_id)
  return { ok: true, version: Date.now() }
}

export async function removeCaseLink(linkId: string): Promise<ActionResult> {
  await requireUser()
  const id = uuid.safeParse(linkId)
  if (!id.success) return { ok: false, error: "Ogiltigt id." }

  const supabase = await createClient()
  // Read the targets first so both sides of the link get refreshed.
  const { data: link } = await supabase
    .from("case_links")
    .select("case_id, person_id, organization_id")
    .eq("id", id.data)
    .maybeSingle()
  const { error } = await supabase.from("case_links").delete().eq("id", id.data)
  if (error) return { ok: false, error: error.message }

  if (link?.case_id) revalidateCase(link.case_id)
  if (link?.person_id) revalidatePerson(link.person_id)
  if (link?.organization_id) revalidateOrganization(link.organization_id)
  return { ok: true }
}
