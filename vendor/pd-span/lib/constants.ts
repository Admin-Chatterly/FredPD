/**
 * Kontrollerade värdelistor. De måste stämma med check-villkoren i
 * supabase/migrations/0001_init.sql — databasen avvisar allt annat. Nycklarna
 * är på engelska eftersom de ligger i databasen; bara etiketterna översätts.
 */

export const PERSON_STATUSES = [
  "unknown",
  "poi",
  "active_investigation",
  "warrant",
  "cleared",
  "incarcerated",
  "deceased",
] as const
export type PersonStatus = (typeof PERSON_STATUSES)[number]

export const PERSON_STATUS_LABELS: Record<PersonStatus, string> = {
  unknown: "Okänd",
  poi: "Person av intresse",
  active_investigation: "Pågående utredning",
  warrant: "Efterlyst",
  cleared: "Avförd",
  incarcerated: "Frihetsberövad",
  deceased: "Avliden",
}

/** Färger per status. Efterlyst är avsiktligt skrikig. */
export const PERSON_STATUS_STYLES: Record<PersonStatus, string> = {
  unknown: "border-zinc-500/40 bg-zinc-500/15 text-zinc-300",
  poi: "border-sky-500/40 bg-sky-500/15 text-sky-300",
  active_investigation: "border-amber-500/40 bg-amber-500/15 text-amber-300",
  warrant: "border-red-500/60 bg-red-500/25 text-red-200 font-semibold",
  cleared: "border-emerald-500/40 bg-emerald-500/15 text-emerald-300",
  incarcerated: "border-violet-500/40 bg-violet-500/15 text-violet-300",
  deceased: "border-zinc-700 bg-zinc-800 text-zinc-400 line-through",
}

export const ORGANIZATION_TYPES = ["gang", "cartel", "business", "crew", "other"] as const
export type OrganizationType = (typeof ORGANIZATION_TYPES)[number]
export const ORGANIZATION_TYPE_LABELS: Record<OrganizationType, string> = {
  gang: "Gäng",
  cartel: "Kartell",
  business: "Företag",
  crew: "Liga",
  other: "Övrigt",
}

export const ORGANIZATION_STATUSES = ["active", "disbanded", "dormant"] as const
export type OrganizationStatus = (typeof ORGANIZATION_STATUSES)[number]
export const ORGANIZATION_STATUS_LABELS: Record<OrganizationStatus, string> = {
  active: "Aktiv",
  disbanded: "Upplöst",
  dormant: "Vilande",
}
export const ORGANIZATION_STATUS_STYLES: Record<OrganizationStatus, string> = {
  active: "border-emerald-500/40 bg-emerald-500/15 text-emerald-300",
  disbanded: "border-zinc-700 bg-zinc-800 text-zinc-400",
  dormant: "border-amber-500/40 bg-amber-500/15 text-amber-300",
}

export const NOTE_SOURCES = ["informant", "wiretap", "patrol", "tip", "surveillance", "other"] as const
export type NoteSource = (typeof NOTE_SOURCES)[number]
export const NOTE_SOURCE_LABELS: Record<NoteSource, string> = {
  informant: "Informatör",
  wiretap: "Telefonavlyssning",
  patrol: "Patrull",
  tip: "Tips",
  surveillance: "Spaning",
  other: "Övrigt",
}

export const CONFIDENCES = ["low", "medium", "high"] as const
export type Confidence = (typeof CONFIDENCES)[number]
export const CONFIDENCE_LABELS: Record<Confidence, string> = {
  low: "Låg",
  medium: "Medel",
  high: "Hög",
}
export const CONFIDENCE_STYLES: Record<Confidence, string> = {
  low: "border-zinc-500/40 bg-zinc-500/15 text-zinc-300",
  medium: "border-sky-500/40 bg-sky-500/15 text-sky-300",
  high: "border-emerald-500/40 bg-emerald-500/15 text-emerald-300",
}

export const CASE_STATUSES = ["open", "closed", "cold"] as const
export type CaseStatus = (typeof CASE_STATUSES)[number]
export const CASE_STATUS_LABELS: Record<CaseStatus, string> = {
  open: "Öppet",
  closed: "Avslutat",
  cold: "Kallt",
}
export const CASE_STATUS_STYLES: Record<CaseStatus, string> = {
  open: "border-amber-500/40 bg-amber-500/15 text-amber-300",
  closed: "border-zinc-700 bg-zinc-800 text-zinc-400",
  cold: "border-sky-500/40 bg-sky-500/15 text-sky-300",
}

/** Fritextfält med förslag i stället för fasta värden. */
export const MEMBERSHIP_ROLE_SUGGESTIONS = [
  "ledare",
  "underledare",
  "torped",
  "langare",
  "medlem",
  "medhjälpare",
  "hangaround",
]
export const RELATIONSHIP_SUGGESTIONS = [
  "familj",
  "partner",
  "återkommande kontakt",
  "setts tillsammans",
  "rival",
  "cellkamrat",
  "arbetsgivare",
]
export const CASE_ROLE_SUGGESTIONS = [
  "misstänkt",
  "vittne",
  "målsägande",
  "informatör",
  "medhjälpare",
  "oidentifierad",
]

/** Privat lagringshink för foton och bevis (se migrationen). */
export const STORAGE_BUCKET = "intel"
