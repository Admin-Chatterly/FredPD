import {
  ANMALAN_ROLLER,
  ANMALAN_STATUSES,
  ATAL_BESLUT,
  ATAL_DISPOSITIONS,
  BROADCAST_KINDS,
  BROTT_GRADER,
  CALL_DISPOSITIONS,
  CALL_LINK_KINDS,
  CALL_LINK_ROLES,
  CALL_PROGRESS_STATUSES,
  CALL_STATUSES,
  CALL_TYPES,
  CLASSIFICATIONS,
  EVIDENCE_DESTINATIONS,
  EVIDENCE_PACKAGING,
  EVIDENCE_STATUSES,
  EVIDENCE_TYPES,
  FIREARM_STATUSES,
  FIREARM_TYPES,
  EFTERLYSNING_GRUNDER,
  FRIHET_STATUSES,
  FU_LEDARE_KINDS,
  FU_STATUSES,
  HAK_METHODS,
  HAK_STATUSES,
  HAK_TARGETS,
  HOTLIST_REASONS,
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
  SPANING_TARGETS,
  TVANG_KINDS,
  TVANG_TARGETS,
  SELF_SET_UNIT_STATUSES,
  SUPERVISOR_UNIT_STATUSES,
  UNIT_STATUSES,
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

  // ----------------------------------------------------------- dispatch (M4)

  /**
   * Dispatch (spec 7.16, 7.17, 7.18). Four rules run through every schema in
   * this section and are not repeated on each one.
   *
   * **No positions, anywhere.** Not on the emergency button, not on a unit
   * status, not on an ALPR read. The server already holds every player's ped
   * and reads the coordinates off it, exactly as the forensics grid does. A
   * client route that reported "I am here" would be a client telling the
   * server where a police unit is: trivially spoofable into a false alibi, and
   * the one fact on the map that an officer has a motive to lie about
   * (invariant 1). AVL positions are read server-side and pushed to sessions
   * with the map open at 3.6's 1–2 second cadence.
   *
   * **No identities and no times.** No agency id, no call number, no author
   * and no timestamp is an input field. Every one of them comes from the
   * session or from the server clock; a call number in particular is
   * allocated from `fpd_counters` under a row lock (13.1, ADR-012). The
   * officer ids on this list are *subjects*, never actors — the units a
   * dispatcher sends, the unit a supervisor manages, the unit whose reads are
   * being filtered — and the actor is always the session (invariant 1).
   *
   * **A unit is `fpd_units.officer_id`, and there is no other id.** That
   * column is the whole primary key of `fpd_units` (the table has no `id`
   * column) and a foreign key to `fpd_officers.id`, so the same number
   * identifies the officer on the roster and the unit on the board — which is
   * the point: 0007 keeps one row per officer rather than per session, so a
   * unit survives a reconnect. Every field below that names a unit is
   * therefore called `officerId`, `officerIds` or `leadOfficerId` and is an
   * `fpd_officers.id`, spelled as what it is.
   *
   * Two neighbouring identifiers are *not* this one and must not be sent:
   * `fpd_units.discord_id` and `fpd_call_units.discord_id` are the identity
   * the server resolves from the session and records as history (0007: "from
   * the session, never from input"), and `fpd_call_units.id` is one row of
   * one assignment, which nothing outside the module ever names. A dispatcher
   * sends officer ids; the module looks up each one's `fpd_units` row and
   * writes the `discord_id` and `callsign` it finds there.
   *
   * **`placementId` exactly where the console is required.** `cad.call.create`
   * and `cad.call.dispatch` are run by a dispatcher at a `dispatch_console`
   * placement (3.10), so both carry it and both routes pin
   * `context = { accessPoint = 'dispatch_console' }` — the condition names the
   * placement *kind*, as the property room and the lab do. It fails closed
   * when `input.placementId` is missing, so a pinned route
   * whose schema omits the field refuses every call it ever receives — that
   * has shipped three times in this project. Everything an officer does in the
   * field — self-assign, report progress, set their own status, press the
   * button, clear a call — carries no `placementId` and is pinned to nothing,
   * because an officer in a car is not standing at the console.
   */

  /**
   * A dispatcher raising a call by hand (7.16 intake).
   *
   * There is no position here and none is missing: a call taken over the phone
   * happens where the *caller* says it does, which is `locationText`, and a
   * dispatcher who knows the district picks `beatId`. A call raised by another
   * resource (the `CreateCall` export of section 14 — an alarm, a robbery
   * script) comes in server-side with real coordinates and never touches this
   * schema, which is why nothing here is shaped as though a session were
   * behind every call.
   */
  CallCreate: {
    placementId: { type: 'integer', required: true, min: 1 },
    type: { type: 'enum', required: true, values: CALL_TYPES },
    /**
     * P1–P4 as an integer, not an enum: `CALL_PRIORITIES` explains why the
     * column is numeric. Required because the intake form makes the dispatcher
     * choose — a default would be a P3 nobody decided on, and the queue is
     * ordered by exactly this.
     */
    priority: { type: 'integer', required: true, min: 1, max: 4 },
    /** As the caller gave it. `fpd_calls.location_text VARCHAR(191)`. */
    locationText: { type: 'string', required: true, min: 1, max: 191 },
    /**
     * The district, when the dispatcher knows it. An `fpd_beats.id`, not a
     * position — a beat is a row, and naming one tells the server nothing
     * about where anybody is standing. Calls that arrive with coordinates are
     * tagged with their beat automatically instead (7.17), so this is only for
     * the ones that do not.
     */
    beatId: { type: 'integer', required: false, min: 1 },
    /** Who called it in. Free text: a caller is rarely on file yet. */
    callerName: { type: 'string', required: false, max: 191 },
    callerPhone: { type: 'string', required: false, max: 32 },
    /**
     * What the caller said, opening the narrative log. It is content, not UI
     * text, so it is stored in `fpd_call_log.body` on the `created` line,
     * beside that line's own `message_key` — `ck_fpd_call_log_content`
     * requires the key on every entry that is not a `note` and says nothing
     * about the body, which is exactly the row this needs. Bounded like every
     * other note on this list: an unbounded narrative is a denial of service
     * on the call card, which loads all of them.
     */
    details: { type: 'string', required: false, max: 1000 },
  },

  /**
   * The pending queue (7.16 stacking), and the same route behind the call list
   * an MDT shows. Not pinned: a unit reads the queue from the car.
   */
  CallList: {
    /**
     * Absent means the working set — everything not yet cleared or cancelled —
     * which is what a queue is. Naming a terminal status is how the day's
     * closed calls are reviewed.
     */
    status: { type: 'enum', required: false, values: CALL_STATUSES },
    priority: { type: 'integer', required: false, min: 1, max: 4 },
    beatId: { type: 'integer', required: false, min: 1 },
    /**
     * "Calls I am on", as a flag rather than an officer id: the server fills
     * in the session's own unit, so this cannot become a way to ask which
     * calls somebody else is working (invariant 1, as `LabQueue.mine`).
     */
    mine: { type: 'boolean', required: false },
    /**
     * The queue is ordered P1 first, oldest first, and it is read as
     * `WHERE agency_id = ? AND queue_priority IS NOT NULL ORDER BY
     * queue_priority, received_at` over `idx_fpd_calls_queue` — not as an
     * order by `priority`, which would sort cleared calls in with the open
     * ones. `queue_priority` is the stored generated column that is the
     * priority while the call is open and NULL once it is closed, so a page
     * is a range read rather than a sort of every call the server has ever
     * taken (budget 12.1). A `status` filter above asks a different question
     * and is answered by `idx_fpd_calls_status` instead. The ceiling matches
     * the other list routes.
     */
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  /** One call card. Not pinned: the card is the unit's copy of the call too. */
  CallGet: {
    id: { type: 'integer', required: true, min: 1 },
  },

  /**
   * Assigning units to a call and setting the lead (7.16). Pinned to the
   * console, so `placementId` is required.
   *
   * Add and remove rather than "here is the new set of units": a replacement
   * set silently undoes a self-assignment that happened between the dispatcher
   * loading the card and pressing save, and the call log would record the
   * dispatcher removing a unit they never saw. The same reasoning as the
   * `version` field on every editable record, expressed in the shape of the
   * write instead.
   */
  CallDispatch: {
    placementId: { type: 'integer', required: true, min: 1 },
    callId: { type: 'integer', required: true, min: 1 },
    /**
     * The units being sent, as `fpd_units.officer_id` values (see the
     * section preamble: that column is the unit's only identifier). They are
     * strings because the validator has no integer-list type — the server
     * parses and bounds them and refuses the whole dispatch if one entry is
     * not an id (as `LabRequestCreate`). `maxLength` is 20 because a
     * `BIGINT UNSIGNED` is at most twenty digits. The cap is a shift's worth
     * of units: a dispatch that names more than twelve is a mistake or an
     * attempt to write a call card nobody can render.
     */
    officerIds: { type: 'string[]', required: false, maxItems: 12, maxLength: 20 },
    /** Units being taken off the call, same encoding and same cap. */
    removeOfficerIds: { type: 'string[]', required: false, maxItems: 12, maxLength: 20 },
    /**
     * Transferring the lead is this field, not a route of its own (7.16
     * "transfer lead unit"): one path onto the call means one place the log
     * line and the audit row are written. The unit must be on the call after
     * this dispatch is applied, which the handler checks — a schema cannot,
     * and `uq_fpd_call_units_lead` only guarantees there is never more than
     * one live lead, not that there is one at all.
     */
    leadOfficerId: { type: 'string', required: false, min: 1, max: 20 },
  },

  /**
   * An officer taking a call themselves (7.16). Not pinned and carrying
   * nothing but the call: which unit is assigned comes from the session, so an
   * officer cannot attach somebody else to a call they do not want.
   */
  CallSelfAssign: {
    callId: { type: 'integer', required: true, min: 1 },
  },

  /**
   * A unit reporting its own progress on a call — en route, on scene (7.16).
   *
   * The call's own status and its `en_route_at` / `on_scene_at` stamps are
   * derived from this by the server, never sent: a client that could set the
   * call's status could put a call on scene with nobody there, and a client
   * that could send the timestamp could decide how long the response took.
   *
   * One write, three rows deep: `fpd_units.status` and `status_since` for the
   * unit, `fpd_calls.status` and the matching stamp for the call, and a line
   * in `fpd_call_log`. There is no per-assignment status to move —
   * `fpd_call_units` records who joined, who left and who has the lead, and
   * carries no status column at all (0007 says why). A unit that goes
   * `transporting` or `busy` while still on a call sets that through
   * `cad.unit.status`, which is why neither is on `CALL_PROGRESS_STATUSES`.
   *
   * `FredPD.Schema.CallStatus` is this input shape; `FredPD.CallStatus` is
   * the generated enum of the call lifecycle, and `FredPD.CallProgressStatus`
   * is the two values this field accepts. Different namespaces, as
   * `UnitStatus` already is.
   */
  CallStatus: {
    callId: { type: 'integer', required: true, min: 1 },
    status: { type: 'enum', required: true, values: CALL_PROGRESS_STATUSES },
  },

  /**
   * Clearing with a disposition code (7.16). Not pinned: Appendix F's `CLR`
   * is a command line an officer types in the car.
   *
   * A call raised by the emergency button cannot be cleared without supervisor
   * acknowledgement (7.16), and that is `CallAcknowledge` below — a separate
   * write by a separate person — not a field here: an `acknowledged: true`
   * flag would be the officer in distress ticking their own box. The handler
   * refuses the clearing with `needs_acknowledgement` while
   * `fpd_calls.acknowledged_at` is NULL, so the officer reads why rather than
   * meeting `ck_fpd_calls_panic_ack` as an `internal` error. Cancelling is
   * refused on the same terms, or cancelling would be the way around it.
   */
  CallClear: {
    callId: { type: 'integer', required: true, min: 1 },
    disposition: { type: 'enum', required: true, values: CALL_DISPOSITIONS },
    /** The closing line of the narrative log. */
    note: { type: 'string', required: false, max: 1000 },
  },

  /**
   * A supervisor acknowledging an emergency call (7.16: an emergency call
   * "cannot be cleared without supervisor acknowledgement").
   *
   * The acknowledgement is a write of its own rather than a flag on
   * `CallClear`, because the two are done by different people at different
   * times: the officer in distress, or whoever is with them, clears the call
   * when it is over, and a supervisor says they have seen it. A flag on the
   * clearing would let the person clearing the call acknowledge it in the
   * same breath, which is the one thing 7.16 is asking to be impossible —
   * and `ck_fpd_calls_panic_ack` refuses the write in any case, so without
   * this route a panic call could never be closed at all.
   *
   * It carries the call and nothing else. `fpd_calls.acknowledged_by` is the
   * session's Discord id and `acknowledged_at` the server clock (invariant
   * 1), and the log line is `cad.log.acknowledged` with the callsign, so
   * there is no text to send either. The permission is `cad.unit.manage`,
   * which Appendix B makes explicit: the groups that hold it — supervisor,
   * command, dispatch — are exactly the ones who may give the
   * acknowledgement, and a key of its own would answer a question this one
   * already answers.
   */
  CallAcknowledge: {
    callId: { type: 'integer', required: true, min: 1 },
  },

  /**
   * Adding to the narrative log (7.16).
   *
   * The kind of the line is not a field: this route writes a `note` and the
   * server writes every other kind from what it just did (`CALL_LOG_KINDS`).
   * The log is append-only (invariant 11), and a line a client could label is
   * a line a client can dress up as a status change that never happened.
   */
  CallNote: {
    callId: { type: 'integer', required: true, min: 1 },
    /**
     * `fpd_call_log.body` is `VARCHAR(2048)`; this stops well short of it,
     * and the bound is the point: a note with no maximum is a denial of
     * service on the call card, which loads the whole log, and on every
     * session subscribed to `call:<id>` (3.6). Stopping short of the column
     * also means a note that is refused here was never truncated on the way
     * to the database — the officer sees `too_long` and keeps their text.
     */
    body: { type: 'string', required: true, min: 1, max: 1000 },
  },

  /**
   * Linking a person or a vehicle to a call (7.16), and unlinking one.
   *
   * `targetId` is a row in the register named by `kind` — `fpd_persons.id` or
   * `fpd_vehicles.id` — and the handler runs the same access check the
   * register itself would before the link is written or read back
   * (invariant 4). A plate or a name is deliberately not accepted: a link is
   * to a record, and creating records from a call card would be a second way
   * into the master name index with none of 7.3's checks.
   */
  CallLink: {
    callId: { type: 'integer', required: true, min: 1 },
    kind: { type: 'enum', required: true, values: CALL_LINK_KINDS },
    targetId: { type: 'integer', required: true, min: 1 },
    /** Absent means `involved`, the column default. */
    role: { type: 'enum', required: false, values: CALL_LINK_ROLES },
    /**
     * True removes the link. One route both ways, because the log line and
     * the audit entry are the same shape either way and splitting them would
     * mean two places to forget one.
     */
    remove: { type: 'boolean', required: false },
  },

  /**
   * The unit board (7.16): every unit, status, assignment and time in status.
   * Not pinned — the board is on the MDT as well as the console.
   */
  UnitList: {
    /** Absent means every unit that is not `off_duty`, which is the board. */
    status: { type: 'enum', required: false, values: UNIT_STATUSES },
    beatId: { type: 'integer', required: false, min: 1 },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  /**
   * An officer setting their own status (7.16, 7.1's F-keys). Not pinned, and
   * it names no officer: the row is the session's own.
   *
   * `FredPD.Schema.UnitStatus` is this input shape; `FredPD.UnitStatus` is the
   * enum table. Different namespaces, as `FirearmStatus` already is.
   *
   * The values are `SELF_SET_UNIT_STATUSES`, not the whole list: `off_duty`
   * is the sign-off path and `emergency` belongs to `cad.emergency`, and
   * leaving them out here makes both refusals happen in the validator rather
   * than in a handler that could forget.
   */
  UnitStatus: {
    status: { type: 'enum', required: true, values: SELF_SET_UNIT_STATUSES },
  },

  /**
   * A supervisor or dispatcher changing somebody else's unit state (7.16).
   *
   * Not pinned, deliberately: a field supervisor (Appendix A, *yttre befäl*)
   * does this from the MDT, and pinning it to the console would refuse every
   * call they make. The permission is what limits it, which is invariant 2
   * doing its job.
   */
  UnitManage: {
    /**
     * The unit being changed — the subject, never the actor. It is an
     * `fpd_units.officer_id` (the preamble says why that is the only id a
     * unit has); the actor is the session, which signs the call log line and
     * the audit row (invariant 1).
     */
    officerId: { type: 'integer', required: true, min: 1 },
    status: { type: 'enum', required: false, values: SUPERVISOR_UNIT_STATUSES },
    /**
     * `fpd_units.callsign VARCHAR(32)`, reassigned at briefing. The bound
     * matches the column, and `fpd_officers.callsign` beside it: a shorter
     * one here would refuse a callsign the roster already holds, with a
     * `too_long` the supervisor cannot act on — there would be no legal way
     * to type the unit's real name.
     */
    callsign: { type: 'string', required: false, max: 32 },
    beatId: { type: 'integer', required: false, min: 1 },
    /**
     * Why. Not required by the validator because a callsign correction needs
     * no essay, and required by the handler for the changes that read as
     * discipline afterwards — taking a unit out of service, signing somebody
     * off — because those are the ones an audit entry has to explain.
     */
    reason: { type: 'string', required: false, max: 255 },
  },

  /**
   * The emergency button (7.16): a P1 call at the officer's position.
   *
   * It takes nothing at all, and that is the whole design. The position comes
   * off the ped server-side, the call type and the priority are fixed by the
   * server, the officer and their unit come from the session, and the
   * timestamp is the server clock. There is no field a client could send that
   * would make this call more accurate, and every field it could send —
   * above all a position — is one an attacker would use to put a fake officer
   * down on the other side of the map and empty a district.
   *
   * The schema exists rather than being omitted because a route that declares
   * one has every key it did not ask for dropped before the handler runs; with
   * an empty schema, that is every key (as `GroupList`).
   */
  Emergency: {},

  /**
   * A BOLO or an all-units message (7.16 [S]).
   *
   * Not pinned: a field supervisor puts out a lookout from the car as readily
   * as dispatch does from the console.
   */
  BroadcastCreate: {
    kind: { type: 'enum', required: true, values: BROADCAST_KINDS },
    /**
     * How loud it is, on the same P1–P4 scale as a call and under the same
     * `ck_fpd_broadcasts_priority` bounds. A field rather than the column
     * default, because `fpd_broadcasts.priority` is `NOT NULL` and without
     * one every broadcast on the board would be a P3 nobody chose — a BOLO
     * for a shooting suspect ranked with a road closure. Optional, so a
     * routine notice needs no decision: absent takes the column's default
     * of 3.
     */
    priority: { type: 'integer', required: false, min: 1, max: 4 },
    /** `fpd_broadcasts.title VARCHAR(191)`; this stops short of it. */
    title: { type: 'string', required: true, min: 1, max: 128 },
    /**
     * The message. Bounded, and stored as text rather than editor JSON: a
     * broadcast is radio traffic that also has to render inside a hit banner
     * (invariant 10 keeps raw HTML out of both).
     */
    body: { type: 'string', required: true, min: 1, max: 2000 },
    /**
     * The plate a lookout is for, when there is one — the primary use of a
     * broadcast, and the field a unit matches an ALPR read against by eye.
     * It lands in `fpd_broadcasts.plate`, a `VARCHAR(16)` column that 0007
     * did not originally have and that is added by the same change as this
     * comment; upper-cased and trimmed on write, like every other plate
     * column in the suite. It puts the plate on the broadcast and
     * nothing else: making an ALPR banner fire on that plate is a hotlist
     * entry, written through `AlprHotlistEdit` under `alpr.hotlist.manage`,
     * because a plate worth stopping a car over is a decision with its own
     * permission (7.18). Whoever holds `cad.broadcast` does not thereby hold
     * that one.
     */
    plate: { type: 'string', required: false, max: 16 },
    /**
     * How long it stands, in minutes, from five minutes to a week. In
     * minutes rather than as a date because an absolute time would be a
     * client-supplied timestamp (invariant 1): the server adds this to its
     * own clock and writes `fpd_broadcasts.expires_at`, which
     * `ck_fpd_broadcasts_expiry` then requires to be after `created_at`.
     * That column is nullable — a standing BOLO runs until somebody takes it
     * off the air — so absent here means the module applies the agency's
     * configured default rather than "no expiry", and a board that nobody
     * clears is the thing the default exists to prevent.
     */
    expiresInMinutes: { type: 'integer', required: false, min: 5, max: 10080 },
  },

  /**
   * Taking a broadcast off the air (7.16 [S]).
   *
   * The counterpart to `AlprHotlistEdit.remove`, as a route of its own rather
   * than a flag, because `BroadcastCreate` requires a title and a body and
   * cancelling supplies neither. Nothing is deleted: the module stamps
   * `fpd_broadcasts.cancelled_at` and `cancelled_by`, and the row stays, so
   * "what was out on the air at the time" survives the shift it was asked
   * about (0007). Without this shape the two columns, and the
   * `cad.broadcast.cancel` and `cad.broadcast.cancelled` strings that name
   * them, could never be reached at all.
   */
  BroadcastCancel: {
    id: { type: 'integer', required: true, min: 1 },
  },

  /**
   * The broadcast board (7.16 [S], 7.26): what is out on the air.
   *
   * A read, so it is gated on `page.dispatch` and on nothing else (Appendix
   * B), and not pinned: the board is the first thing a unit reads coming on
   * shift, from the car. The agency is the session's; nothing here names one.
   *
   * `idx_fpd_broadcasts_live` is `(agency_id, cancelled_at, expires_at)` and
   * `idx_fpd_broadcasts_history` is `(agency_id, created_at)`, which is why
   * `includeExpired` is a flag and not a date range: the live board and the
   * history are two different index reads, and a window would be neither.
   */
  BroadcastList: {
    /**
     * Absent means what is on the air now — neither cancelled nor expired.
     * True adds the ones that have come off it, which is how "what was out
     * at the time" is answered after an arrest; nothing is ever deleted, so
     * the history is complete (0007).
     */
    includeExpired: { type: 'boolean', required: false },
    /** One kind at a time — the BOLO board without the briefing notes. */
    kind: { type: 'enum', required: false, values: BROADCAST_KINDS },
    /** The call a broadcast came out of, when the board is read from a card. */
    callId: { type: 'integer', required: false, min: 1 },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  /**
   * The beats and districts of one agency (7.17): the polygons the map draws,
   * and the list the intake form's beat picker offers.
   *
   * It takes nothing at all. The agency comes from the session; the set is
   * small — 0007 budgets the tagger against an agency that has drawn thirty
   * districts — so there is nothing to page through, and the map needs all of
   * it at once or it draws a district with a hole in it. There is no `kind`
   * filter because a district *is* a beat with a lower precedence in the same
   * table, and both are drawn; and no `enabled` filter, because a beat taken
   * out of use is not drawn and not offered. `fpd_beats.enabled` is how a
   * beat goes out of use without being deleted, and that is the point:
   * `fpd_calls.beat_id` is `ON DELETE SET NULL`, so deleting a beat would
   * quietly untag every call it had ever held.
   *
   * The polygons come back; no position goes out. A beat is a row, and asking
   * for the beat map says nothing about where the asker is standing.
   */
  BeatList: {},

  /**
   * The map payload: units and calls, for a session with the map open (7.17).
   *
   * Positions travel one way. The answer carries where the units are, read
   * server-side off their peds; the request carries nothing about where
   * anybody is, and the subscription is what makes the 1–2 second AVL push
   * legal at all — 3.6 pushes only to sessions with the map open, and budget
   * 12.1 is why that matters at two hundred players.
   *
   * Every position in the answer has passed the same access check as a read
   * (invariants 4 and 5): this is not a broadcast, and a session sees the
   * units of the agencies it is allowed to see.
   */
  MapView: {
    /**
     * True or absent: "the map is open, subscribe me and send the snapshot".
     * False: "it is closed, stop pushing". The close half is a field rather
     * than a second route because a session that disappears without saying so
     * is already handled by the session layer, and one route means one place
     * the subscription is written.
     */
    subscribe: { type: 'boolean', required: false },
  },

  /**
   * Plate reads (7.18 [S]). A read is written server-side from the radar
   * bridge with the time, the place and the unit; this route only reads them
   * back, and every field is a filter.
   */
  AlprReadList: {
    plate: { type: 'string', required: false, min: 2, max: 16 },
    /**
     * Whose reads. An `fpd_units.officer_id`, which is the same number
     * `fpd_alpr_reads.officer_id` carries — that column is nulled when the
     * roster row goes, so filtering by it answers "the reads of an officer
     * who is still on the roster", and the reads of one who is not are
     * reached by plate and time like any other. Auditable, like any query.
     */
    officerId: { type: 'integer', required: false, min: 1 },
    /**
     * A window in hours rather than a pair of timestamps: reads are kept for
     * thirty days by the retention job (7.18), so 720 is the whole file and
     * anything older is gone. A client-supplied datetime would be a client
     * choosing what "now" means, and the server would have to defend against
     * a range that reads the table end to end.
     */
    sinceHours: { type: 'integer', required: false, min: 1, max: 720 },
    /** Only the reads that raised a hotlist hit. */
    hitsOnly: { type: 'boolean', required: false },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  /**
   * Adding and removing a hotlist plate (7.18).
   *
   * One route both ways, for the same reason the vehicle hot file has one:
   * a single path means one place the reason, the audit entry and the
   * expiry are enforced. Putting a plate on the hotlist is putting a red
   * banner in front of an officer about to stop a car, so it is written down
   * or it does not happen.
   */
  AlprHotlistEdit: {
    plate: { type: 'string', required: true, min: 2, max: 16 },
    /**
     * True removes the plate — which stamps `fpd_hotlist.cancelled_at` and
     * `cancelled_by` and leaves the row, so a read that matched it still
     * points at why (0007).
     *
     * `uq_fpd_hotlist_live` is `(agency_id, plate, reason, live)`, so one
     * plate can be listed under two reasons at once — stolen, and wanted by
     * an investigator. A removal that names a `reason` takes that entry; one
     * that does not takes every live entry for the plate, which is what
     * `alpr.hotlist.removeConfirm` asks about by plate alone.
     */
    remove: { type: 'boolean', required: false },
    /**
     * Why the banner fires. Optional here and required by the handler when
     * adding, because a removal has nothing to justify — the schema cannot
     * express "required unless `remove`".
     */
    reason: { type: 'enum', required: false, values: HOTLIST_REASONS },
    /**
     * The detail the banner shows under the reason, stored in
     * `fpd_hotlist.detail` (`VARCHAR(512)`; this stops short of it).
     */
    note: { type: 'string', required: false, max: 255 },
    /** `fpd_hotlist.case_number VARCHAR(32)`. */
    caseNumber: { type: 'string', required: false, max: 32 },
    /**
     * The surveillance case (7.18, section 9), stored in
     * `fpd_hotlist.silent`: the read is logged and the hit is recorded
     * against the entry, and the unit is told nothing. Without this field the
     * column could never be anything but its default of 0, and the two
     * locale strings that explain it (`alpr.hotlist.silent` and
     * `alpr.hotlist.silentHint`) would label a control that sets nothing.
     *
     * It is a flag on the entry rather than a separate list because the check
     * an ALPR read runs is one query either way, and a second table would be
     * a second place to forget the expiry. Who may set it is the handler's
     * question, not the schema's: `alpr.hotlist.manage` puts a plate on the
     * list, and a silent entry is the one a subject must not be able to
     * discover — including when the subject is the officer reading the board.
     */
    silent: { type: 'boolean', required: false },
    /**
     * Optional expiry, in minutes, up to thirty days — the same horizon as
     * read retention. Absent means it stands until somebody removes it, which
     * is right for a stolen vehicle and wrong for a one-shift lookout.
     */
    expiresInMinutes: { type: 'integer', required: false, min: 5, max: 43200 },
  },

  /**
   * The hotlist itself (7.18): which plates are listed, why, by whom and
   * until when.
   *
   * This is the management screen behind `AlprHotlistEdit`, so it is read
   * with `alpr.hotlist.manage` rather than with `alpr.read.view`: the reads
   * file says which cars drove past a camera, and this says which cars an
   * officer will be stopped from driving away in. An officer who holds only
   * `alpr.read.view` still sees the entry behind a banner they were shown —
   * that is part of the hit, not this list.
   *
   * A silent entry (`fpd_hotlist.silent`) is a surveillance target and is not
   * part of that read: the whole point is that the subject learns nothing,
   * and the subject is sometimes an officer with a login. Which rows come
   * back is the handler's decision under section 9, not a filter here, and
   * there is deliberately no `silent` field on this list to ask for them by.
   */
  AlprHotlistList: {
    /** One plate, when the question is "is this car listed, and why". */
    plate: { type: 'string', required: false, min: 2, max: 16 },
    reason: { type: 'enum', required: false, values: HOTLIST_REASONS },
    /**
     * Absent means the live list — not cancelled, not expired — which is what
     * `idx_fpd_hotlist_check` answers and what an entry has to be on to raise
     * a banner. True adds the ones that have come off it, which is how an
     * entry is reviewed before it is put back on.
     */
    includeExpired: { type: 'boolean', required: false },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  // ------------------------------------------------------------------- brott

  /**
   * Brottskatalogen (spec 7.10). The catalogue is read by everyone who writes
   * a record and edited by almost nobody, which is why `BrottList` takes no
   * input at all: the agency comes from the session, and there is nothing to
   * filter by that the client should be choosing.
   */
  BrottList: {},

  BrottVersions: {
    code: { type: 'string', required: true, min: 1, max: 32 },
  },

  /**
   * The charge set a gemensam straffskala is computed over (BrB 26:2).
   *
   * A string list because the validator has no integer-list type; the server
   * parses and bounds them (`Brott.parseIds`) and refuses the whole request if
   * one entry is not an id.
   *
   * **Duplicates are meaningful here** and the server keeps them, unlike
   * `LabRequestCreate.evidenceIds` where a repeat is a double charge to the
   * lab. Three counts of one offence is three entries of the same catalogue
   * id, and collapsing them would understate the very calculation BrB 26:2
   * exists to perform. `maxItems` is what stops one record arriving with a
   * thousand counts and turning the span arithmetic into a loop worth
   * profiling.
   */
  BrottStraffskala: {
    brottIds: { type: 'string[]', required: true, maxItems: 25, maxLength: 20 },
  },

  /**
   * Adding an offence, or adding a version of one. The same shape for both:
   * a new version is the whole row as it should now read, not a patch, because
   * 7.10's rule is that a version is immutable once records cite it and a
   * partial update has no immutable row to be partial against.
   *
   * The straffskala arrives as three fields rather than one object because
   * the validator is flat, and the cross-field rules between them — a floor
   * above a ceiling, böter alongside a fängelse floor, a fixed term above
   * eighteen years — are checked by `Brott.validate`, which is the same set of
   * rules migration 0008 carries as CHECK constraints.
   *
   * `fangelseMaxMonths` absent means **livstid**, not zero. That is why it is
   * not required and why it has no default: a missing ceiling is a legal fact
   * about the offence, and a schema that filled in a number would quietly turn
   * mord into a fixed-term offence.
   */
  BrottCreate: {
    code: { type: 'string', required: true, min: 1, max: 32 },
    balk: { type: 'string', required: false, max: 16 },
    kapitel: { type: 'integer', required: false, min: 1, max: 255 },
    paragraf: { type: 'integer', required: false, min: 1, max: 255 },
    stycke: { type: 'integer', required: false, min: 1, max: 255 },
    labelKey: { type: 'string', required: true, min: 1, max: 128 },
    descriptionKey: { type: 'string', required: false, max: 128 },
    grad: { type: 'enum', required: true, values: BROTT_GRADER },
    boter: { type: 'boolean', required: false },
    // 216 months is eighteen years, the ceiling on a fixed term (BrB 26:1).
    fangelseMinMonths: { type: 'integer', required: false, min: 0, max: 216 },
    fangelseMaxMonths: { type: 'integer', required: false, min: 0, max: 216 },
    forsok: { type: 'boolean', required: false },
    forberedelse: { type: 'boolean', required: false },
    preskriptionYears: { type: 'integer', required: false, min: 1, max: 100 },
  },

  // ----------------------------------------------------------------- anmälan

  /**
   * The Records list (spec 7.7).
   *
   * `mine` is a filter the client asks for; the identity it filters on is the
   * session's own, taken on the server (invariant 1). There is deliberately no
   * `createdBy` field: an officer id arriving in input is an attack, not a
   * field, and a list route that accepted one would answer "show me what that
   * officer has been writing" to anybody who could type a Discord id.
   *
   * `includeSupplements` is off by default because a tilläggsuppgift belongs
   * under its parent; a flat list mixing them in reads as duplicates of
   * reports the officer has already seen.
   */
  AnmalanList: {
    status: { type: 'enum', required: false, values: ANMALAN_STATUSES },
    mine: { type: 'boolean', required: false },
    fuId: { type: 'integer', required: false, min: 1 },
    includeSupplements: { type: 'boolean', required: false },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  /** One anmälan by id, and the shape every transition route takes. */
  AnmalanGet: {
    id: { type: 'integer', required: true, min: 1 },
    /**
     * Optimistic locking. Absent on a plain read; required in practice on a
     * transition, where a stale version is the difference between "approve
     * what I reviewed" and "approve whatever it says now".
     */
    version: { type: 'integer', required: false, min: 1 },
  },

  /** Returning an anmälan carries the supervisor's reason. */
  AnmalanReturn: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: false, min: 1 },
    /**
     * Free text, not a locale key: this is one officer writing to another
     * about this particular report, which is the one kind of string that
     * cannot be a key. Bounded, because it is rendered in a panel.
     */
    note: { type: 'string', required: false, max: 2000 },
  },

  /**
   * Writing an anmälan. `parentId` makes it a tilläggsuppgift.
   *
   * `handelseforlopp` is **editor JSON** (invariant 10), arriving as a string
   * and stored in a JSON column that refuses anything else — which is what
   * stops raw HTML reaching the record, at the database rather than on trust.
   */
  AnmalanCreate: {
    title: { type: 'string', required: true, min: 1, max: 191 },
    parentId: { type: 'integer', required: false, min: 1 },
    fuId: { type: 'integer', required: false, min: 1 },
    callId: { type: 'integer', required: false, min: 1 },
    handelseforlopp: { type: 'string', required: false, max: 60000 },
    occurredAt: { type: 'string', required: false, max: 32 },
    occurredPlace: { type: 'string', required: false, max: 191 },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
  },

  AnmalanUpdate: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
    title: { type: 'string', required: false, min: 1, max: 191 },
    handelseforlopp: { type: 'string', required: false, max: 60000 },
    occurredAt: { type: 'string', required: false, max: 32 },
    occurredPlace: { type: 'string', required: false, max: 191 },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
    fuId: { type: 'integer', required: false, min: 1 },
  },

  /**
   * The charge list, as three parallel lists.
   *
   * Parallel rather than nested because the validator is flat, and the server
   * refuses the request unless they line up — a charge silently attributed to
   * the wrong misstänkt is worse than a refusal the officer can see.
   *
   * `brottIds` keeps its duplicates: three counts of one offence is three
   * entries, which is what BrB 26:2 computes over. `personIds` may carry an
   * empty string for a count against nobody in particular, which is the
   * ordinary case rather than an incomplete record.
   */
  AnmalanCharges: {
    id: { type: 'integer', required: true, min: 1 },
    brottIds: { type: 'string[]', required: true, maxItems: 25, maxLength: 20 },
    /**
     * Not an enum field, because the validator has no enum-list type. The
     * server checks each entry against `BROTT_STAGES` *and* against the
     * catalogue row it applies to (`Anmalan.stageIsAvailable`), which is the
     * stricter test anyway: `forsok` is a valid stage everywhere and a valid
     * charge only where the statute makes the attempt punishable.
     */
    stages: { type: 'string[]', required: false, maxItems: 25, maxLength: 16 },
    personIds: { type: 'string[]', required: false, maxItems: 25, maxLength: 20 },
  },

  AnmalanPerson: {
    id: { type: 'integer', required: true, min: 1 },
    personId: { type: 'integer', required: true, min: 1 },
    roll: { type: 'enum', required: true, values: ANMALAN_ROLLER },
    note: { type: 'string', required: false, max: 255 },
  },

  // --------------------------------------------------------- förundersökning

  FuList: {
    status: { type: 'enum', required: false, values: FU_STATUSES },
    /** The investigations this session leads. Identity from the session. */
    mine: { type: 'boolean', required: false },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  FuGet: {
    id: { type: 'integer', required: true, min: 1 },
  },

  FuCreate: {
    title: { type: 'string', required: true, min: 1, max: 191 },
    /**
     * Who leads it. Absent means the officer opening it, which is the ordinary
     * case — an FU with no ledare is not a state RB allows.
     */
    fuLedare: { type: 'string', required: false, max: 32 },
    ledareKind: { type: 'enum', required: false, values: FU_LEDARE_KINDS },
    intelCaseId: { type: 'integer', required: false, min: 1 },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
  },

  /**
   * Reassigning an investigation. Both fields, always: setting the person
   * without the capacity leaves the row claiming a prosecutor leads it as a
   * police officer, and the tvångsmedel rules read that column.
   */
  FuAssign: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
    fuLedare: { type: 'string', required: true, min: 1, max: 32 },
    ledareKind: { type: 'enum', required: true, values: FU_LEDARE_KINDS },
  },

  /**
   * A decision in a förundersökning: slutdelge, redovisa or lägg ned.
   *
   * `reason` is a **locale key**, not a sentence (invariant 6): a nedläggning
   * is quoted afterwards, and "brott kan ej styrkas" has to read the same way
   * every time and in both languages. The free text beside it is the
   * FU-ledare's own note on this particular case, which is the half that
   * cannot be a key.
   */
  FuDecision: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
    reason: { type: 'string', required: false, max: 128 },
    note: { type: 'string', required: false, max: 2000 },
  },

  // ------------------------------------------------------- frihetsberövande

  /**
   * Everybody the agency is currently holding — the list a supervisor watches
   * the statutory countdowns on. No filter at all: "who is in our cells right
   * now" has one answer, and a filter on it would only ever be used to make
   * the answer shorter than it is.
   */
  FrihetOpen: {
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  FrihetList: {
    status: { type: 'enum', required: false, values: FRIHET_STATUSES },
    personId: { type: 'integer', required: false, min: 1 },
    fuId: { type: 'integer', required: false, min: 1 },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  FrihetGet: {
    id: { type: 'integer', required: true, min: 1 },
  },

  /**
   * Recording a gripande (RB 24:7).
   *
   * **There is no time field, and there must not be.** The moment a person was
   * arrested is what every statutory deadline in this module is measured from —
   * RB 24:12's noon and RB 24:13's four dygn both run from it — so the server
   * stamps it from its own clock (invariant 1). A client that could choose it
   * could move a deadline it had already missed.
   *
   * `grund` is a locale key naming the ground for the arrest, never a
   * sentence (invariant 6): it is quoted afterwards, and it has to read the
   * same way every time and in both languages.
   */
  FrihetGripande: {
    personId: { type: 'integer', required: true, min: 1 },
    grund: { type: 'string', required: true, min: 1, max: 128 },
    plats: { type: 'string', required: false, max: 191 },
    fuId: { type: 'integer', required: false, min: 1 },
    anmalanId: { type: 'integer', required: false, min: 1 },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
  },

  /**
   * A decision in the chain: anhållande, framställan, häktning or frigivande.
   *
   * One shape for all four, because they differ in who may take them and in
   * nothing a client sends. Which capacity a session acts in is derived from
   * its permissions on the server and is deliberately not a field here: a
   * client that could name its own capacity could anhålla itself.
   */
  FrihetDecision: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
    /** A locale key. Required for an anhållande and for a release. */
    grund: { type: 'string', required: false, max: 128 },
  },

  FrihetCharges: {
    id: { type: 'integer', required: true, min: 1 },
    brottIds: { type: 'string[]', required: true, maxItems: 25, maxLength: 20 },
  },

  /**
   * The custody log: förhör, the defence lawyer's arrival, meals, the calls a
   * detainee is entitled to.
   *
   * `kind` is a locale key and not an enum, because what a department logs is a
   * matter of its own routines rather than of what the law names — an enum here
   * would need a migration before a server could record something its own
   * orders require.
   */
  FrihetLog: {
    id: { type: 'integer', required: true, min: 1 },
    kind: { type: 'string', required: true, min: 1, max: 64 },
    note: { type: 'string', required: false, max: 500 },
  },

  // ------------------------------------------------------------- tvångsmedel

  TvangList: {
    kind: { type: 'enum', required: false, values: TVANG_KINDS },
    fuId: { type: 'integer', required: false, min: 1 },
    /** Only measures that authorise something right now. */
    liveOnly: { type: 'boolean', required: false },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  TvangGet: {
    id: { type: 'integer', required: true, min: 1 },
  },

  /**
   * Deciding a coercive measure (RB 27-28).
   *
   * **`deciderKind` is not a field.** The capacity a session decides in comes
   * from its permissions on the server: a client that could name its own
   * capacity could decide a kroppsbesiktning as though it were a prosecutor.
   *
   * `validSeconds` bounds the decision in time. Absent gives the module's
   * default, which exists because a decision with no end is a standing
   * authority to enter somebody's home — not a thing RB grants.
   *
   * `grund` is a locale key naming the ground, never a sentence (invariant 6);
   * `scope` is the free text saying what may be searched for and seized, which
   * is the one part that genuinely cannot be a key.
   */
  TvangDecide: {
    kind: { type: 'enum', required: true, values: TVANG_KINDS },
    targetKind: { type: 'enum', required: true, values: TVANG_TARGETS },
    targetId: { type: 'integer', required: true, min: 1 },
    targetLabel: { type: 'string', required: false, max: 191 },
    fuId: { type: 'integer', required: false, min: 1 },
    grund: { type: 'string', required: true, min: 1, max: 128 },
    scope: { type: 'string', required: false, max: 500 },
    // One hour to thirty days. The floor stops a measure that expires before
    // anybody can act on it; the ceiling stops one that is a standing authority
    // in all but name.
    validSeconds: { type: 'integer', required: false, min: 3600, max: 2592000 },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
  },

  TvangVerkstall: {
    id: { type: 'integer', required: true, min: 1 },
    note: { type: 'string', required: false, max: 500 },
  },

  TvangUpphav: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
  },

  // ------------------------------------------------------------ efterlysning

  EfterlysningList: {
    grund: { type: 'enum', required: false, values: EFTERLYSNING_GRUNDER },
    includeCancelled: { type: 'boolean', required: false },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  /**
   * Wanting somebody (spec 7.13).
   *
   * `expiresInSeconds` absent means the efterlysning stands until it is
   * cancelled, which is the right default for an anhållen i sin frånvaro: the
   * prosecutor's decision does not lapse because time passed.
   */
  EfterlysningCreate: {
    personId: { type: 'integer', required: true, min: 1 },
    grund: { type: 'enum', required: true, values: EFTERLYSNING_GRUNDER },
    frihetId: { type: 'integer', required: false, min: 1 },
    fuId: { type: 'integer', required: false, min: 1 },
    note: { type: 'string', required: false, max: 500 },
    priority: { type: 'integer', required: false, min: 1, max: 4 },
    expiresInSeconds: { type: 'integer', required: false, min: 3600, max: 31536000 },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
  },

  EfterlysningCancel: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
    grund: { type: 'string', required: false, max: 128 },
  },

  // ---------------------------------------------------------------- spaning

  SpaningList: {
    targetKind: { type: 'enum', required: false, values: SPANING_TARGETS },
    /** At most this priority number, so 1 gives only the loudest. */
    priority: { type: 'integer', required: false, min: 1, max: 4 },
    includeResolved: { type: 'boolean', required: false },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  SpaningGet: {
    id: { type: 'integer', required: true, min: 1 },
  },

  /**
   * Raising a lookout (7.13).
   *
   * `targetId` and `description` are both optional **individually** and the
   * server refuses a request carrying neither: a lookout has to be for
   * something. That rule cannot be expressed in a flat schema, so it lives in
   * `Spaning.validate` and in a CHECK in 0012, and the schema's job here is
   * only to bound what arrives.
   *
   * `priority` is what decides how loudly an officer is interrupted
   * (`Spaning.bannerFor`), and 1 is the only value that reaches a banner. It
   * defaults to 3 rather than to 1, because the expensive mistake is the loud
   * one: an officer shown a red banner for every "have a look for this van"
   * learns within a shift to ignore red banners.
   */
  SpaningCreate: {
    targetKind: { type: 'enum', required: true, values: SPANING_TARGETS },
    targetId: { type: 'integer', required: false, min: 1 },
    description: { type: 'string', required: false, max: 500 },
    grund: { type: 'string', required: true, min: 1, max: 128 },
    priority: { type: 'integer', required: false, min: 1, max: 4 },
    beatId: { type: 'integer', required: false, min: 1 },
    areaNote: { type: 'string', required: false, max: 191 },
    fuId: { type: 'integer', required: false, min: 1 },
    anmalanId: { type: 'integer', required: false, min: 1 },
    // An hour to ninety days. Unlike an efterlysning there is no "until
    // cancelled": a lookout that never expires is a banner that stays up until
    // somebody remembers a van from three months ago.
    validSeconds: { type: 'integer', required: false, min: 3600, max: 7776000 },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
  },

  SpaningResolve: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
    grund: { type: 'string', required: false, max: 128 },
  },

  // ------------------------------------------------- surveillance (spec 9)

  HakList: {
    fuId: { type: 'integer', required: false, min: 1 },
    status: { type: 'enum', required: false, values: HAK_STATUSES },
    /** Only measures that are `beviljad` and inside their window right now. */
    liveOnly: { type: 'boolean', required: false },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  HakGet: {
    id: { type: 'integer', required: true, min: 1 },
  },

  /**
   * The åklagare's application (RB 27:18, 27:20d).
   *
   * No `deciderKind` and no `status` field, for the same reason `TvangDecide`
   * has neither: both are the server's to set. A request always starts
   * `begard` — only `hak.grant` and `hak.refuse`, gated on the domare
   * capacity, may move it.
   */
  HakRequest: {
    fuId: { type: 'integer', required: true, min: 1 },
    targetKind: { type: 'enum', required: true, values: HAK_TARGETS },
    targetId: { type: 'integer', required: false, min: 1 },
    targetLabel: { type: 'string', required: false, max: 191 },
    method: { type: 'enum', required: true, values: HAK_METHODS },
    grund: { type: 'string', required: true, min: 1, max: 128 },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
  },

  /**
   * The domare's grant. `validSeconds` bounds the window the same way
   * `TvangDecide.validSeconds` does, and for the same reason: a secret
   * measure with no end is a standing authority to listen, which RB does not
   * grant either.
   */
  HakGrant: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
    courtRef: { type: 'string', required: false, max: 64 },
    validSeconds: { type: 'integer', required: false, min: 3600, max: 2592000 },
  },

  HakRefuse: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
    grund: { type: 'string', required: true, min: 1, max: 128 },
  },

  HakUpphav: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
    grund: { type: 'string', required: false, max: 128 },
  },

  HakInterceptAdd: {
    hakId: { type: 'integer', required: true, min: 1 },
    kind: { type: 'string', required: true, min: 1, max: 64 },
    summary: { type: 'string', required: false, max: 500 },
    mediaRef: { type: 'string', required: false, max: 191 },
  },

  HakSessionStart: {
    hakId: { type: 'integer', required: true, min: 1 },
  },

  HakSessionEnd: {
    id: { type: 'integer', required: true, min: 1 },
    minimizationNote: { type: 'string', required: false, max: 500 },
  },

  HakLog: {
    hakId: { type: 'integer', required: true, min: 1 },
  },

  // -------------------------------------------------------- court (spec 7.20)

  CourtReferralList: {
    beslut: { type: 'enum', required: false, values: ATAL_BESLUT },
    /** Only `atalad` rows with no disposition yet — the domare's own queue. */
    awaitingDisposition: { type: 'boolean', required: false },
    limit: { type: 'integer', required: false, min: 1, max: 200 },
  },

  CourtReferralPending: {},

  CourtReferralGet: {
    id: { type: 'integer', required: true, min: 1 },
  },

  /**
   * The åklagare's charging decision on a redovisad FU (7.8, 7.20).
   *
   * `brottIds` and `stages` are required only for `beslut: 'atalad'` —
   * `Court.validateReferral` enforces that, because a flat schema cannot say
   * "required unless this other field is 'ej_atal'". Duplicates in
   * `brottIds` survive: three counts of one offence is three rows, the same
   * reasoning `AnmalanCharges` gives.
   */
  CourtReferralDecide: {
    fuId: { type: 'integer', required: true, min: 1 },
    beslut: { type: 'enum', required: true, values: ATAL_BESLUT },
    beslutGrund: { type: 'string', required: false, max: 128 },
    brottIds: { type: 'string[]', required: false, maxItems: 25, maxLength: 20 },
    // Not an enum field, for the reason `AnmalanCharges.stages` gives: the
    // server checks each entry against `BROTT_STAGES` *and* against the
    // catalogue row it applies to (`Anmalan.stageIsAvailable`).
    stages: { type: 'string[]', required: false, maxItems: 25, maxLength: 16 },
    classification: { type: 'enum', required: false, values: CLASSIFICATIONS },
  },

  /**
   * The domare's disposition. `sentenceMonths` is checked against
   * `Brott.gemensamStraffskala` for the åtal's own charges in the route —
   * the schema only bounds the number itself, generously, because the real
   * bound depends on which charges are on the row.
   */
  CourtDispositionEnter: {
    id: { type: 'integer', required: true, min: 1 },
    version: { type: 'integer', required: true, min: 1 },
    disposition: { type: 'enum', required: true, values: ATAL_DISPOSITIONS },
    sentenceMonths: { type: 'integer', required: false, min: 0, max: 216 },
    sentenceLivstid: { type: 'boolean', required: false },
    note: { type: 'string', required: false, max: 500 },
  },

} as const satisfies Record<string, Schema>;

export type SchemaName = keyof typeof schemas;
