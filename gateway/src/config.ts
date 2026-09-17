/**
 * Gateway configuration, read from the environment (spec 3.9).
 *
 * Invariant 7: secrets come from the environment, never from a file in the
 * repository. A missing secret stops the process at boot rather than leaving an
 * unauthenticated service listening.
 */

function required(name: string): string {
  const value = process.env[name];

  if (value === undefined || value === '') {
    throw new Error(
      `${name} is not set. The gateway will not start without it: an unsigned gateway would let anything on the host issue role changes and media tokens.`,
    );
  }

  return value;
}

function optional(name: string, fallback: string): string {
  const value = process.env[name];
  return value === undefined || value === '' ? fallback : value;
}

function port(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;

  const parsed = Number.parseInt(raw, 10);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 65535) {
    throw new Error(`${name} must be a port number between 1 and 65535, got "${raw}".`);
  }

  return parsed;
}

export interface GatewayConfig {
  env: 'development' | 'staging' | 'production';
  host: string;
  port: number;
  /** Shared secret for signing both directions of the FXServer link (spec 3.7). */
  secret: string;
  /** How old a signed request may be before it is treated as a replay, in seconds. */
  replayWindowSeconds: number;
}

export function loadConfig(): GatewayConfig {
  const env = optional('FREDPD_ENV', 'development');

  if (env !== 'development' && env !== 'staging' && env !== 'production') {
    throw new Error(`FREDPD_ENV must be development, staging or production, got "${env}".`);
  }

  return {
    env,
    // Loopback only: the gateway is reached by FXServer on the same host, and
    // by the outside world only through Caddy (spec 3.2).
    host: optional('FREDPD_GATEWAY_HOST', '127.0.0.1'),
    port: port('FREDPD_GATEWAY_PORT', 3080),
    secret: required('FREDPD_GATEWAY_SECRET'),
    replayWindowSeconds: 30,
  };
}
