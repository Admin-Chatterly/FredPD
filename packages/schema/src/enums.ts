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

/**
 * Unit status — the nine states of spec 7.1 and Appendix E, in the order a
 * shift moves through them. Every change is timestamped server-side (7.1) into
 * `fpd_units.status_since`, which is what "time in status" on the unit board is
 * measured from, what the welfare-check timer reads (7.16), and what nothing a
 * client sends can move (invariant 1). The column is deliberately not
 * `ON UPDATE CURRENT_TIMESTAMP(3)`, because the AVL sweep writes the same row
 * every second or two and an automatic stamp would reset the timer on every
 * sweep — see `fpd_units` in 0007.
 *
 * The set is closed because the unit board, the recommendation of the closest
 * available unit (7.16) and the map legend all branch on it: a tenth status
 * invented by a route would be a unit that is neither dispatchable nor
 * visibly unavailable. Labels live under `cad.unitStatus.<value>` in both
 * locale files (invariant 6); the command-line codes of Appendix F (AV, ER,
 * OS, BU, TR, ST, OOS) are aliases the command line resolves, not values.
 *
 * `off_duty` is a member rather than the absence of a row: `fpd_units` holds
 * one row per officer, not per session (see the M4 data-model note), so a
 * disconnect in the middle of a call leaves the callsign, the beat and the
 * assignment in place and moves the status here. A vanishing row would take
 * the unit off the call silently and the call log would never say when.
 *
 * `emergency` is Appendix E's spelling of what an officer's panic button puts
 * them in. It is deliberately absent from `SELF_SET_UNIT_STATUSES` and from
 * `SUPERVISOR_UNIT_STATUSES` below: the only way into it is `cad.emergency`,
 * which raises the P1 call at the same time (7.16). A status route that could
 * set it would produce an officer in distress with no call behind them, which
 * is precisely the state dispatch cannot act on.
 */
export const UNIT_STATUSES = [
  'off_duty',
  'available',
  'en_route',
  'on_scene',
  'busy',
  'transporting',
  'at_station',
  'out_of_service',
  'emergency',
] as const;

export type UnitStatus = (typeof UNIT_STATUSES)[number];

/**
 * What an officer may set on themselves through `cad.unit.status`.
 *
 * The restriction is in the schema rather than in the handler so it fails at
 * validation: `off_duty` is the sign-off path (7.1 duty integration), which
 * has to release the assignment and the vehicle rather than only relabel the
 * row, and `emergency` belongs to `cad.emergency` for the reason above.
 */
export const SELF_SET_UNIT_STATUSES = [
  'available',
  'en_route',
  'on_scene',
  'busy',
  'transporting',
  'at_station',
  'out_of_service',
] as const satisfies readonly UnitStatus[];

/**
 * What a supervisor or dispatcher may set on somebody else through
 * `cad.unit.manage` — the same list plus `off_duty`, because signing a unit
 * off is a thing a supervisor does at end of shift and to a unit that has
 * gone quiet.
 *
 * Still no `emergency`: a supervisor cannot declare somebody else's panic,
 * and clearing one is done by clearing the call (7.16 supervisor
 * acknowledgement), which is `cad.call.clear`.
 */
export const SUPERVISOR_UNIT_STATUSES = [
  'off_duty',
  'available',
  'en_route',
  'on_scene',
  'busy',
  'transporting',
  'at_station',
  'out_of_service',
] as const satisfies readonly UnitStatus[];

/**
 * The progress a unit reports *on a call* through `cad.call.status` (7.16:
 * "en route, on scene").
 *
 * A subset of the unit statuses rather than a list of its own, because the
 * two must never disagree. **There is no per-assignment status column**:
 * `fpd_call_units` records who joined a call, when they joined, when they
 * left and who had the lead, and nothing else (0007 says why — a unit's own
 * en-route and on-scene moments are status changes, and every status change
 * is already a line in `fpd_call_log` with an author and a time). So one
 * write of this value moves exactly three things: `fpd_units.status` and
 * `fpd_units.status_since` for the unit, the call's own `fpd_calls.status`,
 * and the call's `en_route_at` or `on_scene_at` stamp when this unit is the
 * first to get there.
 *
 * That is the whole list, and it is exactly the two members of both
 * `UNIT_STATUSES` and `CALL_STATUSES`. Every other unit status is missing for
 * the same reason: it would move `fpd_units.status` to a value
 * `ck_fpd_calls_status` cannot hold, so the call's status would have nowhere
 * to follow it and the card's timestamps would be left unexplained.
 * `transporting` in particular is a *unit* state, not call progress — a unit
 * taking a prisoner away from a scene sets it through `cad.unit.status`,
 * stays on the call, and the log line says so.
 */
