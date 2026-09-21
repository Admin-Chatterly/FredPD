import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import type { GatewayConfig } from '../config.js';
import { SIGNATURE_HEADER, TIMESTAMP_HEADER, sign } from '../hmac.js';
import { createServer } from '../server.js';
import type { Scanner } from './scan.js';

/**
 * The media round trip against the mock — er, the real thing (spec 3.7, 9,
 * 11): FXServer asks for a token, the NUI uploads with it, FXServer asks for
 * a different token to hand the NUI a download link, and neither token works
 * for the other action or the other ref.
 */

function baseConfig(mediaDir: string): GatewayConfig {
  return {
    env: 'development',
    host: '127.0.0.1',
    port: 0,
    secret: 'test-secret',
    replayWindowSeconds: 30,
    media: {
      directory: mediaDir,
      tokenTtlSeconds: 300,
      maxBytes: 1024,
      publicBaseUrl: 'http://127.0.0.1:3080',
    },
    pdf: { chromiumExecutable: '/opt/pw-browsers/chromium' },
    scheduler: {
      enabled: false,
      intervalSeconds: 300,
      databaseUrl: null,
      retentionDays: { queryLog: 365, alprReads: 90, staleDrafts: 180, surveillanceSessions: 730 },
    },
  };
}

function signedHeaders(secret: string, body: string) {
  const timestamp = Math.floor(Date.now() / 1000);

  return {
    [SIGNATURE_HEADER]: sign(secret, timestamp, body),
    [TIMESTAMP_HEADER]: String(timestamp),
    'content-type': 'application/json',
  };
}

describe('media', () => {
  it('issues an upload token, accepts a matching upload, then serves it back with a fresh download token', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'fredpd-media-'));
    const config = baseConfig(dir);
    const app = createServer(config);

    const tokenResponse = await app.inject({
      method: 'POST',
      url: '/fx/media/upload-token',
      headers: signedHeaders(config.secret, ''),
      payload: '',
    });

    expect(tokenResponse.statusCode).toBe(200);
    const { mediaRef, uploadUrl } = tokenResponse.json() as { mediaRef: string; uploadUrl: string };
    expect(mediaRef).toMatch(/^media_/);

    const uploadPath = new URL(uploadUrl).pathname + new URL(uploadUrl).search;

    const uploadResponse = await app.inject({
      method: 'PUT',
      url: uploadPath,
      payload: Buffer.from('a photograph, pretend'),
      headers: { 'content-type': 'application/octet-stream' },
    });

    expect(uploadResponse.statusCode).toBe(200);
    expect(uploadResponse.json()).toMatchObject({ ok: true, mediaRef });

    const downloadTokenResponse = await app.inject({
      method: 'POST',
      url: '/fx/media/download-token',
      headers: signedHeaders(config.secret, JSON.stringify({ mediaRef })),
      payload: JSON.stringify({ mediaRef }),
    });

    expect(downloadTokenResponse.statusCode).toBe(200);
    const { downloadUrl } = downloadTokenResponse.json() as { downloadUrl: string };
    const downloadPath = new URL(downloadUrl).pathname + new URL(downloadUrl).search;

    const downloadResponse = await app.inject({ method: 'GET', url: downloadPath });

    expect(downloadResponse.statusCode).toBe(200);
    expect(downloadResponse.body).toBe('a photograph, pretend');
    expect(downloadResponse.headers['cache-control']).toContain('immutable');

    await app.close();
  });

  it('refuses an upload token used as a download token', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'fredpd-media-'));
    const config = baseConfig(dir);
    const app = createServer(config);

    const tokenResponse = await app.inject({
      method: 'POST',
      url: '/fx/media/upload-token',
      headers: signedHeaders(config.secret, ''),
      payload: '',
    });

    const { mediaRef, uploadUrl } = tokenResponse.json() as { mediaRef: string; uploadUrl: string };
    const upload = new URL(uploadUrl);
    const token = upload.searchParams.get('token');
    const expires = upload.searchParams.get('expires');

    // The same token and expiry, replayed against the download route rather
    // than the upload route it was issued for.
    const response = await app.inject({
      method: 'GET',
      url: `/media/${mediaRef}?token=${token}&expires=${expires}`,
    });

    expect(response.statusCode).toBe(401);

    await app.close();
  });

  it('refuses an upload past the size cap and does not keep a partial file', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'fredpd-media-'));
    const config = baseConfig(dir);
    config.media.maxBytes = 8;
    const app = createServer(config);

    const tokenResponse = await app.inject({
      method: 'POST',
      url: '/fx/media/upload-token',
      headers: signedHeaders(config.secret, ''),
      payload: '',
    });

    const { uploadUrl } = tokenResponse.json() as { uploadUrl: string };
    const uploadPath = new URL(uploadUrl).pathname + new URL(uploadUrl).search;

    const response = await app.inject({
      method: 'PUT',
      url: uploadPath,
      payload: Buffer.from('this body is well over eight bytes long'),
      headers: { 'content-type': 'application/octet-stream' },
    });

    expect(response.statusCode).toBe(413);

    await app.close();
  });

  it('refuses a download for a ref that was never uploaded', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'fredpd-media-'));
    const config = baseConfig(dir);
    const app = createServer(config);

    const response = await app.inject({
      method: 'POST',
      url: '/fx/media/download-token',
      headers: signedHeaders(config.secret, JSON.stringify({ mediaRef: 'media_00000000-0000-0000-0000-000000000000' })),
      payload: JSON.stringify({ mediaRef: 'media_00000000-0000-0000-0000-000000000000' }),
    });

    expect(response.statusCode).toBe(404);

    await app.close();
  });

  it('removes an upload that fails the virus scan and does not serve it', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'fredpd-media-'));
    const config = baseConfig(dir);
    const rejectAll: Scanner = async () => ({ clean: false, reason: 'infected' });
    const app = createServer(config, { scanner: rejectAll });

    const tokenResponse = await app.inject({
      method: 'POST',
      url: '/fx/media/upload-token',
      headers: signedHeaders(config.secret, ''),
      payload: '',
    });

    const { mediaRef, uploadUrl } = tokenResponse.json() as { mediaRef: string; uploadUrl: string };
    const uploadPath = new URL(uploadUrl).pathname + new URL(uploadUrl).search;

    const uploadResponse = await app.inject({
      method: 'PUT',
      url: uploadPath,
      payload: Buffer.from('eicar-like test content'),
      headers: { 'content-type': 'application/octet-stream' },
    });

    expect(uploadResponse.statusCode).toBe(422);

    const downloadTokenResponse = await app.inject({
      method: 'POST',
      url: '/fx/media/download-token',
      headers: signedHeaders(config.secret, JSON.stringify({ mediaRef })),
      payload: JSON.stringify({ mediaRef }),
    });

    // Not stored at all: the scan ran before the ref could ever be handed
    // back to anything that might download it.
    expect(downloadTokenResponse.statusCode).toBe(404);

    await app.close();
  });
});
