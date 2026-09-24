import type { FastifyInstance } from 'fastify';

import type { GatewayConfig } from '../config.js';

/**
 * `/fx/discord/role`: add or remove one Discord role on one member (ADR-022).
 *
 * The only place in the suite that writes to Discord. FXServer decides
 * whether the officer asking may make the change (its own permission, the
 * escalation guards, the audit) and asks here; this service decides only
 * whether the role is one it was configured to manage at all.
 *
 * That second check is deliberate defence in depth. The allowlist lives in
 * this service's own environment, not in anything FXServer sends, so a
 * compromised FXServer -- or a leaked signing secret -- can at worst toggle
 * the handful of rank roles the operator listed, never an administrator
 * role, and never a role the bot was not told about. The bot's own role in
 * Discord must sit above the roles it manages and should hold only Manage
 * Roles (installation guide, 11e).
 *
 * Discord stays the source of truth: nothing here writes `fpd_discord_members`.
 * The change reaches FredPD through FXServer's own read sync (ADR-010).
 */

const API = 'https://discord.com/api/v10';
const SNOWFLAKE = /^\d{17,20}$/;
const REASON_MAX = 400;

export type DiscordFetch = (input: string, init: RequestInit) => Promise<Response>;

interface RoleBody {
  discordId?: unknown;
  roleId?: unknown;
  action?: unknown;
  reason?: unknown;
}

/** What Discord said, as one of this route's own reasons -- never Discord's body. */
function reasonFor(status: number): { code: number; err: string } {
  if (status === 404) return { code: 404, err: 'member_not_found' };
  if (status === 403) return { code: 502, err: 'bot_cannot_manage' };
  if (status === 401) return { code: 502, err: 'bot_token_rejected' };
  if (status === 429) return { code: 503, err: 'rate_limited' };
  return { code: 502, err: 'discord_error' };
}

export function registerDiscordRoutes(scope: FastifyInstance, config: GatewayConfig, fetcher: DiscordFetch): void {
  const roles = config.roleActions;

  scope.post('/discord/role', async (request, reply) => {
    if (!roles.enabled || !roles.botToken || !roles.guildId) {
      return reply.code(409).send({ ok: false, err: 'disabled' });
    }

    const body = (request.verifiedBody ?? {}) as RoleBody;
    const { discordId, roleId, action, reason } = body;

    if (
      typeof discordId !== 'string' ||
      !SNOWFLAKE.test(discordId) ||
      typeof roleId !== 'string' ||
      !SNOWFLAKE.test(roleId) ||
      (action !== 'add' && action !== 'remove')
    ) {
      return reply.code(400).send({ ok: false, err: 'invalid' });
    }

    if (!roles.allowedRoleIds.has(roleId)) {
      request.log.warn({ roleId }, 'refused a role this gateway does not manage');
      return reply.code(403).send({ ok: false, err: 'role_not_allowed' });
    }

    // Discord shows this in the guild's own audit log. URL-encoded, because
    // that is the header's contract, and bounded.
    const auditReason = encodeURIComponent(
      (typeof reason === 'string' ? reason : '').replace(/[\r\n]+/g, ' ').trim().slice(0, REASON_MAX),
    );

    let response: Response;
    try {
      response = await fetcher(`${API}/guilds/${roles.guildId}/members/${discordId}/roles/${roleId}`, {
        method: action === 'add' ? 'PUT' : 'DELETE',
        headers: {
          Authorization: `Bot ${roles.botToken}`,
          'User-Agent': 'FredPD gateway (role actions)',
          ...(auditReason ? { 'X-Audit-Log-Reason': auditReason } : {}),
        },
        signal: AbortSignal.timeout(10_000),
      });
    } catch {
      request.log.warn({ roleId, action }, 'discord did not answer a role change');
      return reply.code(504).send({ ok: false, err: 'discord_unreachable' });
    }

    // 204 is Discord's answer to both; a role already held (or already gone)
    // is also 204, which is the idempotence a retry needs.
    if (response.status === 204 || response.status === 200) {
      request.log.info({ roleId, action }, 'changed a discord role');
      return { ok: true };
    }

    const failure = reasonFor(response.status);
    // The status, never the body, and never the token.
    request.log.warn({ roleId, action, status: response.status }, 'discord refused a role change');
    return reply.code(failure.code).send({ ok: false, err: failure.err });
  });
}
