import type { Json } from "@/lib/database.types"

type PersonLike = {
  name?: string | null
  alias?: string | null
  description?: string | null
}

/** Huvudetikett: namn, annars alias, annars "Okänd". */
export function personLabel(p: PersonLike): string {
  return p.name?.trim() || p.alias?.trim() || "Okänd"
}

/** Sant när namnet ännu är okänt (fallet med märkningen "Oidentifierad"). */
export function isUnidentified(p: PersonLike): boolean {
  return !p.name?.trim()
}

/** Rad under etiketten: aliaset när namn finns, annars signalementet. */
export function personSecondary(p: PersonLike): string | null {
  if (p.name?.trim() && p.alias?.trim()) return `"${p.alias.trim()}"`
  if (!p.alias?.trim() || !p.name?.trim()) return p.description?.trim() || null
  return null
}

export function truncate(text: string, max = 120): string {
  const clean = text.replace(/\s+/g, " ").trim()
  return clean.length > max ? `${clean.slice(0, max - 1).trimEnd()}…` : clean
}

const absolute = new Intl.DateTimeFormat("sv-SE", {
  day: "2-digit",
  month: "short",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
})

export function formatDateTime(iso: string | null | undefined): string {
  if (!iso) return "—"
  return absolute.format(new Date(iso))
}

export function formatRelative(iso: string | null | undefined, now: Date = new Date()): string {
  if (!iso) return "aldrig"
  const then = new Date(iso)
  const diffMs = now.getTime() - then.getTime()
  const minutes = Math.round(diffMs / 60_000)
  if (minutes < 1) return "just nu"
  if (minutes < 60) return `${minutes} min sedan`
  const hours = Math.round(minutes / 60)
  if (hours < 24) return `${hours} tim sedan`
  const days = Math.round(hours / 24)
  if (days === 1) return "i går"
  if (days < 14) return `${days} dgr sedan`
  return absolute.format(then)
}

/** Organisationstillhörighet som vyn people_overview levererar den. */
export type OrganizationAffiliation = {
  id: string
  name: string
  type: string | null
  role: string | null
  is_confirmed: boolean
}

export function parseAffiliations(value: Json | null | undefined): OrganizationAffiliation[] {
  if (!Array.isArray(value)) return []
  const out: OrganizationAffiliation[] = []
  for (const item of value) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue
    const rec = item as Record<string, Json | undefined>
    if (typeof rec.id !== "string" || typeof rec.name !== "string") continue
    out.push({
      id: rec.id,
      name: rec.name,
      type: typeof rec.type === "string" ? rec.type : null,
      role: typeof rec.role === "string" ? rec.role : null,
      is_confirmed: rec.is_confirmed === true,
    })
  }
  return out
}
