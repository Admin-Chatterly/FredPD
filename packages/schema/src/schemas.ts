import {

  CLASSIFICATIONS,
  EVIDENCE_DESTINATIONS,
  EVIDENCE_PACKAGING,
  EVIDENCE_STATUSES,
  EVIDENCE_TYPES,
  FIREARM_STATUSES,
  FIREARM_TYPES,
  INTEL_CASE_STATUSES,
  INTEL_CONFIDENCE,
  INTEL_ORG_STATUSES,
  INTEL_ORG_TYPES,
  INTEL_PERSON_STATUSES,
  INTEL_SOURCES,
  LAB_ANALYSES,
  LAB_ANALYSIS_STATUSES,
  LAB_PRIORITIES,
  PERSON_CAUTION_KINDS,
  PERSON_SEXES,
  PLACEMENT_INTERACTIONS,
  PLACEMENT_KINDS,
  SCENE_STATUSES,
  VEHICLE_FLAG_KINDS,
  VEHICLE_INSURANCE_STATUSES,
  VEHICLE_REGISTRATION_STATUSES,
} from './enums';

/**
 * Route input schemas (spec 3.5).
 *
 * One definition per route input, used two ways: as TypeScript for the NUI and
 * the gateway, and as a generated Lua validator table for the route layer. The
 * server drops unknown keys and rejects anything that does not match, so a
 * handler never sees a field it did not ask for.
 *
 * Nothing here describes *who* may call a route — that is the `perm` on the
 * route itself. A schema only describes the shape of the input.
 */

export type FieldSpec =
  | { type: 'string'; required?: boolean; min?: number; max?: number }
  | { type: 'number'; required?: boolean; min?: number; max?: number }
  | { type: 'integer'; required?: boolean; min?: number; max?: number }
  | { type: 'boolean'; required?: boolean }
  | { type: 'enum'; required?: boolean; values: readonly string[] }
  // A list of strings, each bounded. `maxItems` is what stops one note
  // arriving with ten thousand tags and turning a write into a table scan.
  | { type: 'string[]'; required?: boolean; maxItems?: number; maxLength?: number };

export type Schema = Readonly<Record<string, FieldSpec>>;

/** Coordinates repeat across every placement write. */
const COORDS = {
  x: { type: 'number', required: true },
  y: { type: 'number', required: true },
  z: { type: 'number', required: true },
  heading: { type: 'number', required: false, min: 0, max: 360 },
} as const satisfies Schema;

