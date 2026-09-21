import { describe, expect, it, vi } from 'vitest';

import type { GatewayConfig } from '../config.js';
import type { SchedulerDb, SqlValue } from './db.js';
import { startScheduler } from './scheduler.js';

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

function fakeLog() {
  return { info: vi.fn(), error: vi.fn() };
}

describe('startScheduler', () => {
  it('runs once immediately and writes one audit summary row', async () => {
    const calls: Array<{ sql: string; values: SqlValue[] }> = [];
    const db: SchedulerDb = {
      async execute(sql, values = []) {
        calls.push({ sql, values });
        return 0;
      },
      async end() {},
    };

    const log = fakeLog();
    const scheduler = startScheduler(db, config, log);

    // The immediate run is fired and forgotten inside `startScheduler`; give
    // its promise chain a turn to land before asserting.
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 0));

    scheduler.stop();

    const audit = calls.find((call) => call.sql.includes('fpd_audit_log'));
    expect(audit).toBeDefined();
    expect(audit?.sql).not.toMatch(/UPDATE|DELETE/);
    expect(audit?.values[0]).toBe('scheduler.swept');

    const detail = JSON.parse(audit?.values[1] as string) as Record<string, number>;
    expect(Object.keys(detail)).toContain('spaning.lapsed');

    expect(log.info).toHaveBeenCalled();
    expect(log.error).not.toHaveBeenCalled();
  });

  it('logs a failed sweep rather than throwing, and does not write a summary for it', async () => {
    const db: SchedulerDb = {
      async execute(sql) {
        if (sql.includes('fpd_spaning')) throw new Error('connection reset');
        return 0;
      },
      async end() {},
    };

    const log = fakeLog();
    const scheduler = startScheduler(db, config, log);

    await new Promise((resolvePromise) => setTimeout(resolvePromise, 0));

    scheduler.stop();

    expect(log.error).toHaveBeenCalled();
  });
});
