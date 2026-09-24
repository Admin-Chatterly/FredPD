import Fastify, { type FastifyInstance } from 'fastify';

import type { GatewayConfig } from './config.js';
import { SIGNATURE_HEADER, TIMESTAMP_HEADER, verify } from './hmac.js';
import { createDiskStore } from './media/store.js';
import { noopScanner, type Scanner } from './media/scan.js';
import { registerFxMediaRoutes, registerPublicMediaRoutes, type MediaDeps } from './media/routes.js';
import { registerPdfRoutes } from './pdf/routes.js';
import { registerDiscordRoutes, type DiscordFetch } from './discord/roles.js';

/**
 * The gateway HTTP surface (spec 3.7).
 *
 * M0 gave this a signed, loopback-only skeleton with a health endpoint. Media
 * and PDF rendering mount onto it here, and Discord role actions (ADR-022);
 * the web portal is a later milestone.
 */

declare module 'fastify' {
  interface FastifyRequest {
    /** Set by the signature hook for routes under /fx. */
    verifiedBody?: unknown;
  }
}

export interface ServerDeps {
  scanner?: Scanner;
  /** Discord's REST API; a test passes its own. */
  discordFetch?: DiscordFetch;
}

export function createServer(config: GatewayConfig, deps: ServerDeps = {}): FastifyInstance {
  const app = Fastify({
    logger: {
      level: config.env === 'production' ? 'info' : 'debug',
      // A media URL's query string is its token (ADR-019): logged, it would
      // be a working link to a photograph for whoever reads the log.
      serializers: {
        req: (request) => ({
          method: request.method,
          url: request.url.replace(/\?.*$/, ''),
          remoteAddress: request.ip,
        }),
      },
    },
    // The body has to be verified byte-for-byte as it arrived, so signature
    // checking happens before anything parses or re-serializes it. Media
    // uploads bypass this cap entirely -- see `media/routes.ts`, which
    // registers its own content-type parser scoped to itself and enforces
    // `config.media.maxBytes` while streaming rather than here.
    bodyLimit: 2 * 1024 * 1024,
  });

  app.addContentTypeParser('application/json', { parseAs: 'string' }, (_request, body, done) => {
    done(null, body);
  });

  /**
   * Health, for systemd and monitoring (spec 16). Unsigned on purpose: it
   * reports liveness only and reveals nothing about the agency or its data.
   */
  app.get('/health', async () => ({
    ok: true,
    env: config.env,
    uptimeSeconds: Math.round(process.uptime()),
  }));

  const store = createDiskStore(config.media.directory);
  const mediaDeps: MediaDeps = { store, scanner: deps.scanner ?? noopScanner };

  /**
   * Everything FXServer calls lives under /fx and must be signed. Registered
   * as a plugin so the hook cannot accidentally be skipped by a route added
   * later somewhere else in the tree.
   */
  /**
   * Signatures already accepted, until they fall out of the replay window. A
   * signed request is honoured once: the same bytes arriving again inside the
   * window -- a role just removed, re-added by replaying the request that
   * added it (ADR-022) -- is refused like any other bad signature.
   */
  const seen = new Map<string, number>();

  function firstTime(signature: string, nowSeconds: number): boolean {
    for (const [key, expires] of seen) {
      if (expires < nowSeconds) seen.delete(key);
    }
    if (seen.has(signature)) return false;
    seen.set(signature, nowSeconds + config.replayWindowSeconds * 2);
    return true;
  }

  app.register(
    async (scope) => {
      scope.addHook('preHandler', async (request, reply) => {
        const raw = typeof request.body === 'string' ? request.body : '';

        const result = verify({
          secret: config.secret,
          signature: request.headers[SIGNATURE_HEADER] as string | undefined,
          timestamp: request.headers[TIMESTAMP_HEADER] as string | undefined,
          body: raw,
          replayWindowSeconds: config.replayWindowSeconds,
        });

        const signature = request.headers[SIGNATURE_HEADER] as string | undefined;
        if (result.ok && !firstTime(signature ?? '', Math.floor(Date.now() / 1000))) {
          request.log.warn({ url: request.url }, 'rejected a replayed request');
          return reply.code(401).send({ ok: false, err: 'forbidden' });
        }

        if (!result.ok) {
          // One shape for every failure: a caller learns that it failed, not
          // which check it failed or how close it got.
          request.log.warn({ reason: result.reason, url: request.url }, 'rejected unsigned request');
          return reply.code(401).send({ ok: false, err: 'forbidden' });
        }

        request.verifiedBody = raw === '' ? {} : JSON.parse(raw);
        return undefined;
      });

      scope.post('/ping', async (request) => ({ ok: true, echo: request.verifiedBody }));

      registerFxMediaRoutes(scope, config, mediaDeps);
      registerPdfRoutes(scope, config, store);
      registerDiscordRoutes(scope, config, deps.discordFetch ?? ((input, init) => fetch(input, init)));
    },
    { prefix: '/fx' },
  );

  // Unsigned: reached by the NUI directly, gated by the tokens `/fx` issued
  // (`media/routes.ts`'s own header explains why there is no shared secret
  // to check here).
  app.register(registerPublicMediaRoutes(config, mediaDeps));

  return app;
}
