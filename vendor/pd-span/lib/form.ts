import { z } from "zod"

/** Shared building blocks for the Server Action form parsers. */
export const uuid = z.uuid()

/** Trimmed text where empty means "not known", matching the database triggers. */
export const optionalText = z
  .string()
  .trim()
  .max(4000)
  .optional()
  .transform((v) => (v ? v : null))

/** Pull the named string fields out of a FormData, with absent and empty as undefined. */
export function readFields<K extends string>(
  formData: FormData,
  keys: readonly K[]
): Record<K, string | undefined> {
  const out = {} as Record<K, string | undefined>
  for (const key of keys) {
    const value = formData.get(key)
    out[key] = typeof value === "string" && value !== "" ? value : undefined
  }
  return out
}

/** Checkboxes only appear in the payload when ticked. */
export function readCheckbox(formData: FormData, key: string): boolean {
  return formData.get(key) === "on"
}

export function firstIssue(error: z.ZodError, fallback = "Ogiltig inmatning."): string {
  return error.issues[0]?.message ?? fallback
}
