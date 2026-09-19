import type { SearchHit } from "@/app/(app)/search/actions"

export const SEARCH_KIND_LABELS: Record<string, string> = {
  person: "Personer",
  organization: "Organisationer",
  vehicle: "Fordon",
  note: "Underrättelser",
  case: "Ärenden",
}

/** Ordningen träffarna grupperas i, det mest användbara först. */
export const SEARCH_KIND_ORDER = ["person", "vehicle", "organization", "note", "case"] as const

/**
 * Where a result goes. Vehicles and notes have no page of their own, so they
 * open the record they belong to; when they belong to nothing, they fall back
 * to the list that shows them, already filtered.
 */
export function searchHitHref(hit: SearchHit, term: string): string {
  if (hit.parentId) {
    if (hit.parentKind === "person") return `/people/${hit.parentId}`
    if (hit.parentKind === "organization") return `/organizations/${hit.parentId}`
    if (hit.parentKind === "case") return `/cases/${hit.parentId}`
  }
  switch (hit.kind) {
    case "person":
      return `/people/${hit.id}`
    case "organization":
      return `/organizations/${hit.id}`
    case "case":
      return `/cases/${hit.id}`
    case "vehicle":
      return `/people?q=${encodeURIComponent(hit.title)}`
    case "note":
      return `/intel?q=${encodeURIComponent(term)}`
    default:
      return "/"
  }
}

export function groupHits(hits: SearchHit[]): { kind: string; hits: SearchHit[] }[] {
  return SEARCH_KIND_ORDER.map((kind) => ({
    kind,
    hits: hits.filter((h) => h.kind === kind),
  })).filter((group) => group.hits.length > 0)
}