export const schemas = {
  // ---------------------------------------------------------------- placements

  PlacementList: {
    agencyId: { type: 'string', required: false, max: 32 },
  },

  PlacementCreate: {
    kind: { type: 'enum', required: true, values: PLACEMENT_KINDS },
    interaction: { type: 'enum', required: true, values: PLACEMENT_INTERACTIONS },
    agencyId: { type: 'string', required: false, max: 32 },
    model: { type: 'string', required: false, max: 64 },
    ...COORDS,
    // Big enough to cover a room, small enough that one placement cannot
    // silently become "anywhere in the city" and defeat the access-point rule.
    radius: { type: 'number', required: false, min: 0.5, max: 50 },
    labelKey: { type: 'string', required: false, max: 128 },
  },

  PlacementUpdate: {
    id: { type: 'integer', required: true, min: 1 },
    kind: { type: 'enum', required: false, values: PLACEMENT_KINDS },
    interaction: { type: 'enum', required: false, values: PLACEMENT_INTERACTIONS },
    model: { type: 'string', required: false, max: 64 },
    x: { type: 'number', required: false },
    y: { type: 'number', required: false },
    z: { type: 'number', required: false },
    heading: { type: 'number', required: false, min: 0, max: 360 },
    radius: { type: 'number', required: false, min: 0.5, max: 50 },
    labelKey: { type: 'string', required: false, max: 128 },
    enabled: { type: 'boolean', required: false },
  },

  PlacementDelete: {
    id: { type: 'integer', required: true, min: 1 },
  },

  // --------------------------------------------------------------- police chat

  ChatSend: {
    // Matches fpd_chat_messages.body. Long enough for a plate and an address,
    // short enough that the chat box cannot be flooded from one message.
    body: { type: 'string', required: true, min: 1, max: 512 },
  },

  ChatHistory: {
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  // ------------------------------------------------------------ permissions

  RoleMapList: {
    agencyId: { type: 'string', required: false, max: 32 },
  },

  RoleMapCreate: {
    // A Discord snowflake: digits only, and long enough to be a real id.
    discordRoleId: { type: 'string', required: true, min: 17, max: 32 },
    discordRoleName: { type: 'string', required: false, max: 191 },
    groupKey: { type: 'string', required: true, max: 64 },
    agencyId: { type: 'string', required: true, max: 32 },
  },

  RoleMapDelete: {
    id: { type: 'integer', required: true, min: 1 },
  },

  // ------------------------------------------------------ permission groups

  // The two list routes take no input at all. They keep a schema entry anyway,
  // because a route that declares one has every key it did not ask for dropped
  // before the handler runs — with an empty schema, that is every key.
  GroupList: {},

  GroupCreate: {
    // The primary key of `fpd_permission_groups`. Lower case, and checked
    // again in Lua: the length bound here does not make it a group key.
    key: { type: 'string', required: true, min: 2, max: 64 },
    name: { type: 'string', required: true, min: 1, max: 191 },
    // A blank string clears it; the handler writes NULL through NULLIF.
    inherits: { type: 'string', required: false, max: 64 },
    description: { type: 'string', required: false, max: 255 },
    // The whole grant, replacing whatever is stored. `maxItems` is what stops
    // one save arriving with ten thousand keys.
    permissions: { type: 'string[]', required: true, maxItems: 256, maxLength: 128 },
  },

  GroupUpdate: {
    key: { type: 'string', required: true, min: 2, max: 64 },
    // The version the editor was shown, as on every other editable record. An
    // update replaces the permission set rather than merging into it, so
    // without this the loser of a race loses grants silently and the audit
    // diff reads as though the winner removed them on purpose.
    version: { type: 'integer', required: true, min: 1 },
    name: { type: 'string', required: false, min: 1, max: 191 },
    inherits: { type: 'string', required: false, max: 64 },
    description: { type: 'string', required: false, max: 255 },
    // Omitted means "leave the grant alone"; an empty list means "grant
    // nothing of its own". The two are deliberately different.
    permissions: { type: 'string[]', required: false, maxItems: 256, maxLength: 128 },
  },

  GroupDelete: {
    key: { type: 'string', required: true, min: 2, max: 64 },
  },

  PermissionList: {},

  // --------------------------------------------------------------- motor pool

  FleetList: {
    placementId: { type: 'integer', required: true, min: 1 },
  },

  GarageDraw: {
    placementId: { type: 'integer', required: true, min: 1 },
    model: { type: 'string', required: true, max: 64 },
  },

  GarageReturn: {
    placementId: { type: 'integer', required: true, min: 1 },
    plate: { type: 'string', required: true, max: 16 },
  },

  // ------------------------------------------------------------ fleet editor

  /**
   * The fleet editor (spec 7.31). No input at all: the editor lists the fleet
   * of the agency whose session is asking, and an agency id arriving here
   * would be an administrator reaching into somebody else's motor pool
   * (invariant 1).
   */
  FleetManage: {},

  FleetAdd: {
    model: { type: 'string', required: true, min: 1, max: 64 },
    /** A locale key such as `fleet.cruiser`, never a display name (invariant 6). */
    labelKey: { type: 'string', required: true, min: 3, max: 128 },
    permission: { type: 'string', required: false, max: 128 },
    certification: { type: 'string', required: false, max: 64 },
    /**
     * `-1` means "no livery". JSON null reaches Lua as an absent field, and a
     * nil in an oxmysql values list shifts every placeholder after it, so a
     * sentinel is the only way the editor can clear an integer column.
     */
    livery: { type: 'integer', required: false, min: -1, max: 63 },
    sortOrder: { type: 'integer', required: false, min: 0, max: 9999 },
    enabled: { type: 'boolean', required: false },
    /**
     * The two gates (migration 0003). Either one open is enough; both empty
     * means any officer holding `garage.vehicle.draw` may take the vehicle.
     */
    requiredGroup: { type: 'string', required: false, max: 64 },
    requiredDiscordRole: { type: 'string', required: false, max: 32 },
  },

  /**
   * Every field optional but the id: an absent field is left alone, and an
   * empty string clears that gate.
   */
  FleetUpdate: {
    id: { type: 'integer', required: true, min: 1 },
    model: { type: 'string', required: false, max: 64 },
    labelKey: { type: 'string', required: false, max: 128 },
    permission: { type: 'string', required: false, max: 128 },
    certification: { type: 'string', required: false, max: 64 },
    livery: { type: 'integer', required: false, min: -1, max: 63 },
    sortOrder: { type: 'integer', required: false, min: 0, max: 9999 },
    enabled: { type: 'boolean', required: false },
    requiredGroup: { type: 'string', required: false, max: 64 },
    requiredDiscordRole: { type: 'string', required: false, max: 32 },
  },

  FleetRemove: {
    id: { type: 'integer', required: true, min: 1 },
  },

  // ------------------------------------------------------------ crime scenes

  // No coordinates: the perimeter is where the officer opening it is standing,
  // read from the server's copy of their position (invariant 1).
  SceneCreate: {
    caseNumber: { type: 'string', required: false, max: 32 },
    // The table's CHECK allows up to 500. The floor is here rather than there
    // so a scene cannot be opened as a point nobody can stand outside of.
    radius: { type: 'number', required: false, min: 5, max: 500 },
  },

  SceneRelease: {
    id: { type: 'integer', required: true, min: 1 },
    reason: { type: 'string', required: false, max: 255 },
  },

  SceneList: {
    status: { type: 'enum', required: false, values: SCENE_STATUSES },
    caseNumber: { type: 'string', required: false, max: 32 },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  // ---------------------------------------------------------------- evidence

  // `traceKey` is the opaque key the client was handed with render data, and
  // `targetId` is a server id. Between them they name *which* collection this
  // is, and nothing more: the type, the quality and the owner come from the
  // server-side grid or from the residue table, never from the call. A client
  // that could name either could collect a casing as a blood swab, or frame
  // anybody (8.1, 8.3).
  //
  // Exactly one of the two is meaningful, and the **server** decides which --
  // not this schema. The validator can only say "a string of at most 64
  // characters" and "an integer", so both are optional here and the handler
  // refuses a call that sends neither or both. Making `traceKey` required
  // again, which it was before residue had a reader, deletes the swab path:
  // a swab names a person and there is no trace in the grid to key it by.
  //
  // There is no second route for the swab. Residue is collected by this one
  // with a `targetId` in place of a `traceKey`, because a swab is a collection
  // -- the same item, the same owner row and the same first link of the custody
  // chain, written in the one transaction (8.5, 8.6).
  EvidenceCollect: {
    traceKey: { type: 'string', required: false, min: 1, max: 64 },
    // The person being swabbed, as a server id (8.2's "shooter's hands and
    // clothes"). The server resolves it to a ped itself and range-checks it
    // against its own copy of where both of them are standing (8.3.2), exactly
    // as `ForensicsObserve` treats a `netId` -- a client naming somebody across
    // the map is not swabbing them.
    //
    // Nothing about the residue is in here, and nothing may be added. Whether
    // there is any, how much, how old it is and what it is worth to the lab are
    // all read on the server from the residue table (8.11) -- a `level` or a
    // `present` field would let a shooter's own client tell them whether it was
    // worth washing, and let an officer file a swab that found what it did not.
    targetId: { type: 'integer', required: false, min: 1 },
    sceneId: { type: 'integer', required: false, min: 1 },
    caseNumber: { type: 'string', required: false, max: 32 },
    packaging: { type: 'enum', required: false, values: EVIDENCE_PACKAGING },
    markerNumber: { type: 'integer', required: false, min: 1, max: 999 },
    description: { type: 'string', required: false, max: 512 },
  },

  EvidenceList: {
    status: { type: 'enum', required: false, values: EVIDENCE_STATUSES },
    type: { type: 'enum', required: false, values: EVIDENCE_TYPES },
    sceneId: { type: 'integer', required: false, min: 1 },
    caseNumber: { type: 'string', required: false, max: 32 },
    search: { type: 'string', required: false, max: 64 },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  EvidenceGet: {
    id: { type: 'integer', required: true, min: 1 },
  },

  EvidenceCustody: {
    id: { type: 'integer', required: true, min: 1 },
  },

  // `placementId` is required because the route carries
  // `context: { accessPoint: 'property_terminal' }`: the client names which
  // terminal it is using and the server checks the player is standing at it.
  EvidenceIntake: {
    placementId: { type: 'integer', required: true, min: 1 },
    id: { type: 'integer', required: true, min: 1 },
    // Two-step intake (8.6): the second step is a decision, so it is explicit
    // rather than implied by whether a storage location was filled in.
    accepted: { type: 'boolean', required: true },
    storageLocation: { type: 'string', required: false, max: 64 },
    reason: { type: 'string', required: false, max: 255 },
  },

  EvidenceTransfer: {
    id: { type: 'integer', required: true, min: 1 },
    destination: { type: 'enum', required: true, values: EVIDENCE_DESTINATIONS },
    // Optional here and required in the handler, because which destinations
    // need it depends on the destination: checking an item out to the lab, a
    // court or an investigator happens at the property room counter, while a
    // locker deposit is the collecting officer putting it away before the
    // property room has seen it and has no terminal to name.
    placementId: { type: 'integer', required: false, min: 1 },
    toParty: { type: 'string', required: false, max: 191 },
    // A transfer with no reason is the gap a defence lawyer reads out loud.
    reason: { type: 'string', required: true, min: 1, max: 255 },
  },

  // --------------------------------------------------------------------- lab

  // `evidenceIds` is a string list because the validator has no integer-list
  // type; the server parses and bounds them (`service.parseIds`) and refuses
  // the whole request if one entry is not an id. `analyses` is checked against
  // the analyses the lab actually performs, for the same reason.
  LabRequestCreate: {
    evidenceIds: { type: 'string[]', required: true, maxItems: 25, maxLength: 20 },
    analyses: { type: 'string[]', required: true, maxItems: 6, maxLength: 32 },
    priority: { type: 'enum', required: false, values: LAB_PRIORITIES },
    caseNumber: { type: 'string', required: false, max: 32 },
    justification: { type: 'string', required: false, max: 512 },
  },

  LabQueue: {
    status: { type: 'enum', required: false, values: LAB_ANALYSIS_STATUSES },
    analysis: { type: 'enum', required: false, values: LAB_ANALYSES },
    // "Mine" is a flag, not an analyst id: the server fills in the session's
    // own signature, so nobody can read another analyst's workload.
    mine: { type: 'boolean', required: false },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  LabAnalysisStart: {
    id: { type: 'integer', required: true, min: 1 },
    // The lab terminal the analyst is working at. Required because the route
    // carries `accessPoint = 'lab_terminal'`, and that condition fails closed
    // without it. A claim, not a grant: the server checks they are standing
    // there.
    placementId: { type: 'integer', required: true, min: 1 },
  },

  // Observations are how the analyst worked. The conclusion is not here and
  // never will be: the server computes it (8.7).
  LabAnalysisComplete: {
    id: { type: 'integer', required: true, min: 1 },
    placementId: { type: 'integer', required: true, min: 1 },
    observations: { type: 'string', required: false, max: 1024 },
  },

  // -------------------------------------------------------------- intelligence

  /** Every route that addresses one record by id. */
  IntelId: {
    id: { type: 'integer', required: true, min: 1 },
  },

  IntelSearch: {
    term: { type: 'string', required: true, min: 2, max: 128 },
    perType: { type: 'integer', required: false, min: 1, max: 25 },
  },

  IntelPersonList: {
    search: { type: 'string', required: false, max: 128 },
    status: { type: 'enum', required: false, values: INTEL_PERSON_STATUSES },
    tag: { type: 'string', required: false, max: 64 },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  IntelPersonCreate: {
    // Every field is optional, deliberately: a person of interest can be
    // nothing but a description, which is how a tip enters the register
    // before anyone knows who it concerns (spec 10).
    name: { type: 'string', required: false, max: 191 },
    alias: { type: 'string', required: false, max: 191 },
    description: { type: 'string', required: false, max: 4000 },
    status: { type: 'enum', required: false, values: INTEL_PERSON_STATUSES },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
  },

  IntelPersonUpdate: {
    id: { type: 'integer', required: true, min: 1 },
    // Optimistic locking: a stale version affects no rows and the officer is
    // told to reload rather than silently overwriting somebody else's edit.
    version: { type: 'integer', required: true, min: 1 },
    name: { type: 'string', required: false, max: 191 },
    alias: { type: 'string', required: false, max: 191 },
    description: { type: 'string', required: false, max: 4000 },
    status: { type: 'enum', required: false, values: INTEL_PERSON_STATUSES },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
  },

  IntelPersonMerge: {
    keepId: { type: 'integer', required: true, min: 1 },
    dropId: { type: 'integer', required: true, min: 1 },
  },

  IntelOrgList: {
    search: { type: 'string', required: false, max: 128 },
    tag: { type: 'string', required: false, max: 64 },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  IntelOrgCreate: {
    name: { type: 'string', required: true, min: 1, max: 191 },
    type: { type: 'enum', required: false, values: INTEL_ORG_TYPES },
    territory: { type: 'string', required: false, max: 191 },
    status: { type: 'enum', required: false, values: INTEL_ORG_STATUSES },
    notes: { type: 'string', required: false, max: 4000 },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
  },

  IntelOrgUpdate: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
    name: { type: 'string', required: false, min: 1, max: 191 },
    type: { type: 'enum', required: false, values: INTEL_ORG_TYPES },
    territory: { type: 'string', required: false, max: 191 },
    status: { type: 'enum', required: false, values: INTEL_ORG_STATUSES },
    notes: { type: 'string', required: false, max: 4000 },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
  },

  IntelNoteList: {
    personId: { type: 'integer', required: false, min: 1 },
    orgId: { type: 'integer', required: false, min: 1 },
    caseId: { type: 'integer', required: false, min: 1 },
    source: { type: 'enum', required: false, values: INTEL_SOURCES },
    confidence: { type: 'enum', required: false, values: INTEL_CONFIDENCE },
    tag: { type: 'string', required: false, max: 64 },
    search: { type: 'string', required: false, max: 128 },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  IntelNoteCreate: {
    // All three targets optional: a note may attach to a person, an
    // organisation, a case, any combination, or nothing at all.
    personId: { type: 'integer', required: false, min: 1 },
    orgId: { type: 'integer', required: false, min: 1 },
    caseId: { type: 'integer', required: false, min: 1 },
    body: { type: 'string', required: true, min: 1, max: 8000 },
    source: { type: 'enum', required: false, values: INTEL_SOURCES },
    confidence: { type: 'enum', required: false, values: INTEL_CONFIDENCE },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
    tags: { type: 'string[]', required: false, maxItems: 12, maxLength: 64 },
  },

  IntelNoteUpdate: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
    body: { type: 'string', required: false, min: 1, max: 8000 },
    source: { type: 'enum', required: false, values: INTEL_SOURCES },
    confidence: { type: 'enum', required: false, values: INTEL_CONFIDENCE },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
    tags: { type: 'string[]', required: false, maxItems: 12, maxLength: 64 },
  },

  IntelVehicleCreate: {
    personId: { type: 'integer', required: false, min: 1 },
    plate: { type: 'string', required: false, max: 16 },
    model: { type: 'string', required: false, max: 64 },
    color: { type: 'string', required: false, max: 64 },
    notes: { type: 'string', required: false, max: 2000 },
  },

  IntelCaseList: {
    status: { type: 'enum', required: false, values: INTEL_CASE_STATUSES },
    search: { type: 'string', required: false, max: 128 },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  IntelCaseCreate: {
    title: { type: 'string', required: true, min: 1, max: 191 },
    description: { type: 'string', required: false, max: 8000 },
    status: { type: 'enum', required: false, values: INTEL_CASE_STATUSES },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
  },

  IntelCaseUpdate: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
    title: { type: 'string', required: false, min: 1, max: 191 },
    description: { type: 'string', required: false, max: 8000 },
    status: { type: 'enum', required: false, values: INTEL_CASE_STATUSES },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
  },

  IntelCaseLinkAdd: {
    caseId: { type: 'integer', required: true, min: 1 },
    // Exactly one of these; the handler refuses anything else, and the
    // database would refuse it too.
    personId: { type: 'integer', required: false, min: 1 },
    orgId: { type: 'integer', required: false, min: 1 },
    role: { type: 'string', required: false, max: 191 },
  },

  IntelMembershipSet: {
    personId: { type: 'integer', required: true, min: 1 },
    orgId: { type: 'integer', required: true, min: 1 },
    role: { type: 'string', required: false, max: 191 },
    isConfirmed: { type: 'boolean', required: false },
  },

  IntelMembershipRemove: {
    personId: { type: 'integer', required: true, min: 1 },
    orgId: { type: 'integer', required: true, min: 1 },
  },

  IntelAssociateSet: {
    personId: { type: 'integer', required: true, min: 1 },
    associateId: { type: 'integer', required: true, min: 1 },
    relationship: { type: 'string', required: false, max: 191 },
    isConfirmed: { type: 'boolean', required: false },
  },

  IntelAssociateRemove: {
    personId: { type: 'integer', required: true, min: 1 },
    associateId: { type: 'integer', required: true, min: 1 },
  },

  IntelEvidenceAdd: {
    personId: { type: 'integer', required: false, min: 1 },
    orgId: { type: 'integer', required: false, min: 1 },
    caseId: { type: 'integer', required: false, min: 1 },
    url: { type: 'string', required: false, max: 1024 },
    storagePath: { type: 'string', required: false, max: 512 },
    caption: { type: 'string', required: false, max: 512 },
  },

  // ------------------------------------------------------ records (M2)
  // The master name index (spec 7.2, 7.3).
  PersonSearch: {
    // What the officer typed. The floor is `Repo.MIN_TERM` (persons/repo.lua:142):
    // one character matches a third of the index and answers nothing, and the
    // handler refuses a shorter term anyway. The ceiling is the column the
    // search is logged into -- `fpd_query_log.term VARCHAR(191) NOT NULL`
    // (0005:892) -- because 7.2 logs every query verbatim, including one that
    // found nothing, and a term the log cannot hold is a search that cannot be
    // logged. `Repo.normalize` only ever shortens, so 191 in is 191 stored.
    term: { type: 'string', required: true, min: 2, max: 191 },
    // `fpd_persons.date_of_birth` is a DATE (0005:416), so this is `YYYY-MM-DD`
    // and nothing else. There is no pattern type here, so the width is all the
    // schema can say; the handler checks the shape and answers `format` rather
    // than handing MariaDB a string to reject with a warning and a zero date.
    dateOfBirth: { type: 'string', required: false, max: 10 },
    // `Repo.MAX_LIMIT` clamps a page to 50 and over-fetches four times that to
    // fill it after access filtering (persons/repo.lua:331-342). A larger number
    // here would buy a bigger scan for the same page.
    limit: { type: 'integer', required: false, min: 1, max: 50 },
    // 7.2: a query that reaches restricted data carries a reason or a case
    // number. Widths are `fpd_query_log.reason VARCHAR(255)` and
    // `case_number VARCHAR(32)` (0005:896, 0005:897). Neither carries a `min`:
    // the handler treats a blank string as "not given" (`blank`,
    // persons/routes.lua:230), so an empty box must reach it rather than being
    // refused as too short.
    reason: { type: 'string', required: false, max: 255 },
    caseNumber: { type: 'string', required: false, max: 32 },
  },
  PersonGet: {
    // The only thing this route takes. `fpd_persons.id` is BIGINT UNSIGNED
    // AUTO_INCREMENT (0005:407), so ids start at 1; everything else about the
    // read -- agency, clearance, whether the record may be named at all --
    // comes from the session and the access tables.
    id: { type: 'integer', required: true, min: 1 },
  },
  PersonUpdate: {
    id: { type: 'integer', required: true, min: 1 },
    // Optimistic locking (spec 13.1): the version the editor was shown goes
    // into the WHERE clause, so a stale edit affects no rows and the officer is
    // told to reload rather than overwriting whoever saved first.
    // `fpd_persons.version INT UNSIGNED NOT NULL DEFAULT 1` (0005:427).
    version: { type: 'integer', required: true, min: 1 },
    // The three name columns are VARCHAR(96) each (0005:413-415). No `min`
    // anywhere below: an empty string is how the editor *clears* a nullable
    // column -- it travels as `''` and `NULLIF(?, '')` makes it NULL
    // (persons/repo.lua:668) -- and it cannot travel as a Lua nil, because a nil
    // in an oxmysql values list shifts every placeholder after it.
    firstName: { type: 'string', required: false, max: 96 },
    middleName: { type: 'string', required: false, max: 96 },
    lastName: { type: 'string', required: false, max: 96 },
    // `YYYY-MM-DD`, as on the search: a DATE column (0005:416) and no pattern
    // type here, so the handler checks the shape and answers `format`. The
    // empty string still clears it, which is why there is no `min` and why the
    // handler's shape test skips `''` (persons/routes.lua:409).
    dateOfBirth: { type: 'string', required: false, max: 10 },
    // `ck_fpd_persons_sex` (0005:463-464). An enum rather than the VARCHAR(16)
    // the column is, because a value outside the CHECK does not become a field
    // error, it becomes a 0-row UPDATE that `updateOutcome` reports as CONFLICT
    // -- "someone else changed this record", which is a lie. The list ends in
    // 'unknown', which is also the only way to take a sex back off a record: the
    // validator has no empty-string member, so the `NULLIF(?, '')` clear path
    // is not available to this one field. See the concern.
    sex: { type: 'enum', required: false, values: PERSON_SEXES },
    // `fpd_persons.phone VARCHAR(32)` (0005:418). Stored as the framework wrote
    // it, separators and all -- the search strips them on both sides rather than
    // this column being normalized.
    phone: { type: 'string', required: false, max: 32 },
    // `fpd_persons.address VARCHAR(191)` (0005:421). Field-gated in both
    // directions: a reader without `fields.victim_address.view` is not sent it
    // and may not write it (persons/routes.lua:384).
    address: { type: 'string', required: false, max: 191 },
    // `ck_fpd_persons_class` (0005:461-462), the same five levels as every other
    // record. NOT NULL on the column, so this is the one field the repo sets
    // directly instead of through `NULLIF` (persons/repo.lua:641, 665-667).
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
    // Booleans on the way in, timestamps in the database: *when* somebody died
    // or went missing is a fact the server stamps (`deceased_at`,
    // `missing_since`, 0005:423-424), never a moment a client's clock decides
    // (invariant 1). `false` clears the flag; setting one that is already set
    // keeps the original moment (persons/repo.lua:679-687).
    deceased: { type: 'boolean', required: false },
    missing: { type: 'boolean', required: false },
  },
  PersonCautionSet: {
    // One route, two operations, and every field optional because which ones
    // are needed depends on `cancel`: the handler asks for `cautionId` on the
    // cancel path and for `personId` + `kind` on the create path, and answers
    // `required` per field itself (persons/routes.lua:455-492). Declaring any
    // of them required here would make the other operation uncallable.
    cancel: { type: 'boolean', required: false },
    // `fpd_person_cautions.id` (0005:585). Cancelling is an UPDATE that stamps
    // `cancelled_at`, never a delete: "flagged violent for six months and then
    // withdrawn" is a question an audit asks.
    cautionId: { type: 'integer', required: false, min: 1 },
    personId: { type: 'integer', required: false, min: 1 },
    // `ck_fpd_person_cautions_kind` (0005:606-607). The kind is also what the
    // server derives the field key from (`CAUTION_FIELD_KEY`,
    // persons/routes.lua:54), which is why `mental_health` is a member here and
    // why `fieldKey` is not a field on this schema: a caller who could name the
    // key could file a mental-health caution declaring itself gated on nothing.
    kind: { type: 'enum', required: false, values: PERSON_CAUTION_KINDS },
    // `fpd_person_cautions.detail VARCHAR(512)` (0005:590) -- the part that is
    // redacted unless the reader holds `fields.<field_key>.view`, and the one
    // string in this module that never reaches the audit log.
    detail: { type: 'string', required: false, max: 512 },
    // `fpd_person_cautions.source_case VARCHAR(32)` (0005:592), the same width
    // every case number in the suite is stored at.
    sourceCase: { type: 'string', required: false, max: 32 },
    // `ck_fpd_person_cautions_class` (0005:608-609). A caution carries its own
    // classification, so an officer-safety flag can be open while the
    // intelligence-led one beside it is confidential; the handler refuses a
    // level above the writer's own clearance and defaults to 'internal'.
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
    // Days, not a moment: the database turns this into `expires_at` with
    // `DATE_ADD(NOW(3), INTERVAL ? DAY)` (persons/repo.lua:786), so no client
    // clock can write a caution that expired before it was created (invariant
    // 1). 0 is the "does not expire" sentinel the handler defaults to and the
    // repo's CASE turns into NULL, which is why the floor is 0 and not 1. The
    // ceiling is ten years: longer than any caution should stand without being
    // re-reviewed, and far inside the range DATE_ADD can still produce a
    // DATETIME for.
    expiresInDays: { type: 'integer', required: false, min: 0, max: 3650 },
  },

  // The vehicle register (spec 7.4).
  VehicleSearch: {
    // A plate prefix or a whole VIN: `repo.searchVehicles` matches
    // `v.plate LIKE term%` OR `v.vin = term` and nothing else. The ceiling is
    // the longest identifier the register holds, `fpd_vehicles.vin`
    // VARCHAR(24); `fpd_query_log.term` is wider at VARCHAR(191), so nothing
    // that passes here is truncated when the query is logged.
    //
    // No `min`, deliberately. The field is optional -- a search may filter on
    // the owner alone -- and an empty string is what a form sends when the box
    // is cleared, so a floor here would refuse a call that the same client
    // makes successfully by omitting the key. The floor is
    // `service.searchTerm`, which is pure and unit-tested; every other optional
    // search field in this file is bounded the same way (`IntelOrgList.search`),
    // and the one that carries `min: 2` (`IntelSearch.term`) is required.
    term: { type: 'string', required: false, max: 24 },
    ownerPersonId: { type: 'integer', required: false, min: 1 },
    // `fpd_vehicles.owner_identifier`: the ESX character identifier of the
    // registered keeper.
    ownerIdentifier: { type: 'string', required: false, max: 191 },
    // `service.fetchWindow` clamps to 1..100 and over-fetches three times the
    // page, because access filtering removes rows after the query. The same
    // ceiling here, so a client asking for more is told so rather than
    // silently given a hundred.
    limit: { type: 'integer', required: false, min: 1, max: 100 },
    // Spec 7.2: a query that opens restricted data needs a reason or a case
    // number, and the route refuses the result without one. Both are written
    // to `fpd_query_log`: `reason` VARCHAR(255), `case_number` VARCHAR(32).
    reason: { type: 'string', required: false, max: 255 },
    caseNumber: { type: 'string', required: false, max: 32 },
  },
  VehicleGet: {
    // Any one of the three identifies the vehicle; the handler refuses the
    // call when all three are absent, because a `vehicle.get` with no selector
    // is not a read of anything.
    id: { type: 'integer', required: false, min: 1 },
    // `fpd_vehicles.plate` VARCHAR(16). No pattern and no case rule here:
    // `service.normalizePlate` upper-cases the plate and strips the whitespace
    // inside it before it reaches the query, so `abc 123`, `ABC 123` and
    // `ABC123` are one plate in the register, on an ALPR read and in a search.
    // The bound is the column width, which is what a stored plate can be.
    plate: { type: 'string', required: false, max: 16 },
    // `fpd_vehicles.vin` VARCHAR(24). A VIN the register generated is
    // seventeen characters (`service.VIN_LENGTH`, ISO 3779); the column is
    // wider and the bound follows the column, so a mistyped VIN is refused by
    // the check digit rather than by a length nobody can explain.
    vin: { type: 'string', required: false, max: 24 },
    // A plate or a VIN typed by an officer is a query and is logged as one
    // (7.2); opening the same record by its id is not. Same two columns as
    // `VehicleSearch`.
    reason: { type: 'string', required: false, max: 255 },
    caseNumber: { type: 'string', required: false, max: 32 },
  },
  VehicleRegister: {
    // Required here and checked again in the handler: the schema bound cannot
    // tell a plate of three spaces from a plate, and `service.normalizePlate`
    // can. `fpd_vehicles.plate` VARCHAR(16), and its CHECK refuses a blank.
    plate: { type: 'string', required: true, min: 1, max: 16 },
    //
    // The VIN is absent on purpose and must stay absent: it is generated by
    // `repo.generateVin` and written once (7.4, invariant 1). A client that
    // could name one could give a stolen car the identity of a clean one.
    //
    // `fpd_vehicles.model` -- the spawn name. The label is a locale key.
    model: { type: 'string', required: false, max: 64 },
    colour: { type: 'string', required: false, max: 32 },
    colourSecondary: { type: 'string', required: false, max: 32 },
    ownerPersonId: { type: 'integer', required: false, min: 1 },
    ownerIdentifier: { type: 'string', required: false, max: 191 },
    // `ck_fpd_vehicles_registration` and `ck_fpd_vehicles_insurance`. Enums
    // rather than bounded strings because neither column has a blank it could
    // mean: the insert passes these two straight through as `?` with a repo
    // default (`valid`, `none`), so an empty string that passed the schema
    // would reach MariaDB and be refused by the CHECK -- an `error.internal`
    // for a field the officer can see on the form. The enum makes '' 
    // unrepresentable, which is the only thing standing between the two.
    registrationStatus: { type: 'enum', required: false, values: VEHICLE_REGISTRATION_STATUSES },
    insuranceStatus: { type: 'enum', required: false, values: VEHICLE_INSURANCE_STATUSES },
    // DATE columns, and there is no date FieldSpec: ten characters is
    // `YYYY-MM-DD`, and MariaDB is what refuses anything it cannot parse.
    registrationExpires: { type: 'string', required: false, max: 10 },
    insuranceExpires: { type: 'string', required: false, max: 10 },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
    // Why the vehicle entered the register. It opens the plate history, so it
    // is bounded by `fpd_vehicle_plates.reason` VARCHAR(191) -- *not* by the
    // 255 of a query reason, which is a different column on a different table.
    reason: { type: 'string', required: false, max: 191 },
  },
  VehicleUpdate: {
    id: { type: 'integer', required: true, min: 1 },
    // Optimistic locking, as on every other editable record: the version goes
    // into the WHERE clause, so a stale edit touches no rows and the officer
    // is told to reload rather than quietly overwriting somebody's work.
    version: { type: 'integer', required: true, min: 1 },
    // Every field below is optional and none of the strings carries a `min`.
    // An absent field is left alone and an empty string *clears* the column:
    // the repo's allowlist writes `NULLIF(?, '')`, because a nil appended to
    // an oxmysql values list appends nothing and shifts every placeholder
    // after it. A `min: 1` here would make "clear this field" unreachable.
    model: { type: 'string', required: false, max: 64 },
    colour: { type: 'string', required: false, max: 32 },
    colourSecondary: { type: 'string', required: false, max: 32 },
    // `min: 0`, not 1: zero is the sentinel that clears the registered keeper
    // (`NULLIF(?, 0)`), for the same reason the strings clear with `''`.
    ownerPersonId: { type: 'integer', required: false, min: 0 },
    ownerIdentifier: { type: 'string', required: false, max: 191 },
    // The three NOT NULL columns are the three that are enums, so the blank
    // sentinel is not representable for them: an '' that passed the schema
    // would become NULL through this path's `NULLIF(?, '')` and be refused by
    // the column, which the officer would read as `error.internal`.
    registrationStatus: { type: 'enum', required: false, values: VEHICLE_REGISTRATION_STATUSES },
    insuranceStatus: { type: 'enum', required: false, values: VEHICLE_INSURANCE_STATUSES },
    registrationExpires: { type: 'string', required: false, max: 10 },
    insuranceExpires: { type: 'string', required: false, max: 10 },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
  },
  VehiclePlateChange: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
    // The new plate. `fpd_vehicles.plate` VARCHAR(16), normalised the same way
    // a query is (`service.normalizePlate`), so the plate an officer types,
    // the plate an ALPR reads and the plate on the record compare equal.
    // Required here; the handler refuses a plate that is only whitespace.
    plate: { type: 'string', required: true, min: 1, max: 16 },
    // Why it changed. Written into the new plate period, which is the whole
    // point of the history table: `fpd_vehicle_plates.reason` VARCHAR(191).
    reason: { type: 'string', required: false, max: 191 },
  },
  VehicleFlag: {
    // The route names the vehicle `vehicleId`, not `id` -- the handler reads
    // `input.vehicleId` and the id it returns is the vehicle's.
    vehicleId: { type: 'integer', required: true, min: 1 },
    // `ck_fpd_vehicle_flags_kind`. Three of the six are the hot file (stolen,
    // wanted, bolo) and put a red banner on every plate check, which is why
    // the kind is an enum and not a free string: a misspelled kind that the
    // database accepted would be a flag nobody ever sees.
    kind: { type: 'enum', required: true, values: VEHICLE_FLAG_KINDS },
    // What the flag points at. `service.validateFlag` requires one of these
    // two for a hot-file kind, because an officer stopping a car on a hit has
    // to be able to confirm it against something (7.2 hit confirmation).
    detail: { type: 'string', required: false, max: 512 },
    caseNumber: { type: 'string', required: false, max: 32 },
    // A flag can be more sensitive than the vehicle it sits on -- a BOLO from
    // the intelligence unit on an ordinary car -- so it carries its own level
    // and is filtered on it (4.5).
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
    // Seconds from now, never a moment: the database computes the expiry with
    // `DATE_ADD(NOW(3), INTERVAL ? SECOND)`, so no client clock decides when a
    // stolen flag lapses (invariant 1). `0` is the documented "does not
    // lapse", so the floor is 0 rather than 1, and it must not be negative --
    // that would file a hot-file flag that expired before it existed. The
    // ceiling is a year, which is longer than any flag should sit unreviewed.
    expiresIn: { type: 'integer', required: false, min: 0, max: 31536000 },
  },
  VehicleFlagClear: {
    // The only thing the handler reads. The vehicle is not named: it is read
    // off the flag row, and the reader has to pass the vehicle's access check
    // and the flag's own before the row is stamped cleared (4.5).
    flagId: { type: 'integer', required: true, min: 1 },
  },

  // The firearm register (spec 7.5).
  FirearmSearch: {
    // Searched as a serial prefix (`repo.searchFirearms`: `f.serial LIKE ?`),
    // so the bound is the serial column's, not the query log's. Optional and
    // with no `min`: a search by owner, status or assignment with nothing typed
    // is a legitimate query, a cleared search box sends '', and
    // `service.searchTerm` already drops anything shorter than two characters
    // as too broad to answer inside the budget (spec 12). A `min` here would
    // turn one stray character into `too_short` on the whole search.
    term: { type: 'string', required: false, max: 64 },
    ownerPersonId: { type: 'integer', required: false, min: 1 },
    ownerIdentifier: { type: 'string', required: false, max: 191 },
    status: { type: 'enum', required: false, values: FIREARM_STATUSES },
    // A Discord id, and deliberately without a `min`: the handler runs it
    // through `blankToNull`, so the empty string a cleared filter sends has to
    // validate rather than come back `too_short` and fail the whole search.
    assignedOfficer: { type: 'string', required: false, max: 32 },
    // `service.fetchWindow` clamps to 1..100 and over-fetches three times that.
    // The bound is repeated here so a page of ten thousand is a field error the
    // officer sees rather than a silent clamp.
    limit: { type: 'integer', required: false, min: 1, max: 100 },
    // Spec 7.2: a query that opens restricted data needs one of these. Both are
    // bounded by `fpd_query_log`, which is the table they are written to.
    reason: { type: 'string', required: false, max: 255 },
    caseNumber: { type: 'string', required: false, max: 32 },
  },
  FirearmGet: {
    // Either one. The handler refuses a call carrying neither, because a
    // schema cannot say "one of these two" (routes.lua: `id = 'required'`).
    id: { type: 'integer', required: false, min: 1 },
    // No `min`: `service.normalizeSerial` turns a blank into nil and the
    // handler's own refusal is what catches an empty call.
    serial: { type: 'string', required: false, max: 64 },
    // Only read when the officer typed a serial: opening the same record from a
    // list by its id is not a query and is not logged (7.2).
    reason: { type: 'string', required: false, max: 255 },
    caseNumber: { type: 'string', required: false, max: 32 },
  },
  FirearmRegister: {
    // The one identifying fact this register takes from the officer holding the
    // object: a serial is stamped on the weapon and read off it, the way a VIN
    // would be if the vehicle had one before the registry did (repo.lua says so
    // at length). Everything the *server* authors -- who registered it, when,
    // the opening event, the id -- is authored in the repo (invariant 1). The
    // floor mirrors `ck_fpd_firearms_serial`, which refuses a blank one.
    serial: { type: 'string', required: true, min: 1, max: 64 },
    make: { type: 'string', required: false, max: 64 },
    model: { type: 'string', required: false, max: 64 },
    type: { type: 'enum', required: false, values: FIREARM_TYPES },
    calibre: { type: 'string', required: false, max: 24 },
    // Absent means `registered`, which is the column default. `agency_issued`
    // is accepted here because a duty weapon enters the register as one, and
    // the repo opens its history with an `issued` event rather than a
    // `register` event when it does.
    status: { type: 'enum', required: false, values: FIREARM_STATUSES },
    ownerPersonId: { type: 'integer', required: false, min: 1 },
    ownerIdentifier: { type: 'string', required: false, max: 191 },
    // The keeper as written on the paperwork when no person record exists for
    // them. It lands on the opening event, not on the firearm, which is why it
    // is bounded by `fpd_firearm_events.to_party` and not by the register.
    ownerParty: { type: 'string', required: false, max: 191 },
    // The officer a duty weapon is issued to: a grantee, never the actor. The
    // actor is `session.discordId` and signs the event. No `min`, because the
    // handler blanks it and an ordinary registration sends nothing.
    assignedOfficer: { type: 'string', required: false, max: 32 },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
    // Both land on the opening event, so they carry the event table's widths
    // rather than the query log's.
    caseNumber: { type: 'string', required: false, max: 32 },
    reason: { type: 'string', required: false, max: 512 },
  },
  FirearmUpdate: {
    id: { type: 'integer', required: true, min: 1 },
    // Optimistic locking, as on every other editable record: a stale version
    // affects no rows and the officer is told to reload rather than silently
    // overwriting somebody else's edit.
    version: { type: 'integer', required: true, min: 1 },
    // The serial, the owner, the status and the assignment are absent on
    // purpose and could not be added here: each is an event in the life of the
    // weapon and has its own route, so the ownership history can never disagree
    // with the record (7.5). `repo.FIREARM_UPDATABLE` is the same list.
    //
    // No `min` on the free-text three: the repo's `setClause` writes an empty
    // string as NULL, so a blank is how the editor clears a field it filled in
    // by mistake. `type` and `classification` cannot be cleared that way -- an
    // enum refuses '' before the repo sees it (see concerns).
    make: { type: 'string', required: false, max: 64 },
    model: { type: 'string', required: false, max: 64 },
    type: { type: 'enum', required: false, values: FIREARM_TYPES },
    calibre: { type: 'string', required: false, max: 24 },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
  },
  FirearmTransfer: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
    // Exactly one of a person on file and a named party outside it, checked in
    // `service.validateTransfer` because a schema cannot express "one of these
    // two": "transferred to nobody" is how a weapon leaves a register while
    // staying in circulation.
    toPersonId: { type: 'integer', required: false, min: 1 },
    // Where the weapon goes. `toIdentifier` is written onto the firearm and so
    // carries the register's width; `toParty` and `fromParty` are written onto
    // the event and carry that table's.
    toIdentifier: { type: 'string', required: false, max: 191 },
    toParty: { type: 'string', required: false, max: 191 },
    fromParty: { type: 'string', required: false, max: 191 },
    caseNumber: { type: 'string', required: false, max: 32 },
    reason: { type: 'string', required: false, max: 512 },
  },
  FirearmStatus: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
    // Reporting a weapon lost or stolen is this route (7.5): the status moves
    // and the history gains the matching event in one transaction, so the
    // register can always say when anybody was told.
    status: { type: 'enum', required: true, values: FIREARM_STATUSES },
    // Optional here and conditionally required in `service.validateStatus`:
    // taking a weapon out of circulation (lost, stolen, seized, destroyed)
    // needs one of the two, recovering one does not.
    caseNumber: { type: 'string', required: false, max: 32 },
    reason: { type: 'string', required: false, max: 512 },
  },
  FirearmAssign: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
    // The one officer id the firearm register takes from an input, and it is a
    // grantee rather than the actor: a quartermaster issues weapons to other
    // officers, and the session still signs the event as `recorded_by`
    // (invariant 1). Absent or blank returns the weapon to the armoury, which
    // is why there is no `min` -- `blankToNull` is what turns '' into "nobody",
    // and a Discord-snowflake floor here would refuse the return.
    assignedOfficer: { type: 'string', required: false, max: 32 },
    caseNumber: { type: 'string', required: false, max: 32 },
    reason: { type: 'string', required: false, max: 512 },
  },
  FirearmTrace: {
    // The same two selectors as `firearm.get`, and nothing else: a trace is a
    // read of the record before it is a report, and `rms.firearm.trace` is an
    // extra permission on top of clearance rather than a way around it. The
    // handler refuses a call carrying neither.
    id: { type: 'integer', required: false, min: 1 },
    serial: { type: 'string', required: false, max: 64 },
  },


  // The unified query and hot-file hits (spec 7.2).
  QueryRun: {
    // What the officer typed, before the service normalises it. The floor is
    // `MIN_TERM` (query/service.lua): one character matches most of every
    // register and answers nothing, and the handler refuses a shorter term
    // anyway. The ceiling is the column every query is logged into --
    // `fpd_query_log.term VARCHAR(191) NOT NULL` (0005:892) -- because 7.2 logs
    // every query verbatim, including one that found nothing, and a term the
    // log cannot hold is a query that cannot be logged. `normalizeTerm` only
    // ever shortens, so 191 in is 191 stored.
    term: { type: 'string', required: true, min: 2, max: 191 },
    // The six names of 7.2, plus `serial`, which is what 7.2 calls a firearm
    // query. A bounded string rather than an enum on purpose: the stored value
    // is fixed by `ck_fpd_query_log_type` (0005:911, shipped) and spells a
    // serial query `firearm`, so `Query.canonicalType` resolves the alias to it
    // and the handler answers `not_allowed` for anything else -- one set, in
    // the service, rather than an enum that would have to carry the alias too.
    // Absent means "derive it from the term", which is the ordinary case.
    type: { type: 'string', required: false, max: 16 },
    // `registry.fetchWindow` clamps a page to 1..100 and over-fetches three
    // times it, because access filtering removes rows after the query. Fifty
    // here rather than a hundred: a unified query fans out across three
    // registers, so the window is paid three times over for one page.
    limit: { type: 'integer', required: false, min: 1, max: 50 },
    // 7.2: a query that reaches restricted data carries a reason or a case
    // number, and the route refuses the result without one. Widths are
    // `fpd_query_log.reason VARCHAR(255)` and `case_number VARCHAR(32)`
    // (0005:896-897). Neither carries a `min`: the handler treats a blank
    // string as "not given", so an empty box must reach it rather than being
    // refused as too short.
    reason: { type: 'string', required: false, max: 255 },
    caseNumber: { type: 'string', required: false, max: 32 },
  },
  QueryHitConfirm: {
    // The query that raised the lead (7.2), so the log can say afterwards
    // whether an officer acted on a confirmed record or on an unconfirmed one.
    // Optional, because a hit can also be confirmed from a record page where no
    // query ran. `fpd_query_log.id` is BIGINT UNSIGNED AUTO_INCREMENT, and the
    // handler refuses an id that is not this officer's own -- otherwise a
    // confirmation could be attached to somebody else's query.
    queryId: { type: 'integer', required: false, min: 1 },
    // Which hot file. `ck_fpd_hotfile_confirmations_hit_type` (0006) allows
    // vehicle_flag, firearm and person_caution; `Query.HIT_TYPES` is the copy
    // the handler checks against, answering `not_allowed`.
    hitType: { type: 'string', required: true, max: 24 },
    // The flag, firearm or caution row the hit came from.
    hitId: { type: 'integer', required: true, min: 1 },
    // The three real answers (`ck_fpd_hotfile_confirmations_outcome`, 0006):
    // confirmed, not_confirmed, unable. `unable` is not `not_confirmed` --
    // nobody answered, which is the fact an officer is asked about afterwards.
    outcome: { type: 'string', required: true, max: 16 },
    // What it was confirmed against. `fpd_hotfile_confirmations.case_number`
    // VARCHAR(32) and `detail` VARCHAR(512); a `confirmed` outcome needs one of
    // the two, refused by the handler and again by `ck_..._against`.
    caseNumber: { type: 'string', required: false, max: 32 },
    detail: { type: 'string', required: false, max: 512 },
    // The kind of hit, the record it sits on, who confirmed it and when are all
    // absent and must stay absent (invariant 1): each is read off the record or
    // off the session. A client that could name the kind could file a
    // confirmation saying a vehicle was confirmed stolen when the flag on it
    // says something else.
  },
  QueryLog: {
    // "What have I run." It takes the session's own Discord id rather than the
    // field below (invariant 1) and wins over it in the handler, so it cannot
    // become a way to ask about somebody else by sending their id alongside.
    mine: { type: 'boolean', required: false },
    // Whose history to read, for the misuse-investigation view behind
    // `query.log.view`. `fpd_query_log.discord_id VARCHAR(32)` (0005:887).
    discordId: { type: 'string', required: false, max: 32 },
    // One of the six names (`ck_fpd_query_log_type`), resolved through
    // `Query.canonicalType` so `serial` filters on `firearm` and anything
    // unrecognised filters on nothing.
    queryType: { type: 'string', required: false, max: 16 },
    // `Repo.queryLog` clamps to 1..200; the same ceiling here so a client
    // asking for more is told rather than silently given 200.
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },


  // In-world forensics (spec 8.3, 8.4, 8.10). Every one of these is called from
  // the satellite rather than the MDT (ADR-011): they are actions taken in the
  // world, at the thing they act on, and the MDT is a screen in a car.

  /**
   * A sensor reporting that something happened. Nothing else may be added.
   *
   * Position, weapon, glove state, the trace's type and its owner are all
   * resolved server-side (8.3.2). A coordinate or a type field here would be
   * the hole the whole module exists to close: the client would be telling the
   * server what evidence to create and whose it is.
   *
   * `netId` is resolved and range-checked by the server, never trusted as a
   * position, and `doorIndex` is recorded rather than used as one.
   */
  ForensicsObserve: {
    kind: {
      type: 'enum',
      required: true,
      values: ['shot', 'reload', 'surface', 'vehicle_door', 'item_use', 'tool'],
    },
    netId: { type: 'integer', required: false, min: 1 },
    // A vehicle has eight door indices; which one a print is on is part of the
    // record, because it is what a defence asks about.
    doorIndex: { type: 'integer', required: false, min: 0, max: 7 },
  },

  /** Powder, luminol or a forensic light, worked over a surface (8.4). */
  ForensicsProcess: {
    tool: { type: 'enum', required: true, values: ['powder', 'luminol', 'forensic_light'] },
  },

  /**
   * Wiping, cleaning, washing and picking up (8.10).
   *
   * The narrowest of the three, because it is the one every player reaches --
   * 8.10 forbids gating destruction behind a police permission, so this shape
   * is the only thing standing between a criminal's cloth and the grid. What a
   * client may name is an intent and a handle; what it may never name is a
   * position, a radius, a type or an owner. A `radius` field would let anyone
   * scrub a city block from a doorway, and a `type` field would let them ask
   * for prints specifically and learn, from what the wipe cost them, that
   * prints were there (8.11).
   *
   * `traceKey` is the opaque key the trace was STREAMED with (8.3.2) -- never a
   * position and never a type. It names one trace this player was already shown
   * inside their streaming range, so it cannot reach evidence they were never
   * told about; the grid decides whether it still names anything at all.
   *
   * `netId` is resolved and range-checked by the server, exactly as in
   * `ForensicsObserve`: it says "the thing I am standing at", and the server
   * takes the position off the entity rather than off the client. An unnetworked
   * map prop has no id, which is why it is optional -- the server then falls
   * back to its own copy of where the player is.
   *
   * Which surfaces, which traces and how many is the server's answer, and it is
   * never reported back (8.11).
   */
  ForensicsDestroy: {
    action: {
      type: 'enum',
      required: true,
      values: ['wipe', 'weapon', 'clean', 'wash', 'pickup'],
    },
    traceKey: { type: 'string', required: false, max: 64 },
    netId: { type: 'integer', required: false, min: 1 },
  },

} as const satisfies Record<string, Schema>;

export type SchemaName = keyof typeof schemas;
