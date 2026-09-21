import type { GatewayConfig } from '../config.js';
import type { SchedulerDb } from './db.js';
import { runSweeps } from './sweeps.js';

/**
 * The scheduler loop (spec 13.3).
 *
 * "Writes a summary to the audit log and never touches the audit log
 * itself": one `INSERT` per run, naming what each sweep affected, and
 * nothing here ever reads, updates or deletes a row of `fpd_audit_log` —
 * the same append-only rule invariant 11 puts on every writer of it,
 * including this one.
 */

async function writeSummary(
  db: SchedulerDb,
  results: Array<{ name: string; affected: number }>,
): Promise<void> {
  const detail = JSON.stringify(
    Object.fromEntries(results.map((result) => [result.name, result.affected])),
  );

  await db.execute(
    `INSERT INTO fpd_audit_log (action, discord_id, agency_id, subject_type, outcome, detail)
     VALUES (?, NULL, NULL, NULL, 'ok', ?)`,
    ['scheduler.swept', detail],
  );
}

export interface Scheduler {
  stop(): void;
}

/**
 * Starts the interval loop. A run that throws is logged and does not stop
 * the next one from firing — a sweep that failed once (a lock wait, a
 * transient connection drop) is not a reason to stop sweeping until the
 * process is restarted.
 */
export function startScheduler(
  db: SchedulerDb,
  config: GatewayConfig,
  log: { info: (obj: unknown, msg?: string) => void; error: (obj: unknown, msg?: string) => void },
): Scheduler {
  let running = false;

  async function tick(): Promise<void> {
    if (running) return;
    running = true;

    try {
      const results = await runSweeps(db, config);
      await writeSummary(db, results);
      log.info({ results }, 'scheduler swept');
    } catch (error) {
      log.error({ error }, 'scheduler sweep failed');
    } finally {
      running = false;
    }
  }

  const timer = setInterval(() => void tick(), config.scheduler.intervalSeconds * 1000);
  // Runs once immediately, rather than waiting a full interval after boot —
  // a lookout that lapsed while the gateway was down would otherwise sit
  // stale for up to `intervalSeconds` longer than it needed to.
  void tick();

  return {
    stop() {
      clearInterval(timer);
    },
  };
}
