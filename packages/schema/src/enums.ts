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
