import type { FastifyInstance, FastifyPluginAsync } from 'fastify';

import type { GatewayConfig } from '../config.js';
import { deriveKey } from '../config.js';
import { newMediaRef, signMediaToken, verifyMediaToken } from './tokens.js';
import { AlreadyStoredError, TooLargeError, type MediaStore } from './store.js';
import { makeThumbnail } from './thumbnail.js';
import { contentTypeOf, reencodeImage } from './image.js';
import type { Scanner } from './scan.js';

/**
 * The media service (spec 3.2, 9, 11, 12.2).
 *
 * Two trust boundaries, two halves of this file:
 *
 *   * **`registerFxMediaRoutes`** mounts inside the existing `/fx` scope in
 *     `server.ts`, so every call here is already HMAC-verified. FXServer asks
 *     for a token; it never uploads or downloads bytes itself.
 *   * **`registerPublicMediaRoutes`** mounts at the top level, unsigned,
 *     because its caller is the NUI running in a player's client -- there is
 *     no shared secret to give it. What stands in for one is the token
 *     `registerFxMediaRoutes` issued: scoped to one ref, one action, one
 *     expiry, signed with a subkey derived from the gateway secret
 *     (`deriveKey`, spec 11's "media only through the gateway, with signed
 *     URLs").
 *
 * A `media_ref` a database row carries is never a URL (invariant 9). What
 * this file hands back is the URL, built fresh from the ref and a token that
 * expires -- so a row copied out of the database is worth nothing on its own.
 */

const UPLOAD_PURPOSE = 'media-upload';
const DOWNLOAD_PURPOSE = 'media-download';

export interface MediaDeps {
  store: MediaStore;
  scanner: Scanner;
}

function uploadUrl(
  config: GatewayConfig,
  mediaRef: string,
  token: string,
  expiresAt: number,
  image: boolean,
): string {
  const url = new URL(`/media/upload/${mediaRef}`, config.media.publicBaseUrl);
  url.searchParams.set('token', token);
  url.searchParams.set('expires', String(expiresAt));
  if (image) url.searchParams.set('kind', 'image');

  return url.toString();
}

function downloadUrl(config: GatewayConfig, mediaRef: string, token: string, expiresAt: number): string {
  const url = new URL(`/media/${mediaRef}`, config.media.publicBaseUrl);
  url.searchParams.set('token', token);
  url.searchParams.set('expires', String(expiresAt));

  return url.toString();
}

/**
 * FXServer-facing: request a token. Registered inside the signed `/fx` scope.
 */
export function registerFxMediaRoutes(
  scope: FastifyInstance,
  config: GatewayConfig,
  deps: MediaDeps,
): void {
  const uploadKey = deriveKey(config.secret, UPLOAD_PURPOSE);
  const downloadKey = deriveKey(config.secret, DOWNLOAD_PURPOSE);

  scope.post('/media/upload-token', async (request) => {
    const body = request.verifiedBody as { kind?: unknown } | undefined;
    const image = body?.kind === 'image';

    const mediaRef = newMediaRef();
    const expiresAt = Math.floor(Date.now() / 1000) + config.media.tokenTtlSeconds;
    const token = signMediaToken(uploadKey, mediaRef, image ? 'upload_image' : 'upload', expiresAt);

    request.log.info({ mediaRef, image }, 'issued media upload token');

    return {
      ok: true,
      mediaRef,
      uploadUrl: uploadUrl(config, mediaRef, token, expiresAt, image),
      expiresAt,
    };
  });

  scope.post('/media/download-token', async (request, reply) => {
    const body = request.verifiedBody as { mediaRef?: unknown } | undefined;
    const mediaRef = typeof body?.mediaRef === 'string' ? body.mediaRef : undefined;

    if (!mediaRef || !(await deps.store.exists(mediaRef))) {
      return reply.code(404).send({ ok: false, err: 'not_found' });
    }

    const expiresAt = Math.floor(Date.now() / 1000) + config.media.tokenTtlSeconds;
    const token = signMediaToken(downloadKey, mediaRef, 'download', expiresAt);

    return {
      ok: true,
      mediaRef,
      downloadUrl: downloadUrl(config, mediaRef, token, expiresAt),
      expiresAt,
    };
  });
}

/** Reads `?token=` and `?expires=` off a request, both required. */
function tokenParams(query: unknown): { token: string | undefined; expiresAt: number; image: boolean } {
  const params = (query ?? {}) as { token?: unknown; expires?: unknown; kind?: unknown };

  return {
    token: typeof params.token === 'string' ? params.token : undefined,
    expiresAt: Number.parseInt(typeof params.expires === 'string' ? params.expires : '', 10),
    image: params.kind === 'image',
  };
}

/**
 * Browser-facing: the actual bytes. Registered unsigned at the top level,
 * gated by the token alone.
 */
