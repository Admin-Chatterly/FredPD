import { signPaths } from "@/lib/data/storage"
import type { Tables } from "@/lib/database.types"
import type { Client } from "@/lib/supabase/types"

export type EvidenceRow = Tables<"evidence"> & {
  author: { callsign: string | null } | null
  /** Present for uploaded files; links are rendered from `url` directly. */
  signedUrl?: string | null
}

export const EVIDENCE_SELECT = "*, author:profiles(callsign)"

export type EvidenceTarget = {
  personId?: string
  organizationId?: string
  caseId?: string
}

/**
 * The bucket is private, so an uploaded file is only viewable through a
 * short-lived signed URL minted per request.
 */
export async function signEvidence(supabase: Client, rows: EvidenceRow[]): Promise<EvidenceRow[]> {
  const byPath = await signPaths(supabase, rows.map((row) => row.storage_path))
  if (byPath.size === 0) return rows
  return rows.map((row) =>
    row.storage_path ? { ...row, signedUrl: byPath.get(row.storage_path) ?? null } : row
  )
}
