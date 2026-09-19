/**
 * Filtren för underrättelsesidan, och länken som bär dem.
 *
 * De ligger här och inte i verktygsraden eftersom taggraden är en
 * serverkomponent: en funktion som exporteras ur en "use client"-modul blir en
 * klientreferens, och att anropa den under serverrenderingen kastar fel.
 */
export type IntelFilters = {
  q: string
  tag: string
  source: string
  confidence: string
  attachment: string
}

/** Gör om filtren till den frågesträng underrättelsesidan läser tillbaka. */
export function intelHref(filters: Partial<IntelFilters>): string {
  const params = new URLSearchParams()
  if (filters.q?.trim()) params.set("q", filters.q.trim())
  if (filters.tag) params.set("tag", filters.tag)
  if (filters.source) params.set("source", filters.source)
  if (filters.confidence) params.set("confidence", filters.confidence)
  if (filters.attachment && filters.attachment !== "any") params.set("attachment", filters.attachment)
  const qs = params.toString()
  return qs ? `/intel?${qs}` : "/intel"
}
