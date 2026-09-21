"use server"

import { revalidatePath } from "next/cache"
import { redirect } from "next/navigation"
import { z } from "zod"
import { requireUser } from "@/lib/auth"
import { firstIssue, optionalText, readFields, uuid } from "@/lib/form"
import { revalidatePerson } from "@/lib/revalidate"
import { PERSON_STATUSES, STORAGE_BUCKET } from "@/lib/constants"
import { searchPeople, type PersonPick } from "@/lib/data/people"
import { createClient } from "@/lib/supabase/server"
import { isSafeStoragePath } from "@/lib/upload"

import type { ActionResult, FormState } from "@/lib/action-types"

export type { ActionResult, FormState }

const personSchema = z.object({
  name: optionalText,
  alias: optionalText,
  description: optionalText,
  status: z.enum(PERSON_STATUSES).default("unknown"),
})


// ---------------------------------------------------------------------------
// People
// ---------------------------------------------------------------------------

export async function createPerson(_prev: FormState, formData: FormData): Promise<FormState> {
  await requireUser()
  const parsed = personSchema.safeParse(readFields(formData, ["name", "alias", "description", "status"]))
  if (!parsed.success) return { error: firstIssue(parsed.error) }
  const { name, alias, description } = parsed.data
  if (!name && !alias && !description) {
    return { error: "Ange minst ett namn, ett alias eller en beskrivning." }
  }

  const supabase = await createClient()
  const { data, error } = await supabase.from("people").insert(parsed.data).select("id").single()
  if (error) return { error: error.message }

  revalidatePath("/people")
  revalidatePath("/")
  redirect(`/people/${data.id}`)
}

/** One-field add from the list page: a description is enough to open a file. */
export async function quickAddPerson(_prev: FormState, formData: FormData): Promise<FormState> {
  await requireUser()
  const description = z.string().trim().min(1).max(4000).safeParse(formData.get("description"))
  if (!description.success) return { error: "Beskriv personen först." }

  const supabase = await createClient()
  const { data, error } = await supabase
    .from("people")
    .insert({ description: description.data })
    .select("id")
    .single()
  if (error) return { error: error.message }

  revalidatePath("/people")
  revalidatePath("/")
  redirect(`/people/${data.id}`)
}

export async function updatePerson(_prev: FormState, formData: FormData): Promise<FormState> {
  await requireUser()
  const id = uuid.safeParse(formData.get("id"))
  if (!id.success) return { error: "Person-id saknas." }
  const parsed = personSchema.safeParse(readFields(formData, ["name", "alias", "description", "status"]))
  if (!parsed.success) return { error: firstIssue(parsed.error) }
  const { name, alias, description } = parsed.data
  if (!name && !alias && !description) {
    return { error: "Behåll minst ett namn, ett alias eller en beskrivning." }
  }

  const supabase = await createClient()
  const { error } = await supabase.from("people").update(parsed.data).eq("id", id.data)
  if (error) return { error: error.message }

  revalidatePerson(id.data)
  return { ok: true, version: Date.now() }
}

export async function updatePersonStatus(personId: string, status: string): Promise<ActionResult> {
  await requireUser()
  const parsed = z.object({ id: uuid, status: z.enum(PERSON_STATUSES) }).safeParse({ id: personId, status })
  if (!parsed.success) return { ok: false, error: "Ogiltig status." }

  const supabase = await createClient()
  const { error } = await supabase
    .from("people")
    .update({ status: parsed.data.status })
    .eq("id", parsed.data.id)
  if (error) return { ok: false, error: error.message }

  revalidatePerson(parsed.data.id)
  return { ok: true }
}

/**
 * The photo is already in the bucket by the time this runs: the browser uploads
 * it directly, the same way evidence does. The previous file is removed, so a
 * replaced mugshot does not linger.
 */
export async function setPersonPhoto(personId: string, storagePath: string): Promise<ActionResult> {
  await requireUser()
  const parsed = z
    .object({
      id: uuid,
      path: z.string().trim().min(1).max(500).refine(isSafeStoragePath),
    })
    .safeParse({ id: personId, path: storagePath })
  if (!parsed.success) return { ok: false, error: "Ogiltigt foto." }

  const supabase = await createClient()
  const { data: existing } = await supabase
    .from("people")
    .select("photo_path")
    .eq("id", parsed.data.id)
    .maybeSingle()

  const { error } = await supabase
    .from("people")
    .update({ photo_path: parsed.data.path })
    .eq("id", parsed.data.id)
  if (error) {
    // Without the row pointing at it the file is unreachable, so it goes too.
    await supabase.storage.from(STORAGE_BUCKET).remove([parsed.data.path])
    return { ok: false, error: error.message }
  }

  if (existing?.photo_path && existing.photo_path !== parsed.data.path) {
    await supabase.storage.from(STORAGE_BUCKET).remove([existing.photo_path])
  }
  revalidatePerson(parsed.data.id)
  return { ok: true }
}

export async function removePersonPhoto(personId: string): Promise<ActionResult> {
  await requireUser()
  const id = uuid.safeParse(personId)
  if (!id.success) return { ok: false, error: "Ogiltigt id." }

  const supabase = await createClient()
  const { data: existing } = await supabase
    .from("people")
    .select("photo_path")
    .eq("id", id.data)
    .maybeSingle()

  const { error } = await supabase.from("people").update({ photo_path: null }).eq("id", id.data)
  if (error) return { ok: false, error: error.message }

  if (existing?.photo_path) {
    await supabase.storage.from(STORAGE_BUCKET).remove([existing.photo_path])
  }
  revalidatePerson(id.data)
  return { ok: true }
}

