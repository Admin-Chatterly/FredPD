import {
  CLASSIFICATIONS,
  EVIDENCE_DESTINATIONS,
  EVIDENCE_PACKAGING,
  EVIDENCE_STATUSES,
  EVIDENCE_TYPES,
  INTEL_CASE_STATUSES,
  INTEL_CONFIDENCE,
  INTEL_ORG_STATUSES,
  INTEL_ORG_TYPES,
  INTEL_PERSON_STATUSES,
  INTEL_SOURCES,
  LAB_ANALYSES,
  LAB_ANALYSIS_STATUSES,
  LAB_PRIORITIES,
  PLACEMENT_INTERACTIONS,
  PLACEMENT_KINDS,
  SCENE_STATUSES,
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

  // `traceKey` is the opaque key the client was handed with render data, and it
  // is the only thing collection takes from the call. The type and the owner
  // come from the server-side grid: a client that could name either could
  // collect a casing as a blood swab, or frame anybody (8.1, 8.3).
  EvidenceCollect: {
    traceKey: { type: 'string', required: true, min: 1, max: 64 },
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
  },

  // Observations are how the analyst worked. The conclusion is not here and
  // never will be: the server computes it (8.7).
  LabAnalysisComplete: {
    id: { type: 'integer', required: true, min: 1 },
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
} as const satisfies Record<string, Schema>;

export type SchemaName = keyof typeof schemas;
