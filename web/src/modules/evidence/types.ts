/**
 * What the evidence routes send back (spec 8).
 *
 * These mirror `FredPD.Modules.evidence.public()` exactly, which is an
 * allowlist: an evidence row reaches a client with these fields and no others.
 * What is deliberately absent is the point of the shape — no owner, no weapon
 * serial, no sample quality (8.11). If a field appears here that the server
 * does not send, the interface is inventing it.
 */

import type { LabAnalysis } from '../lab/types';

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
  /**
   * This item's lab analyses, gated the same way `evidence.get` gates them
   * (8.11): present only when `evidence.list` was called with `caseNumber`,
   * absent otherwise. `resultCode`/`observations` on each entry are further
   * withheld until the analysis is finished and the reader is cleared for
   * lab conclusions — see `LabAnalysis`.
   */
  analyses?: LabAnalysis[];
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
