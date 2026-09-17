/**
 * Shared enumerations (spec 1.4, 7.1). Mirrored into Lua by `src/generate.ts`,
 * so `shared/enums.lua` and this file cannot drift.
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
