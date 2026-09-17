import {
  CLASSIFICATIONS,
  INTEL_CASE_STATUSES,
  INTEL_CONFIDENCE,
  INTEL_ORG_STATUSES,
  INTEL_ORG_TYPES,
  INTEL_PERSON_STATUSES,
  INTEL_SOURCES,
  PLACEMENT_INTERACTIONS,
  PLACEMENT_KINDS,
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
