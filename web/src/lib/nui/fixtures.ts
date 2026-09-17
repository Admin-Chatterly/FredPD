import type { ErrorCode } from '@fredpd/schema';

import type { PermissionGroup, RoleMapping } from '../types';

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
  permissionsStale: false,
  // Only what this fake session may open. The real list is derived from
  // Discord roles on the server (invariant 2).
  modules: ['records', 'comms', 'admin'],
};

const groups: PermissionGroup[] = [
  { key: 'patrol_basic', name: 'Patrol (trainee)', inherits: null, description: null },
  { key: 'patrol', name: 'Patrol', inherits: 'patrol_basic', description: null },
  { key: 'supervisor', name: 'Supervisor', inherits: 'patrol', description: null },
  { key: 'dispatch', name: 'Dispatch', inherits: 'patrol_basic', description: null },
  { key: 'admin', name: 'FredPD administration', inherits: null, description: null },
];

/**
 * Mutable so the browser session behaves like a real one: adding a mapping and
 * seeing it appear is the whole point of the screen, and a fixture that always
 * returned the same list would hide a broken refresh.
 */
let mappings: RoleMapping[] = [
  {
    id: 1,
    discordRoleId: '100000000000000001',
    discordRoleName: 'Officer',
    groupKey: 'patrol',
    groupName: 'Patrol',
    agencyId: 'lspd',
  },
  {
    id: 2,
    discordRoleId: '100000000000000002',
    discordRoleName: 'Sergeant',
    groupKey: 'supervisor',
    groupName: 'Supervisor',
    agencyId: 'lspd',
  },
];

let nextId = 3;

export const fixtures: FixtureSet = {
  ok: {
    'session.get': () => session,

    'admin.rolemap.list': () => ({
      mappings,
      groups,
      snapshotAgeSeconds: 12,
    }),

    'admin.rolemap.create': (input) => {
      const body = input as {
        discordRoleId: string;
        discordRoleName?: string;
        groupKey: string;
        agencyId: string;
      };

      const group = groups.find((candidate) => candidate.key === body.groupKey);

      mappings = [
        ...mappings,
        {
          id: nextId,
          discordRoleId: body.discordRoleId,
          discordRoleName: body.discordRoleName ?? null,
          groupKey: body.groupKey,
          groupName: group?.name ?? body.groupKey,
          agencyId: body.agencyId,
        },
      ];

      return { id: nextId++ };
    },

    'admin.rolemap.delete': (input) => {
      const { id } = input as { id: number };
      mappings = mappings.filter((mapping) => mapping.id !== id);

      return { id };
    },
  },

  fail: {
    // Proves the shell renders a forbidden state rather than an empty panel.
    'records.person.search': { err: 'forbidden' },
  },
};
