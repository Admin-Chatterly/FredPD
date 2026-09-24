import { createHmac } from 'node:crypto';

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

function optionalBoolean(name: string, fallback: boolean): boolean {
  const value = process.env[name];
  if (value === undefined || value === '') return fallback;

  return value === '1' || value.toLowerCase() === 'true';
}

function optionalInt(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;

  const parsed = Number.parseInt(raw, 10);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new Error(`${name} must be a positive whole number, got "${raw}".`);
  }

  return parsed;
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

const SNOWFLAKE = /^\d{17,20}$/;

function snowflake(name: string): string {
  const value = required(name);
  if (!SNOWFLAKE.test(value)) throw new Error(`${name} must be a Discord id (digits only), got "${value}".`);
  return value;
}

/**
 * A comma-separated list of Discord role ids, none of them empty. Required
 * and non-empty: role actions with nothing allowed is a configuration
 * mistake, and a gateway that started anyway would refuse every request with
 * no hint why.
 */
function snowflakeList(name: string): ReadonlySet<string> {
  const ids = required(name)
    .split(',')
    .map((id) => id.trim())
    .filter((id) => id !== '');

  for (const id of ids) {
    if (!SNOWFLAKE.test(id)) throw new Error(`${name} must list Discord role ids, got "${id}".`);
  }
  if (ids.length === 0) throw new Error(`${name} lists no roles.`);

  return new Set(ids);
}

export interface GatewayConfig {
  env: 'development' | 'staging' | 'production';
  host: string;
  port: number;
  /** Shared secret for signing both directions of the FXServer link (spec 3.7). */
  secret: string;
  /** How old a signed request may be before it is treated as a replay, in seconds. */
  replayWindowSeconds: number;

  media: {
    /**
     * Where files are stored. A local directory by default (spec 3.2: "disk
     * or S3-compatible"); an S3-compatible backend is a `store.ts`
     * implementation this config does not yet select between, because
     * nothing in the suite needs one before a deployment does.
     */
    directory: string;
    /** How long an upload or download URL stays valid, in seconds. */
    tokenTtlSeconds: number;
    /** Payload size cap (spec 12.2): the largest a single upload may be. */
    maxBytes: number;
    /**
     * The origin the NUI reaches this service at. Baked into `web/index.html`
     * at build time (`%FREDPD_MEDIA_BASE_URL%`, Vite's HTML env replacement)
     * so the CSP's `img-src`/`media-src`/`connect-src` can name it without a
     * wildcard (invariant 9).
     */
    publicBaseUrl: string;
    /**
     * The one browser origin allowed to upload from script: the NUI, which
     * FiveM serves as `https://cfx-nui-<resource>`. An upload is a `PUT` with
     * an image content type, so the browser asks first (a CORS preflight),
     * and without an answer naming this origin every upload fails before it
     * is sent. Nothing else is let in; the token is still what authorises.
     */
    allowedOrigin: string;
  };

  pdf: {
    /** Same override `web/playwright.config.ts` reads, for the same reason:
     * a pinned Chromium revision may not match what a sandboxed image
     * shipped, and a build that cannot render a PDF is indistinguishable
     * from a broken one. */
    chromiumExecutable: string;
  };

  /**
   * Discord role actions (ADR-022): hire, promote, demote, dismiss. Off by
   * default. A bot of its own -- not the read bot FXServer uses (ADR-010) --
   * whose token only this service holds, and an allowlist of the only roles
   * it will ever touch, set here rather than trusted from any request.
   */
  roleActions: {
    enabled: boolean;
    botToken: string | null;
    guildId: string | null;
    allowedRoleIds: ReadonlySet<string>;
  };

  scheduler: {
    /**
     * Off by default (this package's whole rule), and **superseded for
     * retention** by the sweep FXServer runs itself (ADR-021). Leave it off:
     * its deletes are idempotent, so running both breaks nothing, but the
     * work is done twice and the windows here are not the ones
     * `config/server.lua` sets.
     */
    enabled: boolean;
    intervalSeconds: number;
    /** `mysql://user:pass@host:port/db` -- the same `DATABASE_URL` `.env.example` already documents. */
    databaseUrl: string | null;
    /**
     * Retention windows in days, per data type (spec 11.4, 13.3). Provisional
     * defaults, conservative on purpose: no `admin.retention.edit` screen
     * exists yet to set these per deployment, so a server that never
     * configures them keeps data for a year or more rather than losing it to
     * a default nobody chose. Closed scenes are deliberately absent — see
     * `scheduler/sweeps.ts`'s header for why deleting one is not safe here.
     */
    retentionDays: {
      queryLog: number;
      alprReads: number;
      staleDrafts: number;
      surveillanceSessions: number;
    };
  };
}

