"use server"

import { z } from "zod"
import type { ActionResult, FormState } from "@/lib/action-types"
import { requireUser } from "@/lib/auth"
import { firstIssue, optionalText, readCheckbox, readFields, uuid } from "@/lib/form"
import { revalidateOrganization, revalidatePerson } from "@/lib/revalidate"
import { createClient } from "@/lib/supabase/server"

/**
 * A membership belongs to both a person and an organization, and is managed
 * from either page, so every action here refreshes both sides.
 */
const membershipSchema = z.object({
  person_id: uuid,
  organization_id: uuid,
  role: optionalText,
  is_confirmed: z.boolean(),
})

const pairSchema = z.object({ person_id: uuid, organization_id: uuid })

function revalidateBoth(personId: string, organizationId: string) {
  revalidatePerson(personId)
  revalidateOrganization(organizationId)
}

export async function addMembership(_prev: FormState, formData: FormData): Promise<FormState> {
  await requireUser()
  const parsed = membershipSchema.safeParse({
    ...readFields(formData, ["person_id", "organization_id", "role"]),
    is_confirmed: readCheckbox(formData, "is_confirmed"),
  })
  if (!parsed.success) return { error: "Välj både en person och en organisation." }

  const supabase = await createClient()
  const { error } = await supabase.from("memberships").insert(parsed.data)
  if (error) {
    return { error: error.code === "23505" ? "Det medlemskapet finns redan." : error.message }
  }

  revalidateBoth(parsed.data.person_id, parsed.data.organization_id)
  return { ok: true, version: Date.now() }
}

/** Edits an existing membership's role and confirmed flag together. */
export async function updateMembership(_prev: FormState, formData: FormData): Promise<FormState> {
  await requireUser()
  const parsed = membershipSchema.safeParse({
    ...readFields(formData, ["person_id", "organization_id", "role"]),
    is_confirmed: readCheckbox(formData, "is_confirmed"),
  })
  if (!parsed.success) return { error: firstIssue(parsed.error) }
  const { person_id, organization_id, role, is_confirmed } = parsed.data

  const supabase = await createClient()
  const { error } = await supabase
    .from("memberships")
    .update({ role, is_confirmed })
    .eq("person_id", person_id)
    .eq("organization_id", organization_id)
  if (error) return { error: error.message }

  revalidateBoth(person_id, organization_id)
  return { ok: true, version: Date.now() }
}

/** One-click suspected/confirmed toggle. */
export async function setMembershipConfirmed(
  personId: string,
  organizationId: string,
  isConfirmed: boolean
): Promise<ActionResult> {
  await requireUser()
  const parsed = pairSchema.safeParse({ person_id: personId, organization_id: organizationId })
  if (!parsed.success) return { ok: false, error: "Ogiltiga id:n." }

  const supabase = await createClient()
  const { error } = await supabase
    .from("memberships")
    .update({ is_confirmed: isConfirmed })
    .eq("person_id", parsed.data.person_id)
    .eq("organization_id", parsed.data.organization_id)
  if (error) return { ok: false, error: error.message }

  revalidateBoth(parsed.data.person_id, parsed.data.organization_id)
  return { ok: true }
}

export async function removeMembership(personId: string, organizationId: string): Promise<ActionResult> {
  await requireUser()
  const parsed = pairSchema.safeParse({ person_id: personId, organization_id: organizationId })
  if (!parsed.success) return { ok: false, error: "Ogiltiga id:n." }

  const supabase = await createClient()
  const { error } = await supabase
    .from("memberships")
    .delete()
    .eq("person_id", parsed.data.person_id)
    .eq("organization_id", parsed.data.organization_id)
  if (error) return { ok: false, error: error.message }

  revalidateBoth(parsed.data.person_id, parsed.data.organization_id)
  return { ok: true }
}
