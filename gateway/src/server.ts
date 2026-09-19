import Fastify, { type FastifyInstance } from 'fastify';

import type { GatewayConfig } from './config.js';
import { SIGNATURE_HEADER, TIMESTAMP_HEADER, verify } from './hmac.js';

/**
 * The gateway HTTP surface (spec 3.7).
 *
 * M0 scope: a signed, loopback-only skeleton with a health endpoint. The Discord
 * bot, media service, PDF renderer and scheduler mount onto this in M1 and later.
 */

declare module 'fastify' {
  interface FastifyRequest {
    /** Set by the signature hook for routes under /fx. */
    verifiedBody?: unknown;
  }
}

export function createServer(config: GatewayConfig): FastifyInstance {
  const app = Fastify({
    logger: { level: config.env === 'production' ? 'info' : 'debug' },
    // The body has to be verified byte-for-byte as it arrived, so signature
    // checking happens before anything parses or re-serializes it.
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

  /**
   * Everything FXServer calls lives under /fx and must be signed. Registered as
   * a plugin so the hook cannot accidentally be skipped by a route added later
   * somewhere else in the tree.
   */
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
    },
    { prefix: '/fx' },
  );

  return app;
}