export const CALL_PROGRESS_STATUSES = [
  'en_route',
  'on_scene',
] as const satisfies readonly UnitStatus[];

export type CallProgressStatus = (typeof CALL_PROGRESS_STATUSES)[number];

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

// ------------------------------------------------------------ dispatch (M4)

/**
 * Call priority, P1–P4 exactly as Appendix E fixes them:
 *
 * - `1` life-threatening or in progress — what the emergency button raises (7.16)
 * - `2` urgent
 * - `3` routine
 * - `4` report only or scheduled
 *
 * Numbers rather than names, because the pending queue is *ordered* by this
 * column: 7.16 stacks by priority and age, which is
 * `ORDER BY priority ASC, received_at ASC` over an index in that order. A
 * name would need a CASE expression on every poll and would not use the
 * index, and the queue is polled by every dispatcher and every MDT (budget
 * 12.1, route p95 < 50 ms).
 *
 * Stored in a `TINYINT UNSIGNED` under `ck_fpd_calls_priority`, so a field
 * that carries one is an `integer` spec with `min: 1, max: 4` — the
 * validator's `enum` type compares strings and would refuse the number 1.
 * This list is here for the NUI's labels (`cad.priority.p1` … `p4`) and so
 * nothing has to spell the bounds a second time.
 *
 * The set is closed at four because priority is the only thing that decides
 * order: a fifth level would sort somewhere nobody chose, and every call
 * carries one (the column is `NOT NULL`).
 */
export const CALL_PRIORITIES = [1, 2, 3, 4] as const;

export type CallPriority = (typeof CALL_PRIORITIES)[number];

/**
 * `ck_fpd_calls_status` — the call lifecycle of Appendix E:
 * Pending → Dispatched → En route → On scene → Cleared, or Cancelled.
 *
 * Closed because each member but `pending` is the visible half of a
 * timestamp. 7.16's call card carries five of them — received, dispatched,
 * en route, on scene, cleared — and the server sets the matching column in
 * the same statement that moves the status, so the two can never disagree. A
 * status with no column behind it would be a call whose card cannot say when
 * it got there.
 *
 * The status is derived from the units, never sent: it is the furthest any
 * assigned unit has got (`cad.call.status`), which is why a second unit being
 * dispatched to a call that already has somebody on scene does not walk it
 * backwards.
 *
 * `cancelled` is terminal beside `cleared`, not a step before it. Both are
 * reached through `cad.call.clear` and both stamp `cleared_at`: a call
 * cancelled before anybody rolled still leaves a log that has to say who
 * closed it and when (11.3 — a record nobody can account for). Which of the
 * two a clearing produces is decided by the disposition, below.
 */
export const CALL_STATUSES = [
  'pending',
  'dispatched',
  'en_route',
  'on_scene',
  'cleared',
  'cancelled',
] as const;

export type CallStatus = (typeof CALL_STATUSES)[number];

/**
 * `fpd_calls.type` — what the call is (7.16's call card "type").
 *
 * **There is no CHECK on that column** and this list is deliberately not
 * paired with one in `tools/enum-check.ts`: 0007 leaves call types and
 * dispositions unconstrained so an agency can add one without a migration,
 * and the allowlist that refuses an unknown value lives with the module,
 * where it fails at the call site with the value in the message. The column
 * is `VARCHAR(32)`, so every member here has to fit in that.
 *
 * A closed enum rather than a free string or a code table, for three reasons
 * that all cost something later if it is open: the type carries a locale key
 * (`cad.callType.<value>`, invariant 6) and a free string cannot have one;
 * the type is what the statistics (7.27) and the beat workload group by, and
 * two dispatchers spelling "shots fired" differently make both meaningless;
 * and the type drives the default priority the intake form offers, which
 * needs a value it recognises.
 *
 * `officer_emergency` is on the list because the NUI and the map have to
 * label it, not because anybody may choose it: `cad.emergency` is the only
 * thing that writes it (7.16), and `cad.call.create` refuses it — a
 * hand-raised officer-down call would ring the tone for a unit that never
 * pressed anything.
 *
 * `other` is the escape hatch that keeps the rest honest. Without it a
 * dispatcher would file the odd call under the nearest wrong type and the
 * statistics would quietly absorb it.
 */
