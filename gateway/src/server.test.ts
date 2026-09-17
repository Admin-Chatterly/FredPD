import { describe, expect, it } from 'vitest';

import type { GatewayConfig } from './config.js';
import { SIGNATURE_HEADER, TIMESTAMP_HEADER, sign } from './hmac.js';
import { createServer } from './server.js';

const config: GatewayConfig = {
  env: 'development',
  host: '127.0.0.1',
  port: 0,
  secret: 'test-secret',
  replayWindowSeconds: 30,
};

function signedHeaders(body: string, secret = config.secret) {
  const timestamp = Math.floor(Date.now() / 1000);

  return {
    [SIGNATURE_HEADER]: sign(secret, timestamp, body),
    [TIMESTAMP_HEADER]: String(timestamp),
    'content-type': 'application/json',
  };
}

describe('gateway server', () => {
  it('serves health without a signature', async () => {
    const app = createServer(config);
    const response = await app.inject({ method: 'GET', url: '/health' });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({ ok: true, env: 'development' });

    await app.close();
  });

  it('accepts a signed call from FXServer', async () => {
    const app = createServer(config);
    const body = JSON.stringify({ hello: 'world' });

    const response = await app.inject({
      method: 'POST',
      url: '/fx/ping',
      headers: signedHeaders(body),
      payload: body,
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ ok: true, echo: { hello: 'world' } });

    await app.close();
  });

  it('rejects an unsigned call', async () => {
    const app = createServer(config);

    const response = await app.inject({
      method: 'POST',
      url: '/fx/ping',
      headers: { 'content-type': 'application/json' },
      payload: JSON.stringify({ hello: 'world' }),
    });

    expect(response.statusCode).toBe(401);

    await app.close();
  });

  it('rejects a call signed with the wrong secret', async () => {
    const app = createServer(config);
    const body = JSON.stringify({ hello: 'world' });

    const response = await app.inject({
      method: 'POST',
      url: '/fx/ping',
      headers: signedHeaders(body, 'wrong-secret'),
      payload: body,
    });

    expect(response.statusCode).toBe(401);

    await app.close();
  });

  it('rejects a body altered after signing', async () => {
    const app = createServer(config);
    const signedBody = JSON.stringify({ amount: 1 });

    const response = await app.inject({
      method: 'POST',
      url: '/fx/ping',
      headers: signedHeaders(signedBody),
      payload: JSON.stringify({ amount: 1000 }),
    });

    expect(response.statusCode).toBe(401);

    await app.close();
  });
});
