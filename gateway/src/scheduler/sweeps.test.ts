import { describe, expect, it } from 'vitest';

import type { GatewayConfig } from '../config.js';
import type { SchedulerDb, SqlValue } from './db.js';
import { runSweeps } from './sweeps.js';

/**
 * The sweeps against a fake database that records what was asked of it
 * rather than a live MariaDB, so this suite runs everywhere `pnpm verify`
 * does (spec 15). What matters here is not the SQL text -- that only a real
 * database can validate -- but that every table spec 13.3 names is swept
 * exactly once, in a fixed order, with a parameterized day count and never a
 * value built into the statement string.
 */

interface Call {
  sql: string;
  values: SqlValue[];
}

function fakeDb(affectedByTable: Record<string, number> = {}): { db: SchedulerDb; calls: Call[] } {
  const calls: Call[] = [];

  const db: SchedulerDb = {
    async execute(sql, values = []) {
      calls.push({ sql, values });

      for (const [table, affected] of Object.entries(affectedByTable)) {
        if (sql.includes(table)) return affected;
      }

      return 0;
    },
    async end() {},
  };

  return { db, calls };
}

const config: GatewayConfig = {
  env: 'development',
  host: '127.0.0.1',
  port: 0,
  secret: 'x',
  replayWindowSeconds: 30,
  media: { directory: '/tmp/x', tokenTtlSeconds: 300, maxBytes: 1024, publicBaseUrl: 'http://x' },
  pdf: { chromiumExecutable: '/opt/pw-browsers/chromium' },
  scheduler: {
    enabled: true,
    intervalSeconds: 300,
    databaseUrl: 'mysql://x:x@x:3306/x',
    retentionDays: { queryLog: 365, alprReads: 90, staleDrafts: 180, surveillanceSessions: 730 },
  },
};

describe('runSweeps', () => {
  it('runs every sweep spec 13.3 names, in a fixed order', async () => {
    const { db, calls } = fakeDb();

    const results = await runSweeps(db, config);

    expect(results.map((result) => result.name)).toEqual([
      'spaning.lapsed',
      'retention.query_log',
      'retention.alpr_reads',
      'retention.stale_drafts',
      'retention.surveillance_sessions',
    ]);
    expect(calls).toHaveLength(5);
  });

  it('never deletes fpd_scenes -- evidence cascades from it and retention cannot take that with it', async () => {
    const { db, calls } = fakeDb();

    await runSweeps(db, config);

    for (const call of calls) {
      expect(call.sql).not.toContain('fpd_scenes');
      expect(call.sql).not.toContain('fpd_evidence');
    }
  });

  it('never touches fpd_hak, only fpd_hak_sessions', async () => {
    const { db, calls } = fakeDb();

    await runSweeps(db, config);

    const surveillance = calls.find((call) => call.sql.includes('fpd_hak'));

    expect(surveillance?.sql).toContain('fpd_hak_sessions');
    expect(surveillance?.sql).not.toMatch(/DELETE FROM `?fpd_hak`?\s/);
  });

  it('passes each configured retention window as a parameter, never interpolated', async () => {
    const { db, calls } = fakeDb();

    await runSweeps(db, config);

    const queryLog = calls.find((call) => call.sql.includes('fpd_query_log'));
    expect(queryLog?.sql).not.toContain('365');
    expect(queryLog?.values).toEqual([365]);

    const alpr = calls.find((call) => call.sql.includes('fpd_alpr_reads'));
    expect(alpr?.values).toEqual([90]);
  });

  it('stamps a lapsed lookout with a system actor the schema accepts', async () => {
    const { db, calls } = fakeDb();

    await runSweeps(db, config);

    const spaning = calls.find((call) => call.sql.includes('fpd_spaning'));
    // `ck_fpd_spaning_resolved` (0012) requires `resolved_by` whenever
    // `resolved_at` is set. A NULL here would fail the write outright.
    expect(spaning?.values[0]).toBe('system:scheduler');
    expect(spaning?.sql).toContain("resolved_grund = 'tiden_ute'");
  });

  it('only sweeps top-level drafts, never a tilläggsuppgift', async () => {
    const { db, calls } = fakeDb();

    await runSweeps(db, config);

    const drafts = calls.find((call) => call.sql.includes('fpd_anmalan'));
    expect(drafts?.sql).toContain('parent_id IS NULL');
    expect(drafts?.sql).toContain("status = 'utkast'");
  });

  it('reports what each sweep actually affected', async () => {
    const { db } = fakeDb({ fpd_spaning: 3, fpd_query_log: 120 });

    const results = await runSweeps(db, config);

    expect(results.find((result) => result.name === 'spaning.lapsed')?.affected).toBe(3);
    expect(results.find((result) => result.name === 'retention.query_log')?.affected).toBe(120);
  });
});
