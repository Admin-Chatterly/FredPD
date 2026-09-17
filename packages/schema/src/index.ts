/**
 * The shared schema package.
 *
 * One definition of every route's input shape and every shared enumeration,
 * consumed three ways: TypeScript types for the NUI and the gateway, and
 * generated Lua validator tables for the server (spec 3.5, 17.2).
 *
 * M1 adds the route and entity schemas themselves. M0 establishes the package
 * and the generation step, so nothing is ever hand-copied between Lua and TS.
 */

export { ERROR_CODES, isErrorCode } from './errors';
export type { ErrorCode } from './errors';

export {
  ACCESS_POINTS,
  PLACEMENT_ACCESS_POINTS,
  PLACEMENT_INTERACTIONS,
  PLACEMENT_KINDS,
  UNIT_STATUSES,
} from './enums';
export type { AccessPoint, PlacementInteraction, PlacementKind, UnitStatus } from './enums';

export { schemas } from './schemas';
export type { FieldSpec, Schema, SchemaName } from './schemas';
