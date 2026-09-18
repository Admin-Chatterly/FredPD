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
  CLASSIFICATIONS,
  CUSTODY_ACTIONS,
  EVIDENCE_DESTINATIONS,
  EVIDENCE_PACKAGING,
  EVIDENCE_SEAL_STATES,
  EVIDENCE_STATUSES,
  EVIDENCE_TYPES,
  FIREARM_EVENTS,
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
  LAB_REQUEST_STATUSES,
  LAB_RESULT_CODES,
  PERSON_CAUTION_KINDS,
  PERSON_SEXES,
  PLACEMENT_ACCESS_POINTS,
  PLACEMENT_INTERACTIONS,
  PLACEMENT_KINDS,
  SCENE_STATUSES,
  UNIT_STATUSES,
  VEHICLE_FLAG_KINDS,
  VEHICLE_INSURANCE_STATUSES,
  VEHICLE_REGISTRATION_STATUSES,
} from './enums';
export type {
  AccessPoint,
  Classification,
  CustodyAction,
  EvidenceDestination,
  EvidencePackaging,
  EvidenceSealState,
  EvidenceStatus,
  EvidenceType,
  FirearmEvent,
  FirearmStatus,
  FirearmType,
  IntelCaseStatus,
  IntelConfidence,
  IntelOrgStatus,
  IntelOrgType,
  IntelPersonStatus,
  IntelSource,
  LabAnalysisKind,
  LabAnalysisStatus,
  LabPriority,
  LabRequestStatus,
  LabResultCode,
  PersonCautionKind,
  PersonSex,
  PlacementInteraction,
  PlacementKind,
  SceneStatus,
  UnitStatus,
  VehicleFlagKind,
  VehicleInsuranceStatus,
  VehicleRegistrationStatus,
} from './enums';

export { schemas } from './schemas';
export type { FieldSpec, Schema, SchemaName } from './schemas';
