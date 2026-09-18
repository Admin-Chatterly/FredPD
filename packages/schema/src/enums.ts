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

// -------------------------------------------------------- records (M2)

/**
 * `ck_fpd_persons_sex`. What is recorded on a person's file, which is a records
 * field and not a statement about anybody: 'unknown' is a real answer -- a
 * person can enter the master name index from a scene with nothing known about
 * them but a description -- and it is also the only way to take a sex back off a
 * record, because the column is nullable but an enum has no empty member.
 */
export const PERSON_SEXES = [
  'male',
  'female',
  'other',
  'unknown',
] as const;

export type PersonSex = (typeof PERSON_SEXES)[number];

/**
 * `ck_fpd_person_cautions_kind` — what a query result turns red for (spec 7.3).
 * 
 * `mental_health` is a member because the server derives the caution's
 * `field_key` from the kind (`CAUTION_FIELD_KEY` in the persons routes) and the
 * database refuses a mental-health caution that does not carry that key
 * (`ck_fpd_person_cautions_field`, 0005:611-612). It is a kind that may be
 * *written* by a reader who holds `fields.mental_health.view`, and it is
 * deliberately not a filter anywhere: a route that let a caller select persons
 * by this kind would answer "who is on the mental-health list" by row count
 * alone, without ever showing a caution (spec 4.5, 7.3).
 */
export const PERSON_CAUTION_KINDS = [
  'armed',
  'violent',
  'officer_safety',
  'mental_health',
  'gang',
] as const;

export type PersonCautionKind = (typeof PERSON_CAUTION_KINDS)[number];

/**
 * `ck_fpd_vehicle_flags_kind` — what a vehicle can be flagged as (spec 7.4).
 * 
 * The first three are the hot file (7.2): a plate check that returns one of
 * them shows a red banner and has to be confirmed before it is acted on, which
 * is why the list is an enum and not a free string. The other three are
 * administrative — an impound or a lapsed insurance is something for the
 * officer to read, not something to stop a car over — and the split between
 * the two halves lives in `service.VEHICLE_HOTFILE`, not here.
 * 
 * Reporting a vehicle stolen is `stolen` on this list and not a route of its
 * own: one path onto the hot file means one place the case number, the reason
 * and the audit entry are enforced.
 */
export const VEHICLE_FLAG_KINDS = [
  'stolen',
  'wanted',
  'bolo',
  'impounded',
  'evidence_hold',
  'uninsured',
] as const;

export type VehicleFlagKind = (typeof VEHICLE_FLAG_KINDS)[number];

/**
 * `ck_fpd_vehicles_registration`. The column is `NOT NULL DEFAULT 'valid'`, so
 * a write schema declares this as an enum rather than a bounded string: there
 * is no empty value it could carry. On the register path the repo sends it as
 * a plain parameter and the CHECK refuses a blank; on the update path the
 * allowlist clears optional columns with `NULLIF(?, '')` and a blank would
 * become a NULL the column refuses. Both surface to the officer as
 * `error.internal` for a field they can see, which is what the enum prevents.
 */
export const VEHICLE_REGISTRATION_STATUSES = [
  'valid',
  'expired',
  'suspended',
  'revoked',
  'unregistered',
] as const;

export type VehicleRegistrationStatus = (typeof VEHICLE_REGISTRATION_STATUSES)[number];

/**
 * `ck_fpd_vehicles_insurance`. `none` is a state, not an absence: a vehicle
 * with no insurance on file and a vehicle whose insurance has lapsed are
 * different facts, and only one of them is `uninsured` on the flag list. The
 * column is `NOT NULL DEFAULT 'none'` for the same reason as the registration
 * status above.
 */
export const VEHICLE_INSURANCE_STATUSES = [
  'valid',
  'expired',
  'none',
] as const;

export type VehicleInsuranceStatus = (typeof VEHICLE_INSURANCE_STATUSES)[number];

/**
 * `ck_fpd_firearms_status` (7.5). Where a weapon stands, not who holds it.
 * 
 * `agency_issued` is a status on the same table rather than a separate armoury
 * because a duty weapon recovered from a crime scene has to be as traceable as
 * any other firearm; who is carrying it is `assigned_officer`, which a return
 * clears while the status stays. `lost` and `stolen` are the two that make a
 * serial query a hot-file hit (7.2).
 */
export const FIREARM_STATUSES = [
  'registered',
  'lost',
  'stolen',
  'seized',
  'destroyed',
  'agency_issued',
] as const;

export type FirearmStatus = (typeof FIREARM_STATUSES)[number];

/**
 * `ck_fpd_firearms_type` (7.5). Nullable in the table: a weapon can be entered
 * from a serial alone before anybody has the thing in front of them, so every
 * schema that carries this field leaves it optional.
 */
export const FIREARM_TYPES = [
  'pistol',
  'revolver',
  'rifle',
  'shotgun',
  'smg',
  'other',
] as const;

export type FirearmType = (typeof FIREARM_TYPES)[number];

/**
 * `ck_fpd_firearm_events_event` — every event in the life of a weapon (7.5).
 * 
 * No route accepts one of these, so no schema in this file imports it: the
 * server picks the event from what the officer did (`service.statusEvent`, and
 * `issued`/`returned` from whether an assignment names an officer), because the
 * history is what a trace report reconstructs and a history a client could write
 * traces nothing. The list is here so the NUI can label a trace and so
 * `service.lua` can stop keeping its own hand-written copy of the CHECK.
 */
export const FIREARM_EVENTS = [
  'register',
  'transfer',
  'lost',
  'stolen',
  'recovered',
  'seized',
  'destroyed',
  'issued',
  'returned',
] as const;

export type FirearmEvent = (typeof FIREARM_EVENTS)[number];