export const CALL_TYPES = [
  'alarm',
  'assault',
  'backup',
  'burglary',
  'disturbance',
  'domestic',
  'drugs',
  'missing_person',
  'officer_emergency',
  'pursuit',
  'robbery',
  'shots_fired',
  'stolen_vehicle',
  'suspicious',
  'theft',
  'traffic_collision',
  'traffic_stop',
  'warrant_service',
  'weapons',
  'welfare_check',
  'other',
] as const;

export type CallType = (typeof CALL_TYPES)[number];

/**
 * `fpd_calls.disposition` — how a call ended (7.16: "clear with a disposition
 * code").
 *
 * Unconstrained in the database for the reason given on `CALL_TYPES`: the
 * constraint named `ck_fpd_calls_disposition` in 0007 is a *presence* check —
 * a call whose status is `cleared` must carry some disposition — and says
 * nothing about which values are legal. The vocabulary below is enforced by
 * this schema on the way in and by the module's allowlist behind it.
 *
 * Closed because a disposition is a statement about what happened, read back
 * months later by whoever asks why nothing came of a call. The list is the
 * standard CAD one; each value has a locale key under
 * `cad.disposition.<value>` and real Swedish wording (Appendix A: an
 * `arrest_made` is a *gripande*, a `citation_issued` an *ordningsbot* — a
 * machine gloss of either says something legally different).
 *
 * `cancelled` and `duplicate` are dispositions rather than a separate route:
 * one clearing path means one place the log entry, the `cleared_at` stamp and
 * the audit row are written. They are the two that leave the call
 * `cancelled` instead of `cleared`; every other value clears it.
 *
 * `report_taken` is the one M4's acceptance criterion ends on — a dispatcher
 * takes a P1 end to end *including report creation*. It records that a report
 * was written, and nothing more: the report itself is created through the
 * records module, pre-filled from the call (7.16), and the link between the
 * two lives on the report.
 */
export const CALL_DISPOSITIONS = [
  'report_taken',
  'arrest_made',
  'citation_issued',
  'warning_given',
  'handled_on_scene',
  'assistance_rendered',
  'gone_on_arrival',
  'unable_to_locate',
  'unfounded',
  'referred',
  'duplicate',
  'cancelled',
] as const;

export type CallDisposition = (typeof CALL_DISPOSITIONS)[number];

/**
 * `ck_fpd_call_log_type`, on `fpd_call_log.entry_type` — what a line in the
 * narrative log is (7.16).
 *
 * Each member is the *event that happened*, not a category of line: the
 * locale keys and `fpd_call_log.message_key` are written from it, which is
 * why `unit_joined` and `lead_changed` sit beside `note` rather than both
 * collapsing into "unit". `tools/enum-check.ts` pairs this list with that
 * constraint, so the two cannot drift again.
 *
 * No route accepts one of these and no schema below imports the list: the
 * server picks the kind from what it just did, because the log is
 * append-only (invariant 11) and a log line a client could label is a log
 * line a client can dress up. `cad.call.note` writes a `note` and nothing
 * else; every other kind is a side effect of a dispatch, a status, a link or
 * a clearing.
 *
 * The list is here so the NUI can render each line with the right icon and
 * locale key (`cad.logKind.<value>`), and so the migration's CHECK and the
 * module have one spelling between them. The *sentence* a generated line
 * renders as is a second, separate key, stored in `fpd_call_log.message_key`
 * with its placeholder values in `message_args` — the `cad.log.*` family,
 * which is longer than this list (`cad.log.self_assigned`,
 * `cad.log.created_external`, `cad.log.acknowledged`, `cad.log.welfare_check`
 * and `cad.log.report_created` all have no event of their own). The module
 * chooses both: this value says what happened, the message key says how the
 * line reads.
 */
