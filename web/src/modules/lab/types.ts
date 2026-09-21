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
}
