/**
 * Shared enumerations (spec 1.4, 3.10, 7.1). Mirrored into Lua by
 * `src/generate.ts`, so the NUI and the route layer cannot drift apart.
 */

/** Where a session opened FredPD from. Some features require a specific one. */
export const ACCESS_POINTS = [
  'mdc',
  'tablet',
  'station',
  'property',
  'lab',
  'booking',
  'dispatch',
  'courthouse',
  'portal',
] as const;

export type AccessPoint = (typeof ACCESS_POINTS)[number];

/** Unit status (spec 7.1). Every change is timestamped server-side. */
export const UNIT_STATUSES = [
  'available',
  'en_route',
  'on_scene',
  'busy',
  'out_of_service',
  'panic',
] as const;

export type UnitStatus = (typeof UNIT_STATUSES)[number];

/**
 * What a world placement opens (spec 3.10, ADR-006).
 *
 * Each kind is an entrance to a feature, not a permission to use it: the server
 * still checks the Discord-derived permission on every route the feature calls.
 */
export const PLACEMENT_KINDS = [
  'station_terminal',
  'property_terminal',
  'lab_terminal',
  'booking_terminal',
  'dispatch_console',
  'courthouse_terminal',
  'motorpool',
  'evidence_bench',
] as const;

export type PlacementKind = (typeof PLACEMENT_KINDS)[number];

/** How a placement is reached in the world (spec 3.10). */
export const PLACEMENT_INTERACTIONS = [
  /** Bind to a prop that already exists in the map. */
  'prop',
  /** Spawn a ped to walk up to — how the motor pool works. */
  'ped',
  /** A radius on the ground, with no entity of its own. */
  'zone',
] as const;

export type PlacementInteraction = (typeof PLACEMENT_INTERACTIONS)[number];

/**
 * The access point each placement kind counts as, for the `accessPoint` context
 * condition (spec 4.3). Kinds with no access point of their own are reached
 * from anywhere the permission allows.
 */
export const PLACEMENT_ACCESS_POINTS: Partial<Record<PlacementKind, AccessPoint>> = {
  station_terminal: 'station',
  property_terminal: 'property',
  lab_terminal: 'lab',
  booking_terminal: 'booking',
  dispatch_console: 'dispatch',
  courthouse_terminal: 'courthouse',
};

/**
 * Intelligence vocabularies (spec 10), carried over from PD-Span verbatim so
 * the meaning of an existing note does not shift under the port.
 */

/** How a person of interest stands in the register. */
export const INTEL_PERSON_STATUSES = [
  'unknown',
  'poi',
  'active_investigation',
  'warrant',
  'cleared',
  'incarcerated',
  'deceased',
] as const;

export type IntelPersonStatus = (typeof INTEL_PERSON_STATUSES)[number];

export const INTEL_ORG_TYPES = ['gang', 'cartel', 'business', 'crew', 'other'] as const;
export type IntelOrgType = (typeof INTEL_ORG_TYPES)[number];

export const INTEL_ORG_STATUSES = ['active', 'disbanded', 'dormant'] as const;
export type IntelOrgStatus = (typeof INTEL_ORG_STATUSES)[number];

/**
 * Where a piece of intelligence came from. The first three are protected: a
 * note from one of them hides its source from readers without
 * `intel.source.view` (spec 10.6).
 */
export const INTEL_SOURCES = [
  'informant',
  'wiretap',
  'surveillance',
  'patrol',
  'tip',
  'other',
] as const;

export type IntelSource = (typeof INTEL_SOURCES)[number];

export const INTEL_CONFIDENCE = ['low', 'medium', 'high'] as const;
export type IntelConfidence = (typeof INTEL_CONFIDENCE)[number];

export const INTEL_CASE_STATUSES = ['open', 'closed', 'cold'] as const;
export type IntelCaseStatus = (typeof INTEL_CASE_STATUSES)[number];

/** Record classification levels (spec 4.5). */
export const CLASSIFICATIONS = [
  'open',
  'internal',
  'restricted',
  'confidential',
  'secret',
] as const;

export type Classification = (typeof CLASSIFICATIONS)[number];

// ---------------------------------------------------------------- evidence

/**
 * The evidence types of spec 8.2, one key per row of that table.
 *
 * The `fpd_evidence.type` column carries no CHECK: the type of a trace is
 * decided by the server's own grid when it is collected, never by the call
 * (8.3.6), so the database is not where a wrong value would come from. This
 * list is what the *interface* may filter and report on, and what a route will
 * accept as a filter — which is the only place a client's opinion about a type
 * matters.
 */
export const EVIDENCE_TYPES = [
  'print',
  'blood',
  'dna_touch',
  'casing',
  'bullet',
  'magazine',
  'gsr',
  'footwear',
  'glove_mark',
  'drug_residue',
  'tool_mark',
  'digital',
] as const;