export const CALL_LOG_KINDS = [
  'created',
  'note',
  'dispatched',
  'unit_joined',
  'unit_left',
  'lead_changed',
  'unit_status',
  'call_status',
  'linked',
  'unlinked',
  'cleared',
] as const;

export type CallLogKind = (typeof CALL_LOG_KINDS)[number];

/**
 * `ck_fpd_call_links_target`, on `fpd_call_links.target_type` — what can hang
 * off a call (7.16: "linked persons and vehicles").
 *
 * Two members and no more: each one names a register that exists
 * (`fpd_persons`, `fpd_vehicles`) and `fpd_call_links.target_id` is the row in
 * it. The link is polymorphic and carries **no** foreign key to that row —
 * 0007 explains why, and the consequence is the repo's, not the database's:
 * it checks the target belongs to the session's agency before writing, and
 * reading the call card runs the same access check the register would
 * (invariant 4). A third kind would need a third table to point at before it
 * could mean anything.
 */
export const CALL_LINK_KINDS = ['person', 'vehicle'] as const;

export type CallLinkKind = (typeof CALL_LINK_KINDS)[number];

/**
 * `ck_fpd_call_links_role` — how the person or vehicle is involved.
 *
 * The role is what the report pre-fill reads (7.16: create report from call),
 * which is why it is an enum and not free text: a report's person rows carry
 * the same vocabulary (Appendix A — *anmälare*, *målsägande*, *misstänkt*,
 * *vittne*), and a free string here would have to be guessed at there.
 *
 * `involved` is the honest default for a vehicle seen leaving and for a
 * person whose part is not yet known; a call is the earliest and least
 * certain record in the suite, and forcing a stronger word this early is how
 * a witness becomes a suspect in the file.
 */
export const CALL_LINK_ROLES = [
  'caller',
  'victim',
  'suspect',
  'witness',
  'involved',
] as const;

export type CallLinkRole = (typeof CALL_LINK_ROLES)[number];

/**
 * `ck_fpd_broadcasts_kind` — what a dispatch broadcast is (7.16 [S]).
 *
 * These are radio traffic, not records: a `bolo` here is the message that
 * goes out to every unit, and it is not the formal BOLO record of 7.13 with
 * its subject, its expiry and its attempts. That record is [M2] in the spec
 * and no migration has built it yet — what exists today is the vehicle-level
 * flag `fpd_vehicle_flags.kind = 'bolo'` (0005), which is a fact about a
 * registration rather than a message. Keeping the two apart is deliberate: a
 * broadcast expires off the board on its own and leaves whatever it referred
 * to untouched.
 *
 * Labels under `cad.broadcastKind.<value>`. `attempt_to_locate` is 7.13's
 * second half; Swedish has no separate word and Appendix A's *spaningsuppdrag*
 * covers both, so the two keys differ in wording rather than in vocabulary.
 */
export const BROADCAST_KINDS = [
  'bolo',
  'attempt_to_locate',
  'all_units',
  'information',
] as const;

export type BroadcastKind = (typeof BROADCAST_KINDS)[number];

/**
 * `ck_fpd_hotlist_reason` — why a plate is on the ALPR hotlist and what the
 * hit banner says (7.18).
 *
 * The first three are 7.18's own list ("hotlist checks against BOLOs, stolen
 * vehicles and warrants"). An enum rather than free text because the banner
 * is a *reason to stop a car*: an officer acting on one has to be able to say
 * afterwards which register it came from, and the wording of that has to be
 * the same in both languages every time (invariant 6). The labels are
 * `alpr.reason.<value>` in both locale files — the ALPR namespace, not the
 * CAD one, because the banner they title is raised by a plate read.
 *
 * The free text beside it carries the detail (`fpd_hotlist.detail`, the
 * `note` field of `AlprHotlistEdit`); this carries the ground.
 */
export const HOTLIST_REASONS = [
  'stolen_vehicle',
  'wanted_person',
  'warrant',
  'bolo',
  'investigation',
  'other',
] as const;

export type HotlistReason = (typeof HOTLIST_REASONS)[number];
