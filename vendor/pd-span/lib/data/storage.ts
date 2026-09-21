import { STORAGE_BUCKET } from "@/lib/constants"
import type { Client } from "@/lib/supabase/types"

/** How long a rendered image stays fetchable, in seconds. */
export const SIGNED_URL_TTL = 60 * 60

/**
 * The bucket is private, so anything stored in it is only viewable through a
 * short-lived signed URL minted per request. One call covers every path on a
 * page; a failure returns an empty map so the page still renders without its
 * images rather than not at all.
 */
export async function signPaths(
  supabase: Client,
  paths: (string | null | undefined)[]
): Promise<Map<string, string>> {
  const wanted = Array.from(new Set(paths.filter((p): p is string => Boolean(p))))
  if (wanted.length === 0) return new Map()

  const { data, error } = await supabase.storage
    .from(STORAGE_BUCKET)
    .createSignedUrls(wanted, SIGNED_URL_TTL)
  if (error) return new Map()

  // A path can come back null when that one object failed to sign; the rest of
  // the batch is still usable.
  return new Map(
    (data ?? []).flatMap((entry) =>
      entry.path && entry.signedUrl ? [[entry.path, entry.signedUrl] as [string, string]] : []
    )
  )
}