export const registerPublicMediaRoutes: (config: GatewayConfig, deps: MediaDeps) => FastifyPluginAsync =
  (config, deps) => async (app) => {
    const uploadKey = deriveKey(config.secret, UPLOAD_PURPOSE);
    const downloadKey = deriveKey(config.secret, DOWNLOAD_PURPOSE);

    // A catch-all content-type parser, scoped to this plugin only (Fastify's
    // parsers are encapsulated per plugin, so `/fx`'s JSON-only parser is
    // untouched). It hands the raw request stream straight to the handler
    // rather than buffering it, which is what lets `store.save` enforce the
    // size cap while the body is still arriving instead of after the whole
    // thing is already in memory.
    app.addContentTypeParser('*', (_request, payload, done) => {
      done(null, payload);
    });

    // CORS for the NUI's upload, and only for its origin (`allowedOrigin`).
    // A preflight is answered here; the PUT and GET themselves carry the
    // header so the browser lets the NUI read the answer.
    app.addHook('onRequest', async (request, reply) => {
      if (request.headers.origin !== config.media.allowedOrigin) return;

      reply.header('access-control-allow-origin', config.media.allowedOrigin);
      reply.header('vary', 'origin');

      if (request.method === 'OPTIONS') {
        reply.header('access-control-allow-methods', 'PUT, GET');
        reply.header('access-control-allow-headers', 'content-type');
        reply.header('access-control-max-age', '600');
        return reply.code(204).send();
      }
    });

    app.options('/media/upload/:mediaRef', async (_request, reply) => reply.code(204).send());

    app.put<{ Params: { mediaRef: string } }>('/media/upload/:mediaRef', async (request, reply) => {
      const { mediaRef } = request.params;
      const { token, expiresAt, image } = tokenParams(request.query);

      const verified = verifyMediaToken(uploadKey, mediaRef, image ? 'upload_image' : 'upload', expiresAt, token);
      if (!verified.ok) {
        request.log.warn({ mediaRef, reason: verified.reason }, 'rejected media upload');
        return reply.code(401).send({ ok: false, err: 'forbidden' });
      }

      try {
        const { bytes } = await deps.store.save(
          mediaRef,
          request.raw,
          config.media.maxBytes,
        );

        const scan = await deps.scanner(deps.store.pathFor(mediaRef));

        if (scan.reason === 'not_configured') {
          request.log.warn(
            { mediaRef },
            'no virus scanner configured; this upload was stored unscanned',
          );
        }

        if (!scan.clean) {
          await deps.store.remove(mediaRef);
          request.log.warn({ mediaRef, reason: scan.reason }, 'upload failed the virus scan');
          return reply.code(422).send({ ok: false, err: 'invalid', fields: { file: 'unsafe' } });
        }

        // A photograph is decoded and written out again (`image.ts`): what
        // is kept is sharp's own JPEG, never the bytes as sent.
        if (image) {
          const chunks: Buffer[] = [];
          for await (const chunk of deps.store.read(mediaRef) as AsyncIterable<Buffer>) chunks.push(chunk);

          const encoded = await reencodeImage(Buffer.concat(chunks));
          if (!encoded) {
            await deps.store.remove(mediaRef);
            request.log.warn({ mediaRef }, 'upload refused: not an image');
            return reply.code(422).send({ ok: false, err: 'invalid', fields: { file: 'not_image' } });
          }

          await deps.store.replace(mediaRef, encoded);
          return { ok: true, mediaRef, bytes: encoded.length };
        }

        return { ok: true, mediaRef, bytes };
      } catch (error) {
        if (error instanceof AlreadyStoredError) {
          request.log.warn({ mediaRef }, 'upload refused: the ref already holds a file');
          return reply.code(409).send({ ok: false, err: 'conflict' });
        }

        if (error instanceof TooLargeError) {
          await deps.store.remove(mediaRef);
          return reply.code(413).send({ ok: false, err: 'invalid', fields: { file: 'too_large' } });
        }

        throw error;
      }
    });

    app.get<{ Params: { mediaRef: string } }>('/media/:mediaRef', async (request, reply) => {
      const { mediaRef } = request.params;
      const { token, expiresAt } = tokenParams(request.query);

      const verified = verifyMediaToken(downloadKey, mediaRef, 'download', expiresAt, token);
      if (!verified.ok) {
        return reply.code(401).send({ ok: false, err: 'forbidden' });
      }

      if (!(await deps.store.exists(mediaRef))) {
        return reply.code(404).send({ ok: false, err: 'not_found' });
      }

      // Long cache headers (spec 12.2): a ref is immutable once stored, so a
      // successful fetch may be cached for as long as the browser likes. The
      // token in the URL is what limits how long the *link* itself works, not
      // this header.
      reply.header('cache-control', 'private, max-age=31536000, immutable');
      // Named from the file's own first bytes, and never sniffed further by
      // the browser: a stored file is what this gateway says it is or an
      // opaque download, nothing in between.
      reply.header('x-content-type-options', 'nosniff');
      return reply.type(contentTypeOf(await deps.store.head(mediaRef, 8))).send(deps.store.read(mediaRef));
    });

    app.get<{ Params: { mediaRef: string } }>('/media/:mediaRef/thumbnail', async (request, reply) => {
      const { mediaRef } = request.params;
      const { token, expiresAt } = tokenParams(request.query);

      const verified = verifyMediaToken(downloadKey, mediaRef, 'download', expiresAt, token);
      if (!verified.ok) {
        return reply.code(401).send({ ok: false, err: 'forbidden' });
      }

      if (!(await deps.store.exists(mediaRef))) {
        return reply.code(404).send({ ok: false, err: 'not_found' });
      }

      const chunks: Buffer[] = [];
      for await (const chunk of deps.store.read(mediaRef) as AsyncIterable<Buffer>) {
        chunks.push(chunk);
      }

      const thumbnail = await makeThumbnail(Buffer.concat(chunks));
      if (!thumbnail) {
        return reply.code(404).send({ ok: false, err: 'not_found' });
      }

      reply.header('cache-control', 'private, max-age=31536000, immutable');
      return reply.type('image/webp').send(thumbnail);
    });
  };
