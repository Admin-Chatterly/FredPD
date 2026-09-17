import { revalidatePath } from "next/cache"

/**
 * A record shows up in its own page, in its list, and on the dashboard, so a
 * change to one has to clear all three.
 */
export function revalidatePerson(id: string) {
  revalidatePath(`/people/${id}`)
  revalidatePath("/people")
  revalidatePath("/")
}

export function revalidateOrganization(id: string) {
  revalidatePath(`/organizations/${id}`)
  revalidatePath("/organizations")
  revalidatePath("/")
}

export function revalidateCase(id: string) {
  revalidatePath(`/cases/${id}`)
  revalidatePath("/cases")
  revalidatePath("/")
}
