/**
 * What the evidence routes send back (spec 8).
 *
 * These mirror `FredPD.Modules.evidence.public()` exactly, which is an
 * allowlist: an evidence row reaches a client with these fields and no others.
 * What is deliberately absent is the point of the shape — no owner, no weapon
 * serial, no sample quality (8.11). If a field appears here that the server
 * does not send, the interface is inventing it.
 */

export interface EvidenceItem {
  id: number;
  /** The opaque reference carried by the item in the world, never the owner. */
  ref: string;
  evidenceNumber: string;
  type: string;
  packaging: string | null;
  sealState: string;
  markerNumber: number | null;
  description: string | null;
  caseNumber: string | null;
  sceneId: number | null;
  collectedAt: string;
  /** Assigned at property room intake; null until the item is accepted (8.6). */
  storageLocation: string | null;
  status: string;
}

/** One link in the chain of custody (8.6). Append-only on the server. */
export interface CustodyEntry {
  id: number;
  action: string;
  fromParty: string | null;
  toParty: string | null;
  reason: string | null;
  /** The Discord id that signed it. The server signs; the call never says who. */
  signedBy: string;
  occurredAt: string;
}

export interface Scene {
  id: number;
  sceneNumber: string;
  caseNumber: string | null;
  x: number;
  y: number;
  z: number;
  radius: number;
  status: string;
  createdBy: string | null;
  createdAt: string;
  releasedBy: string | null;
  releasedAt: string | null;
  /** Only on the list, which counts them per scene. */
  evidenceCount?: number;
  entryCount?: number;
}

/**
 * A trace the officer is standing at, pushed by the client (8.3.6).
 *
 * The key is opaque and the type comes from the render data the client already
 * holds. Neither is a claim the interface makes: `evidence.collect` reads the
 * real type and the owner from the server's own grid and ignores anything the
 * call says about them.
 */
export interface PendingTrace {
  traceKey: string;
  /**
   * Null when the client's push carried no type. That is a legitimate state,
   * not a defect to paper over with an empty string: the server reads the real
   * type from its own grid, so a trace the client cannot name is still
   * collectable. The form simply says nothing about what it is.
   */
  type: string | null;
  sceneId: number | null;
}
