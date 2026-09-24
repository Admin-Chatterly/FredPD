import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import type { GatewayConfig } from '../config.js';
import { SIGNATURE_HEADER, TIMESTAMP_HEADER, sign } from '../hmac.js';
import { createServer } from '../server.js';
import type { DiscordFetch } from './roles.js';

const MEMBER = '123456789012345678';
const RANK = '223456789012345678';
const ADMIN = '323456789012345678';

function configWith(enabled: boolean): GatewayConfig {
  return {
    env: 'development',
    host: '127.0.0.1',
    port: 0,
    secret: 'test-secret',
    replayWindowSeconds: 30,
    media: {
      directory: join(mkdtempSync(join(tmpdir(), 'fredpd-roles-')), 'store'),
      tokenTtlSeconds: 300,
      maxBytes: 1024,
      publicBaseUrl: 'http://127.0.0.1:3080',
      allowedOrigin: 'https://cfx-nui-fredpd',
    },
    pdf: { chromiumExecutable: '/opt/pw-browsers/chromium' },
    roleActions: {
      enabled,
      botToken: enabled ? 'bot-token' : null,
      guildId: enabled ? '423456789012345678' : null,
      allowedRoleIds: new Set(enabled ? [RANK] : []),
    },
    scheduler: {
      enabled: false,
      intervalSeconds: 300,
      databaseUrl: null,
      retentionDays: { queryLog: 365, alprReads: 30, staleDrafts: 180, surveillanceSessions: 730 },
    },
  };
}

interface Call {
  url: string;
  init: RequestInit;
}

function fakeDiscord(status: number): { fetcher: DiscordFetch; calls: Call[] } {
  const calls: Call[] = [];
  return {
    calls,
    fetcher: async (url, init) => {
      calls.push({ url, init });
      return new Response(null, { status });
    },
  };
}

async function post(config: GatewayConfig, fetcher: DiscordFetch, payload: unknown) {
  const app = createServer(config, { discordFetch: fetcher });
  const body = JSON.stringify(payload);
  const timestamp = Math.floor(Date.now() / 1000);

  const response = await app.inject({
    method: 'POST',
    url: '/fx/discord/role',
    payload: body,
    headers: {
      [SIGNATURE_HEADER]: sign(config.secret, timestamp, body),
      [TIMESTAMP_HEADER]: String(timestamp),
      'content-type': 'application/json',
    },
  });

  await app.close();
  return response;
}

describe('discord role actions', () => {
  it('adds an allowed role, with the reason in Discord’s own audit log', async () => {
    const discord = fakeDiscord(204);
    const response = await post(configWith(true), discord.fetcher, {
      discordId: MEMBER,
      roleId: RANK,
      action: 'add',
      reason: 'Promoted by 1-ADAM-12: passed the sergeant board',
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ ok: true });
    expect(discord.calls).toHaveLength(1);
    expect(discord.calls[0]?.url).toBe(
      `https://discord.com/api/v10/guilds/423456789012345678/members/${MEMBER}/roles/${RANK}`,
    );
    expect(discord.calls[0]?.init.method).toBe('PUT');
    const headers = discord.calls[0]?.init.headers as Record<string, string>;
    expect(headers['Authorization']).toBe('Bot bot-token');
    expect(decodeURIComponent(headers['X-Audit-Log-Reason'] ?? '')).toBe(
      'Promoted by 1-ADAM-12: passed the sergeant board',
    );
  });

  it('removes a role with DELETE', async () => {
    const discord = fakeDiscord(204);
    await post(configWith(true), discord.fetcher, { discordId: MEMBER, roleId: RANK, action: 'remove' });

    expect(discord.calls[0]?.init.method).toBe('DELETE');
  });

  it('never touches a role it was not configured to manage, whatever FXServer asks', async () => {
    const discord = fakeDiscord(204);
    const response = await post(configWith(true), discord.fetcher, { discordId: MEMBER, roleId: ADMIN, action: 'add' });

    expect(response.statusCode).toBe(403);
    expect(response.json()).toEqual({ ok: false, err: 'role_not_allowed' });
    expect(discord.calls).toHaveLength(0);
  });

  it('is off unless switched on', async () => {
    const discord = fakeDiscord(204);
    const response = await post(configWith(false), discord.fetcher, { discordId: MEMBER, roleId: RANK, action: 'add' });

    expect(response.statusCode).toBe(409);
    expect(discord.calls).toHaveLength(0);
  });

  it('refuses anything that is not a Discord id, before calling Discord', async () => {
    const discord = fakeDiscord(204);

    for (const payload of [
      { discordId: '../../guilds', roleId: RANK, action: 'add' },
      { discordId: MEMBER, roleId: `${RANK}/../x`, action: 'add' },
      { discordId: MEMBER, roleId: RANK, action: 'ban' },
    ]) {
      const response = await post(configWith(true), discord.fetcher, payload);
      expect(response.statusCode).toBe(400);
    }

    expect(discord.calls).toHaveLength(0);
  });

  it('reports what Discord said as its own reason, never Discord’s body', async () => {
    expect((await post(configWith(true), fakeDiscord(404).fetcher, { discordId: MEMBER, roleId: RANK, action: 'add' })).json()).toEqual({
      ok: false,
      err: 'member_not_found',
    });
    expect((await post(configWith(true), fakeDiscord(403).fetcher, { discordId: MEMBER, roleId: RANK, action: 'add' })).json()).toEqual({
      ok: false,
      err: 'bot_cannot_manage',
    });
  });

  it('refuses an unsigned request', async () => {
    const discord = fakeDiscord(204);
    const app = createServer(configWith(true), { discordFetch: discord.fetcher });
    const response = await app.inject({
      method: 'POST',
      url: '/fx/discord/role',
      payload: JSON.stringify({ discordId: MEMBER, roleId: RANK, action: 'add' }),
      headers: { 'content-type': 'application/json' },
    });
    await app.close();

    expect(response.statusCode).toBe(401);
    expect(discord.calls).toHaveLength(0);
  });
});