export async function deletePerson(personId: string): Promise<ActionResult> {
  await requireUser()
  const id = uuid.safeParse(personId)
  if (!id.success) return { ok: false, error: "Ogiltigt id." }

  const supabase = await createClient()
  const { error } = await supabase.from("people").delete().eq("id", id.data)
  if (error) return { ok: false, error: error.message }

  revalidatePath("/people")
  revalidatePath("/")
  redirect("/people")
}

export async function mergePeople(keepId: string, dropId: string): Promise<ActionResult> {
  await requireUser()
  const parsed = z.object({ keep: uuid, drop: uuid }).safeParse({ keep: keepId, drop: dropId })
  if (!parsed.success) return { ok: false, error: "Ogiltiga id:n." }
  if (parsed.data.keep === parsed.data.drop) return { ok: false, error: "Välj två olika personer." }

  const supabase = await createClient()
  const { error } = await supabase.rpc("merge_people", {
    keep_id: parsed.data.keep,
    drop_id: parsed.data.drop,
  })
  if (error) return { ok: false, error: error.message }

  revalidatePerson(parsed.data.keep)
  revalidatePath(`/people/${parsed.data.drop}`)
  redirect(`/people/${parsed.data.keep}`)
}

/** Used by pickers in client components. */
export async function searchPeopleAction(term: string, excludeIds: string[] = []): Promise<PersonPick[]> {
  await requireUser()
  const supabase = await createClient()
  return searchPeople(supabase, term, excludeIds)
}

// ---------------------------------------------------------------------------
// Associates
// ---------------------------------------------------------------------------

export async function addAssociate(_prev: FormState, formData: FormData): Promise<FormState> {
  await requireUser()
  const parsed = z
    .object({
      person_id: uuid,
      associate_id: uuid,
      relationship: optionalText,
      is_confirmed: z.boolean(),
    })
    .safeParse({
      ...readFields(formData, ["person_id", "associate_id", "relationship"]),
      is_confirmed: formData.get("is_confirmed") === "on",
    })
  if (!parsed.success) return { error: "Välj en person att koppla." }
  if (parsed.data.person_id === parsed.data.associate_id) {
    return { error: "En person kan inte kopplas till sig själv." }
  }

  const supabase = await createClient()
  const { error } = await supabase.from("associates").insert(parsed.data)
  if (error) {
    return { error: error.code === "23505" ? "De två är redan kopplade." : error.message }
  }

  revalidatePerson(parsed.data.person_id)
  revalidatePerson(parsed.data.associate_id)
  return { ok: true, version: Date.now() }
}

export async function removeAssociate(personId: string, otherId: string): Promise<ActionResult> {
  await requireUser()
  const parsed = z.object({ a: uuid, b: uuid }).safeParse({ a: personId, b: otherId })
  if (!parsed.success) return { ok: false, error: "Ogiltiga id:n." }
  const [first, second] = [parsed.data.a, parsed.data.b].sort()

  const supabase = await createClient()
  const { error } = await supabase
    .from("associates")
    .delete()
    .eq("person_id", first)
    .eq("associate_id", second)
  if (error) return { ok: false, error: error.message }

  revalidatePerson(parsed.data.a)
  revalidatePerson(parsed.data.b)
  return { ok: true }
}

// ---------------------------------------------------------------------------
// Vehicles
// ---------------------------------------------------------------------------

export async function addVehicle(_prev: FormState, formData: FormData): Promise<FormState> {
  await requireUser()
  const parsed = z
    .object({
      person_id: uuid.optional(),
      plate: optionalText,
      model: optionalText,
      color: optionalText,
      notes: optionalText,
    })
    .safeParse(readFields(formData, ["person_id", "plate", "model", "color", "notes"]))
  if (!parsed.success) return { error: firstIssue(parsed.error) }
  if (!parsed.data.plate && !parsed.data.model) {
    return { error: "Ange minst en registreringsskylt eller en modell." }
  }

  const supabase = await createClient()
  const { error } = await supabase.from("vehicles").insert({
    ...parsed.data,
    person_id: parsed.data.person_id ?? null,
  })
  if (error) return { error: error.message }

  if (parsed.data.person_id) revalidatePerson(parsed.data.person_id)
  return { ok: true, version: Date.now() }
}

export async function unlinkVehicle(vehicleId: string, personId: string): Promise<ActionResult> {
  await requireUser()
  const parsed = z.object({ v: uuid, p: uuid }).safeParse({ v: vehicleId, p: personId })
  if (!parsed.success) return { ok: false, error: "Ogiltiga id:n." }

  const supabase = await createClient()
  const { error } = await supabase.from("vehicles").update({ person_id: null }).eq("id", parsed.data.v)
  if (error) return { ok: false, error: error.message }

  revalidatePerson(parsed.data.p)
  return { ok: true }
}

export async function deleteVehicle(vehicleId: string, personId: string | null): Promise<ActionResult> {
  await requireUser()
  const v = uuid.safeParse(vehicleId)
  if (!v.success) return { ok: false, error: "Ogiltigt id." }

  const supabase = await createClient()
  const { error } = await supabase.from("vehicles").delete().eq("id", v.data)
  if (error) return { ok: false, error: error.message }

  if (personId) revalidatePerson(personId)
  return { ok: true }
}
