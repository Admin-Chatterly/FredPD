"use server"

import { revalidatePath } from "next/cache"
import { redirect } from "next/navigation"
import { z } from "zod"
import type { ActionResult, FormState } from "@/lib/action-types"
import { requireUser } from "@/lib/auth"
import { ORGANIZATION_STATUSES, ORGANIZATION_TYPES } from "@/lib/constants"
import { firstIssue, optionalText, readFields, uuid } from "@/lib/form"
import { revalidateOrganization } from "@/lib/revalidate"
import { createClient } from "@/lib/supabase/server"

const organizationSchema = z.object({
  name: z.string().trim().min(1, "Ge organisationen ett namn.").max(200),
  type: z.enum(ORGANIZATION_TYPES).optional(),
  territory: optionalText,
  status: z.enum(ORGANIZATION_STATUSES).default("active"),
  notes: optionalText,
})

function parseOrganization(formData: FormData) {
  const fields = readFields(formData, ["name", "type", "territory", "status", "notes"])
  return organizationSchema.safeParse({
    ...fields,
    // "none" is the placeholder the type dropdown uses for an unknown type.
    type: fields.type && fields.type !== "none" ? fields.type : undefined,
  })
}

export async function createOrganization(_prev: FormState, formData: FormData): Promise<FormState> {
  await requireUser()
  const parsed = parseOrganization(formData)
  if (!parsed.success) return { error: firstIssue(parsed.error) }

  const supabase = await createClient()
  const { data, error } = await supabase
    .from("organizations")
    .insert({ ...parsed.data, type: parsed.data.type ?? null })
    .select("id")
    .single()
  if (error) return { error: error.message }

  revalidatePath("/organizations")
  revalidatePath("/")
  redirect(`/organizations/${data.id}`)
}

export async function updateOrganization(_prev: FormState, formData: FormData): Promise<FormState> {
  await requireUser()
  const id = uuid.safeParse(formData.get("id"))
  if (!id.success) return { error: "Organisations-id saknas." }
  const parsed = parseOrganization(formData)
  if (!parsed.success) return { error: firstIssue(parsed.error) }

  const supabase = await createClient()
  const { error } = await supabase
    .from("organizations")
    .update({ ...parsed.data, type: parsed.data.type ?? null })
    .eq("id", id.data)
  if (error) return { error: error.message }

  revalidateOrganization(id.data)
  return { ok: true, version: Date.now() }
}

export async function deleteOrganization(organizationId: string): Promise<ActionResult> {
  await requireUser()
  const id = uuid.safeParse(organizationId)
  if (!id.success) return { ok: false, error: "Ogiltigt id." }

  const supabase = await createClient()
  // Members keep their own records, and notes are detached rather than deleted
  // (see migration 0003), so only the organization itself goes.
  const { data: members } = await supabase
    .from("memberships")
    .select("person_id")
    .eq("organization_id", id.data)
  const { error } = await supabase.from("organizations").delete().eq("id", id.data)
  if (error) return { ok: false, error: error.message }

  for (const m of members ?? []) revalidatePath(`/people/${m.person_id}`)
  revalidatePath("/organizations")
  revalidatePath("/people")
  revalidatePath("/")
  redirect("/organizations")
}
