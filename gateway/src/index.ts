import { loadConfig } from './config.js';
import { createServer } from './server.js';

/**
 * Gateway entry point. Runs under systemd with automatic restart (spec 16), so
 * a configuration fault should exit loudly rather than limp along.
 */

const config = loadConfig();
const app = createServer(config);

try {
  await app.listen({ host: config.host, port: config.port });
} catch (error) {
  app.log.error(error, 'gateway failed to start');
  process.exit(1);
}

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => {
    void app.close().then(() => process.exit(0));
  });
}