export type EvidenceType = (typeof EVIDENCE_TYPES)[number];

/**
 * How an item is packaged, from the list spec 8.5 fixes.
 *
 * These are ox_inventory *items* an officer carries and spends, not a
 * description of how the trace was lifted: 8.5 marks the list [M] and names
 * exactly these eight. The distinction matters because 8.2's "collected as"
 * column reads like a packaging list and is not one -- a photograph and a cast
 * are how a footwear impression is recorded, and neither is a container that
 * can hold anything.
 *
 * Packaging is the officer's choice and the one thing about a collection the
 * client genuinely decides, which is why it is the field `evidence.collect`
 * validates most strictly: the wrong container degrades a sample.
 */
export const EVIDENCE_PACKAGING = [
  'evidence_bag',
  'envelope',
  'swab_box',
  'lift_card',
  'firearm_box',
  'drug_bag',
  'phone_bag',
  'item_tag',
] as const;

export type EvidencePackaging = (typeof EVIDENCE_PACKAGING)[number];

/** `ck_fpd_evidence_seal`. */
export const EVIDENCE_SEAL_STATES = ['sealed', 'broken', 'resealed'] as const;
export type EvidenceSealState = (typeof EVIDENCE_SEAL_STATES)[number];

/** `ck_fpd_evidence_status`. Where an item is, not what it proves. */
export const EVIDENCE_STATUSES = [
  'collected',
  'in_locker',
  'in_property',
  'checked_out',
  'at_lab',
  'released',
  'destroyed',
] as const;

export type EvidenceStatus = (typeof EVIDENCE_STATUSES)[number];

/**
 * Where a transfer can send an item (8.6). Not the same list as the statuses:
 * a destination is an instruction, and the server derives the resulting status
 * from it. An officer asks for `court`; the row becomes `checked_out`.
 */
export const EVIDENCE_DESTINATIONS = ['locker', 'lab', 'court', 'investigator'] as const;
export type EvidenceDestination = (typeof EVIDENCE_DESTINATIONS)[number];

/** `fpd_custody_log.action`. Append-only, so this list only ever grows. */
export const CUSTODY_ACTIONS = [
  'collect',
  'deposit',
  'intake',
  'transfer',
  'checkout',
  'checkin',
  'release',
  'destroy',
] as const;

export type CustodyAction = (typeof CUSTODY_ACTIONS)[number];

/** `ck_fpd_scenes_status`. */
export const SCENE_STATUSES = ['open', 'released'] as const;
export type SceneStatus = (typeof SCENE_STATUSES)[number];

// --------------------------------------------------------------------- lab

/** The analyses of spec 8.7, mirroring the `fpd_lab_analyses.analysis` comment. */
export const LAB_ANALYSES = [
  'dna',
  'print_comparison',
  'print_search',
  'ballistics',
  'gsr',
  'drug_id',
] as const;

/** Named `Kind` so it cannot be confused with the `LabAnalysis` row the NUI holds. */
export type LabAnalysisKind = (typeof LAB_ANALYSES)[number];

/** `ck_fpd_lab_requests_priority`. Priority moves the queue, never the result. */
export const LAB_PRIORITIES = ['routine', 'expedited', 'urgent'] as const;
export type LabPriority = (typeof LAB_PRIORITIES)[number];

/** `ck_fpd_lab_requests_status`. */
export const LAB_REQUEST_STATUSES = ['queued', 'in_progress', 'complete', 'cancelled'] as const;
export type LabRequestStatus = (typeof LAB_REQUEST_STATUSES)[number];

/**
 * `ck_fpd_lab_analyses_status`. Longer than the request's list by two states:
 * an analysis is reviewed and then released, and only a released one may have
 * its result read (8.11).
 */
export const LAB_ANALYSIS_STATUSES = [
  'queued',
  'in_progress',
  'complete',
  'reviewed',
  'released',
  'cancelled',
] as const;

export type LabAnalysisStatus = (typeof LAB_ANALYSIS_STATUSES)[number];

/**
 * `ck_fpd_lab_analyses_result` — the standard result language of 8.7.
 *
 * These are legal statements, not UI labels, and the distinctions are the whole
 * point: a `candidate_match` is a register hit to be followed up, an
 * `identification` is an examiner's conclusion, and the two must never be
 * spelled the same way in any language. The server computes which one applies;
 * nothing a client sends can choose it (invariant 1).
 */
export const LAB_RESULT_CODES = [
  'profile_obtained',
  'partial_profile',
  'mixture',
  'no_profile',
  'identification',
  'exclusion',
  'inconclusive',
  'insufficient',
  'candidate_match',
  'no_match',
] as const;

export type LabResultCode = (typeof LAB_RESULT_CODES)[number];
