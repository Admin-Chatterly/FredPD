/**
 * Escape a user-typed string for use inside a PostgREST `ilike` pattern that is
 * itself embedded in an `or(...)` filter list. Both the LIKE wildcards and the
 * quotes that delimit the value have to be neutralised, or a search for `50%`
 * or `o"neil` changes the shape of the query.
 */
export function likePattern(term: string): string {
  const escaped = term.replace(/[\\%_]/g, (c) => `\\${c}`).replace(/"/g, '\\"')
  return `"%${escaped}%"`
}

/**
 * PostgREST rejects a malformed uuid with an error rather than an empty result,
 * so ids from the URL are checked first. The shape matters: a string of 36
 * hyphens is the right length but is not a uuid, and would reach the database
 * and throw instead of rendering a not-found page.
 */
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function isUuid(value: string): boolean {
  return UUID.test(value)
}

/** Keep only the ids that are safe to interpolate into an `in.(...)` list. */
export function uuidList(ids: (string | null | undefined)[]): string[] {
  return Array.from(new Set(ids.filter((id): id is string => typeof id === "string" && isUuid(id))))
}
