import type { ErrorCode } from '@fredpd/schema';

import type { IntelCase, IntelNote, IntelOrg, IntelPerson, IntelTag, PermissionGroup, RoleMapping } from '../types';

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
  modules: ['records', 'intel', 'comms', 'admin'],
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

/**
 * Intelligence fixtures.
 *
 * `notes[1]` comes from an informant and arrives with `source` withheld and
 * `sourceProtected` set, which is what the server sends a reader without
 * `intel.source.view` — the one behaviour PD-Span had no equivalent for, so
 * the browser session shows it by default rather than hiding it.
 */
let intelNotes: IntelNote[] = [
  {
    id: 1,
    personId: 1,
    orgId: 1,
    caseId: null,
    body: 'Black van, no plates, parked on Alta Street twice this week. Same two occupants both times.',
    source: 'patrol',
    confidence: 'medium',
    tags: ['narcotics', 'alta-street'],
    createdBy: '100000000000000001',
    createdAt: '2026-09-16T21:14:00.000Z',
    version: 1,
  },
  {
    id: 2,
    personId: 1,
    orgId: null,
    caseId: 1,
    body: 'Subject is said to be moving product through the laundrette on Popular Street.',
    source: null,
    sourceProtected: true,
    confidence: 'high',
    tags: ['narcotics'],
    createdBy: '100000000000000002',
    createdAt: '2026-09-15T18:02:00.000Z',
    version: 1,
  },
  {
    id: 3,
    personId: null,
    orgId: null,
    caseId: null,
    body: 'Anonymous call: someone is selling firearms out of a lock-up near the docks. No description given.',
    source: 'tip',
    confidence: 'low',
    tags: ['weapons', 'docks'],
    createdBy: '100000000000000001',
    createdAt: '2026-09-14T09:40:00.000Z',
    version: 1,
  },
];

let nextNoteId = 4;

const intelTags: IntelTag[] = [
  { tag: 'narcotics', uses: 2 },
  { tag: 'weapons', uses: 1 },
  { tag: 'alta-street', uses: 1 },
  { tag: 'docks', uses: 1 },
];

const intelPersons: IntelPerson[] = [
  {
    id: 1,
    name: 'Marko Petrov',
    alias: 'Slim',
    description: 'Tall, scar on left cheek.',
    status: 'active_investigation',
    noteCount: 2,
    plates: '4XYZ123',
    version: 1,
  },
  {
    // A person with no identity at all: a description and nothing else. This
    // is deliberate and is how a tip enters the register (spec 10).
    id: 2,
    name: null,
    alias: null,
    description: 'Short, heavy build, grey hooded top, seen with the van on Alta Street.',
    status: 'poi',
    noteCount: 0,
    plates: null,
    version: 1,
  },
];

const intelOrgs: IntelOrg[] = [
  {
    id: 1,
    name: 'Alta Street Crew',
    type: 'crew',
    territory: 'Alta Street, Mirror Park',
    status: 'active',
    memberCount: 4,
    confirmedCount: 2,
    noteCount: 1,
    version: 1,
  },
];

const intelCases: IntelCase[] = [
  {
    id: 1,
    title: 'Operation Kvarnen',
    description: 'Narcotics distribution around Alta Street.',
    status: 'open',
    personCount: 2,
    orgCount: 1,
    noteCount: 1,
    version: 1,
  },
];

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

    'intel.note.list': (input) => {
      const filter = (input ?? {}) as { tag?: string };
      const notes = filter.tag
        ? intelNotes.filter((note) => note.tags.includes(filter.tag as string))
        : intelNotes;

      return { notes };
    },

    'intel.note.create': (input) => {
      const body = input as {
        body: string;
        tags?: string[];
        source?: string;
        confidence?: string;
      };

      intelNotes = [
        {
          id: nextNoteId,
          personId: null,
          orgId: null,
          caseId: null,
          body: body.body,
          source: body.source ?? null,
          confidence: body.confidence ?? 'medium',
          tags: (body.tags ?? []).map((tag) => tag.trim().toLowerCase()).filter(Boolean),
          createdBy: '100000000000000001',
          createdAt: new Date().toISOString(),
          version: 1,
        },
        ...intelNotes,
      ];

      return { id: nextNoteId++ };
    },

    'intel.tags': () => ({ tags: intelTags }),
    'intel.person.list': () => ({ persons: intelPersons }),
    'intel.org.list': () => ({ orgs: intelOrgs }),
    'intel.case.list': () => ({ cases: intelCases }),

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
