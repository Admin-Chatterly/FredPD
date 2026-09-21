import { loadConfig } from './config.js';
import { createServer } from './server.js';
import { connect } from './scheduler/db.js';
import { startScheduler, type Scheduler } from './scheduler/scheduler.js';

/**
 * Gateway entry point. Runs under systemd with automatic restart (spec 16), so
 * a configuration fault should exit loudly rather than limp along.
 */

const config = loadConfig();
const app = createServer(config);

let scheduler: Scheduler | null = null;

// Off by default (this package's whole rule, `gateway/CLAUDE.md`): the
// scheduler only starts when both `FREDPD_SCHEDULER_ENABLED` and the
// database credentials it needs are present, which `loadConfig` already
// enforces together.
if (config.scheduler.enabled && config.scheduler.databaseUrl) {
  const db = connect(config.scheduler.databaseUrl);
  scheduler = startScheduler(db, config, app.log);
}

try {
  await app.listen({ host: config.host, port: config.port });
} catch (error) {
  app.log.error(error, 'gateway failed to start');
  process.exit(1);
}

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => {
    scheduler?.stop();
    void app.close().then(() => process.exit(0));
  });
}
