import type { ErrorCode } from '@fredpd/schema';

/**
 * Fixtures for browser development (spec 17.2, M0).
 *
 * A fixture answers one route. Keeping them here rather than inside components
 * means the mock bridge stays a transport and the data stays reviewable: when a
 * route's real shape changes, this file is the diff that proves the UI was
 * updated with it.
 *
 * Fixtures describe what an *authorized* session sees. They are not a
 * permission model: the server decides that, and the UI is never the control
 * (invariant 4).
 */

export type Fixture = (input: unknown) => unknown;

/** A route that should answer with a failure, to exercise the error paths. */
export interface FixtureFailure {
  err: ErrorCode;
  fields?: Record<string, string>;
}

export interface FixtureSet {
  ok: Record<string, Fixture>;
  fail: Record<string, FixtureFailure>;
}

const session = {
  officerId: 'OFF-1042',
  callsign: '12-40',
  name: 'A. Lindqvist',
  agencyId: 'lspd',
  agencyName: 'Los Santos Police Department',
  onDuty: true,
  accessPoint: 'station',
  // Only what this fake session may open. The real list is derived from
  // Discord roles on the server (invariant 2).
  modules: ['records', 'admin'],
  permissions: ['records.person.search', 'admin.permission.view'],
};

export const fixtures: FixtureSet = {
  ok: {
    'session.get': () => session,

    'session.setStatus': (input) => ({
      ...session,
      status: (input as { status?: string } | undefined)?.status ?? 'available',
    }),

    'admin.permission.view': () => ({
      groups: [
        { key: 'patrol', name: 'Patrol', discordRoleId: '000000000000000001', members: 24 },
        { key: 'investigations', name: 'Investigations', discordRoleId: '000000000000000002', members: 6 },
        { key: 'command', name: 'Command', discordRoleId: '000000000000000003', members: 3 },
      ],
      snapshotAgeSeconds: 12,
    }),
  },

  fail: {
    // Proves the shell renders a forbidden state rather than an empty panel.
    'records.person.search': { err: 'forbidden' },
  },
};