export function loadConfig(): GatewayConfig {
  const env = optional('FREDPD_ENV', 'development');

  if (env !== 'development' && env !== 'staging' && env !== 'production') {
    throw new Error(`FREDPD_ENV must be development, staging or production, got "${env}".`);
  }

  const gatewayPort = port('FREDPD_GATEWAY_PORT', 3080);
  const schedulerEnabled = optionalBoolean('FREDPD_SCHEDULER_ENABLED', false);
  const roleActionsEnabled = optionalBoolean('FREDPD_ROLE_ACTIONS_ENABLED', false);

  return {
    env,
    // Loopback only: the gateway is reached by FXServer on the same host, and
    // by the outside world only through Caddy (spec 3.2).
    host: optional('FREDPD_GATEWAY_HOST', '127.0.0.1'),
    port: gatewayPort,
    secret: required('FREDPD_GATEWAY_SECRET'),
    replayWindowSeconds: 30,

    media: {
      directory: optional('FREDPD_MEDIA_DIR', './data/media'),
      tokenTtlSeconds: optionalInt('FREDPD_MEDIA_TOKEN_TTL', 300),
      maxBytes: optionalInt('FREDPD_MEDIA_MAX_BYTES', 15 * 1024 * 1024),
      publicBaseUrl: optional('FREDPD_MEDIA_BASE_URL', `http://127.0.0.1:${gatewayPort}`),
      allowedOrigin: optional('FREDPD_MEDIA_ALLOWED_ORIGIN', 'https://cfx-nui-fredpd'),
    },

    pdf: {
      chromiumExecutable: optional('PLAYWRIGHT_CHROMIUM_EXECUTABLE', '/opt/pw-browsers/chromium'),
    },

    roleActions: {
      enabled: roleActionsEnabled,
      // Required only when role actions are on: nothing an install is
      // required to run needs a write-capable bot (this package's rule).
      botToken: roleActionsEnabled ? required('DISCORD_ROLE_BOT_TOKEN') : null,
      guildId: roleActionsEnabled ? snowflake('DISCORD_GUILD_ID') : null,
      allowedRoleIds: roleActionsEnabled ? snowflakeList('FREDPD_ROLE_ACTIONS_ALLOWED') : new Set<string>(),
    },

    scheduler: {
      enabled: schedulerEnabled,
      intervalSeconds: optionalInt('FREDPD_SCHEDULER_INTERVAL', 300),
      // Required only when the scheduler is switched on: a normal install
      // runs no scheduler and therefore needs no database credential here at
      // all (this package's whole rule — nothing an install is required to
      // run).
      databaseUrl: schedulerEnabled ? required('DATABASE_URL') : null,
      retentionDays: {
        queryLog: optionalInt('FREDPD_RETENTION_QUERY_LOG_DAYS', 365),
        alprReads: optionalInt('FREDPD_RETENTION_ALPR_READS_DAYS', 30),
        staleDrafts: optionalInt('FREDPD_RETENTION_STALE_DRAFTS_DAYS', 180),
        surveillanceSessions: optionalInt('FREDPD_RETENTION_SURVEILLANCE_SESSIONS_DAYS', 730),
      },
    },
  };
}

/**
 * A purpose-scoped subkey, so a leaked media token cannot be replayed as an
 * FXServer link signature and a compromise of one channel does not hand over
 * the other. `HMAC(secret, purpose)` rather than string concatenation,
 * because concatenation admits `sign(secret, 'a' + 'b')` and
 * `sign(secret, 'ab')` colliding for adjacent purposes; HMAC does not.
 */
export function deriveKey(secret: string, purpose: string): string {
  return createHmac('sha256', secret).update(purpose).digest('hex');
}
