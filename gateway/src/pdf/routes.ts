import { Readable } from 'node:stream';

import type { FastifyInstance } from 'fastify';

import type { GatewayConfig } from '../config.js';
import { deriveKey } from '../config.js';
import { newMediaRef, signMediaToken } from '../media/tokens.js';
import type { MediaStore } from '../media/store.js';
import { renderDocumentToPdf } from './render.js';
import type { DocumentInput } from './document.js';

/**
 * `/fx/pdf/render` -- inside the signed `/fx` scope, the same as the media
 * token routes.
 *
 * The rendered bytes are written straight into the media store rather than
 * returned inline: a PDF an officer downloads is media like any other, and a
 * second delivery mechanism here would be a second set of rules about size
 * caps and cache headers to keep in step with `media/routes.ts`'s. The
 * response is a `mediaRef` and a signed download URL, the same shape
 * `/fx/media/upload-token` hands back once a file already exists.
 */
export function registerPdfRoutes(scope: FastifyInstance, config: GatewayConfig, store: MediaStore): void {
  const downloadKey = deriveKey(config.secret, 'media-download');

  scope.post('/pdf/render', async (request, reply) => {
    const body = request.verifiedBody as Partial<DocumentInput> | undefined;

    if (!body || typeof body.title !== 'string' || !body.body || body.body.type !== 'doc') {
      return reply.code(400).send({ ok: false, err: 'invalid', fields: { body: 'required' } });
    }

    const input: DocumentInput = {
      title: body.title,
      fields: Array.isArray(body.fields) ? body.fields : [],
      body: body.body,
      classification: typeof body.classification === 'string' ? body.classification : undefined,
      letterhead: typeof body.letterhead === 'string' ? body.letterhead : undefined,
      documentNumber: typeof body.documentNumber === 'string' ? body.documentNumber : undefined,
      pageLabel: typeof body.pageLabel === 'string' ? body.pageLabel : undefined,
      printedLabel: typeof body.printedLabel === 'string' ? body.printedLabel : undefined,
    };

    const pdf = await renderDocumentToPdf(config, input);

    const mediaRef = newMediaRef();
    await store.save(mediaRef, Readable.from(pdf), pdf.length + 1);

    const expiresAt = Math.floor(Date.now() / 1000) + config.media.tokenTtlSeconds;
    const token = signMediaToken(downloadKey, mediaRef, 'download', expiresAt);
    const url = new URL(`/media/${mediaRef}`, config.media.publicBaseUrl);
    url.searchParams.set('token', token);
    url.searchParams.set('expires', String(expiresAt));

    request.log.info({ mediaRef, bytes: pdf.length }, 'rendered a document to PDF');

    return {
      ok: true,
      mediaRef,
      downloadUrl: url.toString(),
      expiresAt,
      bytes: pdf.length,
    };
  });
}
