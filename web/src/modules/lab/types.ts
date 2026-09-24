/**
 * What the lab routes send back (spec 8.7).
 *
 * Mirrors `FredPD.Modules.evidence.analysisPublic()`. The queue is readable
 * long before a conclusion exists — an analyst has to see what is waiting, who
 * has it and when it is due — so `resultCode` and `observations` are optional
 * here in the type as well as on the wire: they arrive only when the analysis
 * has finished *and* the reader is cleared for lab conclusions (8.11).
 */

export interface LabAnalysis {
  id: number;
  requestId: number;
  evidenceId: number;
  evidenceNumber: string | null;
  analysis: string;
  status: string;
  /** The analyst's Discord id, set when the analysis is started. */
  assignedTo: string | null;
  startedAt: string | null;
  /** Persisted, so the wait survives a restart. Never counted down client-side. */
  dueAt: string | null;
  completedAt: string | null;
  priority: string;
  caseNumber: string | null;
  resultCode?: string | null;
  observations?: string | null;
  /**
   * Who a candidate match points at (0030), as far as this reader may read
   * them. A lead, never an identification (8.1.3).
   */
  candidates?: LabCandidate[];
  /** How many more candidates exist that this reader may not see. */
  candidatesWithheld?: number;
}

export interface LabCandidate {
  id: number;
  personNumber: string;
  firstName: string | null;
  lastName: string | null;
}
