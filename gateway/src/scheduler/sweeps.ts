import type { GatewayConfig } from '../config.js';
import type { SchedulerDb } from './db.js';

/**
 * **Superseded by ADR-021:** retention now runs inside FXServer
 * (`server/modules/retention/`), which every install has. This file stays
 * for an install that already runs the scheduler; new sweeps go there, not
 * here.
 *
 * The scheduled sweeps spec 13.3 asked the gateway scheduler to run: the
 * lapsed-lookout sweeper, and retention over drafts, ALPR reads, query logs
 * and surveillance sessions.
 *
 * **Closed scenes are deliberately not here.** `fpd_evidence_items` and
 * `fpd_scene_entries` reference `fpd_scenes` with `ON DELETE CASCADE`
 * (0002), so deleting an old released scene would take its evidence chain of
 * custody with it — the one category retention cannot safely apply as a
 * DELETE without an archival design (cold storage, or a redaction pass that
 * keeps the chain intact) that is a policy decision, not an engineering one,
 * and this sweep does not make it unasked. Scenes stay until that design
 * exists.
 *
 * Every statement is a fixed string with `?` placeholders (invariant 8): the
 * only variable in any of them is a day count computed from configuration,
 * which becomes an interval bound, never SQL text.
 */

export interface SweepResult {
  name: string;
  affected: number;
}

/**
 * Stamps every `fpd_spaning` row whose window has run out and was never
 * otherwise resolved. 7.13's "auto-resolve"; `resolved_by` carries a sentinel
 * rather than NULL because `ck_fpd_spaning_resolved` requires both columns
 * together once either is set — the same rule a gripande's auto-resolve of
 * an efterlysning satisfies with a real Discord id, and the scheduler has
 * none to give.
 */
const SYSTEM_ACTOR = 'system:scheduler';

async function sweepLapsedLookouts(db: SchedulerDb): Promise<SweepResult> {
  const affected = await db.execute(
    `UPDATE fpd_spaning
        SET resolved_at = NOW(3), resolved_by = ?, resolved_grund = 'tiden_ute', version = version + 1
      WHERE resolved_at IS NULL AND expires_at <= NOW(3)`,
    [SYSTEM_ACTOR],
  );

  return { name: 'spaning.lapsed', affected };
}

async function sweepQueryLog(db: SchedulerDb, days: number): Promise<SweepResult> {
  const affected = await db.execute(
    `DELETE FROM fpd_query_log WHERE created_at < DATE_SUB(NOW(3), INTERVAL ? DAY)`,
    [days],
  );

  return { name: 'retention.query_log', affected };
}

async function sweepAlprReads(db: SchedulerDb, days: number): Promise<SweepResult> {
  const affected = await db.execute(
    `DELETE FROM fpd_alpr_reads WHERE read_at < DATE_SUB(NOW(3), INTERVAL ? DAY)`,
    [days],
  );

  return { name: 'retention.alpr_reads', affected };
}

/**
 * A draft anmälan nobody has touched in a long time. Only `utkast` rows, and
 * only ones with no supervisor return pending (`returned_at` would mean an
 * author is expected to act on it) — a draft the author walked away from is
 * personal data with no investigative value left in it (spec 11.4); one
 * mid-review is not this sweep's to remove.
 */
async function sweepStaleDrafts(db: SchedulerDb, days: number): Promise<SweepResult> {
  const affected = await db.execute(
    `DELETE FROM fpd_anmalan
      WHERE status = 'utkast' AND parent_id IS NULL
        AND created_at < DATE_SUB(NOW(3), INTERVAL ? DAY)`,
    [days],
  );

  return { name: 'retention.stale_drafts', affected };
}

/**
 * Only the observer-session telemetry — who was listening, from when to
 * when. The decision itself (`fpd_hak`) is not touched: that is the record
 * RB 27 accountability rests on, and it is a case file's, not a log's,
 * retention question. This is the practical split invariant 11.4 and 9's
 * "no broadcasts of sessions or device lists" both point at — the minute-by-
 * minute detail ages out; the fact that a measure existed and what it
 * authorised does not.
 */
async function sweepSurveillanceSessions(db: SchedulerDb, days: number): Promise<SweepResult> {
  const affected = await db.execute(
    `DELETE FROM fpd_hak_sessions
      WHERE ended_at IS NOT NULL AND ended_at < DATE_SUB(NOW(3), INTERVAL ? DAY)`,
    [days],
  );

  return { name: 'retention.surveillance_sessions', affected };
}

export async function runSweeps(db: SchedulerDb, config: GatewayConfig): Promise<SweepResult[]> {
  const { retentionDays } = config.scheduler;

  // Sequential, not parallel: these are independent tables, but the
  // scheduler runs on a two-connection pool (`db.ts`) sized for its own
  // light, occasional traffic rather than for concurrency, and a summary
  // that lists sweeps in a fixed order is easier to read than one whose
  // order changes run to run.
  return [
    await sweepLapsedLookouts(db),
    await sweepQueryLog(db, retentionDays.queryLog),
    await sweepAlprReads(db, retentionDays.alprReads),
    await sweepStaleDrafts(db, retentionDays.staleDrafts),
    await sweepSurveillanceSessions(db, retentionDays.surveillanceSessions),
  ];
}
