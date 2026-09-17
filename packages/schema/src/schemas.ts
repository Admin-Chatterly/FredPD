import { PLACEMENT_INTERACTIONS, PLACEMENT_KINDS } from './enums';

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
  | { type: 'enum'; required?: boolean; values: readonly string[] };

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
} as const satisfies Record<string, Schema>;

export type SchemaName = keyof typeof schemas;
