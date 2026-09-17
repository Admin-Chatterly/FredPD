import type { ErrorCode } from '@fredpd/schema';

import type { IntelCase, IntelNote, IntelOrg, IntelPerson, IntelTag, PermissionGroup, RoleMapping } from '../types';
import type { FleetEntry, GroupRow, PermissionRow } from '../../modules/admin/types';
import type { CustodyEntry, EvidenceItem, Scene } from '../../modules/evidence/types';
import type { LabAnalysis } from '../../modules/lab/types';

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
  modules: ['records', 'evidence', 'lab', 'intel', 'comms', 'admin'],
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

/**
 * Evidence, property room and lab fixtures (spec 8).
 *
 * Mutable for the same reason the role mappings are: accepting an item at the
 * counter and watching it move from a locker into a vault is the screen, and a
 * fixture that answered the same list afterwards would hide a broken refresh.
 *
 * What is *not* here is as deliberate as what is. No owner, no weapon serial and
 * no sample quality appears on an evidence row, because the server's own
 * allowlist does not send them (8.11) — a fixture that invented them would let
 * the interface grow a dependency on a field it can never receive.
 */
let evidenceItems: EvidenceItem[] = [
  {
    id: 1,
    ref: 'a41f8c2e9b7d40518e6a2c37bd914f60',
    evidenceNumber: 'LSPD-2026-000118',
    type: 'casing',
    packaging: 'envelope',
    sealState: 'sealed',
    markerNumber: 3,
    description: '9 mm casing, gutter outside 1123 Grove Street.',
    caseNumber: 'LSPD-C26-00045',
    sceneId: 1,
    collectedAt: '2026-09-17T13:02:00.000Z',
    storageLocation: null,
    status: 'collected',
  },
  {
    id: 2,
    ref: 'c7d1e4a09f3b42d6a8150be27c99f3a1',
    evidenceNumber: 'LSPD-2026-000119',
    type: 'blood',
    packaging: 'swab_box',
    sealState: 'sealed',
    markerNumber: 4,
    description: 'Swab from the driver seat.',
    caseNumber: 'LSPD-C26-00045',
    sceneId: 1,
    collectedAt: '2026-09-17T13:11:00.000Z',
    storageLocation: 'Vault A, shelf B-04',
    status: 'in_property',
  },
  {
    id: 3,
    ref: '58b3f0d6ac214e7fb92e61d4c8075a32',
    evidenceNumber: 'LSPD-2026-000120',
    type: 'print',
    packaging: 'lift_card',
    // A broken seal is a fact about the item, not an error: the package was
    // opened at the lab and the chain says who did it (8.5).
    sealState: 'broken',
    markerNumber: null,
    description: 'Latent lift, exterior driver door handle.',
    caseNumber: 'LSPD-C26-00045',
    sceneId: 1,
    collectedAt: '2026-09-17T13:20:00.000Z',
    storageLocation: 'Vault A, shelf B-04',
    status: 'at_lab',
  },
];

const custodyLog: Record<number, CustodyEntry[]> = {
  1: [
    {
      id: 1,
      action: 'collect',
      fromParty: 'LSPD-S-2026-0007',
      toParty: '100000000000000001',
      reason: null,
      signedBy: '100000000000000001',
      occurredAt: '2026-09-17T13:02:00.000Z',
    },
  ],
  2: [
    {
      id: 2,
      action: 'collect',
      fromParty: 'LSPD-S-2026-0007',
      toParty: '100000000000000001',
      reason: null,
      signedBy: '100000000000000001',
      occurredAt: '2026-09-17T13:11:00.000Z',
    },
    {
      id: 3,
      action: 'intake',
      fromParty: '100000000000000001',
      toParty: 'Vault A, shelf B-04',
      reason: 'Seal intact, description matches.',
      signedBy: '100000000000000002',
      occurredAt: '2026-09-17T13:40:00.000Z',
    },
  ],
  3: [
    {
      id: 4,
      action: 'intake',
      fromParty: '100000000000000001',
      toParty: 'Vault A, shelf B-04',
      reason: null,
      signedBy: '100000000000000002',
      occurredAt: '2026-09-17T13:44:00.000Z',
    },
    {
      id: 5,
      action: 'checkout',
      fromParty: 'Vault A, shelf B-04',
      toParty: 'Forensic lab',
      reason: 'Latent comparison requested on LSPD-C26-00045.',
      signedBy: '100000000000000002',
      occurredAt: '2026-09-17T14:05:00.000Z',
    },
  ],
};

let scenes: Scene[] = [
  {
    id: 1,
    sceneNumber: 'LSPD-S-2026-0007',
    caseNumber: 'LSPD-C26-00045',
    x: 12.4,
    y: -1120.8,
    z: 29.8,
    radius: 25,
    status: 'open',
    createdBy: '100000000000000001',
    createdAt: '2026-09-17T12:55:00.000Z',
    releasedBy: null,
    releasedAt: null,
    evidenceCount: 3,
    entryCount: 5,
  },
  {
    id: 2,
    sceneNumber: 'LSPD-S-2026-0006',
    caseNumber: null,
    x: -47.2,
    y: 220.1,
    z: 71.2,
    radius: 15,
    status: 'released',
    createdBy: '100000000000000002',
    createdAt: '2026-09-16T22:10:00.000Z',
    releasedBy: '100000000000000002',
    releasedAt: '2026-09-17T01:30:00.000Z',
    evidenceCount: 1,
    entryCount: 2,
  },
];

/**
 * The lab queue. One of each state, because the three rows behave differently:
 * queued can be started, in progress can be completed, and a finished one
 * carries a result — which is the only row where `resultCode` is present at all.
 */
let labQueue: LabAnalysis[] = [
  {
    id: 1,
    requestId: 1,
    evidenceId: 2,
    evidenceNumber: 'LSPD-2026-000119',
    analysis: 'dna',
    status: 'queued',
    assignedTo: null,
    startedAt: null,
    dueAt: null,
    completedAt: null,
    priority: 'expedited',
    caseNumber: 'LSPD-C26-00045',
  },
  {
    id: 2,
    requestId: 1,
    evidenceId: 3,
    evidenceNumber: 'LSPD-2026-000120',
    analysis: 'print_comparison',
    status: 'in_progress',
    assignedTo: '100000000000000001',
    startedAt: '2026-09-17T14:10:00.000Z',
    dueAt: '2026-09-17T14:40:00.000Z',
    completedAt: null,
    priority: 'routine',
    caseNumber: 'LSPD-C26-00045',
  },
  {
    id: 3,
    requestId: 1,
    evidenceId: 1,
    evidenceNumber: 'LSPD-2026-000118',
    analysis: 'ballistics',
    status: 'complete',
    assignedTo: '100000000000000002',
    startedAt: '2026-09-17T13:30:00.000Z',
    dueAt: '2026-09-17T14:00:00.000Z',
    completedAt: '2026-09-17T14:02:00.000Z',
    priority: 'routine',
    caseNumber: 'LSPD-C26-00045',
    resultCode: 'candidate_match',
    observations: 'Barrel marks legible; correlated against the open file.',
  },
];

let nextEvidenceId = 4;
let nextSceneId = 3;
let nextCustodyId = 6;
let nextAnalysisId = 4;
let nextRequestId = 2;

/** Where a transfer destination leaves an item, mirroring the server's table. */
const TRANSFER_STATUS: Record<string, string> = {
  locker: 'in_locker',
  lab: 'at_lab',
  court: 'checked_out',
  investigator: 'checked_out',
};

/**
 * A plausible conclusion per analysis, so the completed state can be walked in
 * a browser. The real code comes from hidden truth on the server and is not
 * something this file could compute even if it wanted to (8.1).
 */
const FIXTURE_RESULT: Record<string, string> = {
  dna: 'profile_obtained',
  print_comparison: 'identification',
  print_search: 'candidate_match',
  ballistics: 'candidate_match',
  gsr: 'no_match',
  drug_id: 'identification',
};

function appendCustody(evidenceId: number, entry: Omit<CustodyEntry, 'id'>): void {
  custodyLog[evidenceId] = [...(custodyLog[evidenceId] ?? []), { id: nextCustodyId++, ...entry }];
}

// ------------------------------------------------------- permission groups

/**
 * What `admin.group.list` sends: the rows plus the two decisions the server
 * made for the editor — whether this session may author each group, and (in the
 * catalogue below) whether it could grant each key at all.
 */
let groupRows: GroupRow[] = [
  {
    key: 'patrol_basic',
    name: 'Patrol (trainee)',
    inherits: null,
    description: null,
    createdAt: '2026-08-01T10:00:00.000Z',
    childCount: 2,
    roleMapCount: 0,
    agencyRoleMapCount: 0,
    permissions: ['evidence.item.view'],
    effective: ['evidence.item.view'],
    locked: false,
    editable: true,
  },
  {
    key: 'patrol',
    name: 'Patrol',
    inherits: 'patrol_basic',
    description: null,
    createdAt: '2026-08-01T10:00:00.000Z',
    childCount: 1,
    roleMapCount: 1,
    agencyRoleMapCount: 1,
    permissions: ['forensics.evidence.collect', 'forensics.scene.create'],
    effective: ['evidence.item.view', 'forensics.evidence.collect', 'forensics.scene.create'],
    locked: false,
    editable: true,
  },
  {
    key: 'supervisor',
    name: 'Supervisor',
    inherits: 'patrol',
    description: null,
    createdAt: '2026-08-01T10:00:00.000Z',
    childCount: 0,
    roleMapCount: 1,
    agencyRoleMapCount: 1,
    permissions: ['evidence.item.intake', 'evidence.item.transfer', 'forensics.scene.release'],
    effective: [
      'evidence.item.intake',
      'evidence.item.transfer',
      'evidence.item.view',
      'forensics.evidence.collect',
      'forensics.scene.create',
      'forensics.scene.release',
    ],
    locked: false,
    editable: true,
  },
  {
    key: 'lab',
    name: 'Forensic lab',
    inherits: null,
    description: null,
    createdAt: '2026-08-01T10:00:00.000Z',
    childCount: 0,
    roleMapCount: 0,
    agencyRoleMapCount: 0,
    permissions: ['lab.analysis.perform', 'lab.queue.view', 'lab.request.create'],
    effective: ['lab.analysis.perform', 'lab.queue.view', 'lab.request.create'],
    // A bundle this session does not itself hold: the editor draws it, the
    // server refuses to let it be authored.
    locked: false,
    editable: false,
  },
  {
    key: 'admin',
    name: 'FredPD administration',
    inherits: null,
    description: null,
    createdAt: '2026-08-01T10:00:00.000Z',
    childCount: 0,
    roleMapCount: 0,
    agencyRoleMapCount: 0,
    permissions: ['admin.groups.edit', 'admin.rolemap.edit', 'garage.fleet.edit'],
    effective: ['admin.groups.edit', 'admin.rolemap.edit', 'garage.fleet.edit'],
    // The administration group. It cannot be renamed, emptied or deleted.
    locked: true,
    editable: true,
  },
];

const permissionCatalogue: PermissionRow[] = [
  { key: 'admin.groups.edit', area: 'admin', groupCount: 1, grantable: true },
  { key: 'admin.rolemap.edit', area: 'admin', groupCount: 1, grantable: true },
  { key: 'evidence.item.intake', area: 'evidence', groupCount: 1, grantable: true },
  { key: 'evidence.item.transfer', area: 'evidence', groupCount: 1, grantable: true },
  { key: 'evidence.item.view', area: 'evidence', groupCount: 1, grantable: true },
  { key: 'forensics.evidence.collect', area: 'forensics', groupCount: 1, grantable: true },
  { key: 'forensics.scene.create', area: 'forensics', groupCount: 1, grantable: true },
  { key: 'forensics.scene.release', area: 'forensics', groupCount: 1, grantable: true },
  { key: 'garage.fleet.edit', area: 'garage', groupCount: 1, grantable: true },
  // Not held by this session, so it cannot be put into a bundle: the checkbox
  // arrives disabled because the server said so, not because the UI decided.
  { key: 'lab.analysis.perform', area: 'lab', groupCount: 1, grantable: false },
  { key: 'lab.queue.view', area: 'lab', groupCount: 1, grantable: false },
  { key: 'lab.request.create', area: 'lab', groupCount: 1, grantable: false },
];

// --------------------------------------------------------------- motor pool

let fleetRows: FleetEntry[] = [
  {
    id: 1,
    model: 'police3',
    labelKey: 'fleet.patrol_sedan',
    permission: null,
    certification: null,
    livery: 0,
    sortOrder: 10,
    enabled: true,
    requiredGroup: null,
    requiredDiscordRole: null,
  },
  {
    id: 2,
    model: 'riot',
    labelKey: 'fleet.riot',
    permission: null,
    certification: null,
    livery: null,
    sortOrder: 20,
    enabled: true,
    // Gated by a group. Either gate opens the vehicle.
    requiredGroup: 'supervisor',
    requiredDiscordRole: null,
  },
  {
    id: 3,
    model: 'polmav',
    labelKey: 'fleet.helicopter',
    permission: null,
    certification: 'air',
    livery: null,
    sortOrder: 30,
    enabled: false,
    requiredGroup: null,
    // The case migration 0003 exists for: a Discord role that is already
    // maintained, with no permission group behind it.
    requiredDiscordRole: '100000000000000009',
  },
];

let nextFleetId = 4;

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

    // ------------------------------------------------------------- evidence

    'evidence.list': (input) => {
      const filter = (input ?? {}) as { status?: string; type?: string; search?: string };
      const search = filter.search?.toLowerCase();

      return {
        items: evidenceItems.filter((item) => {
          if (filter.status && item.status !== filter.status) return false;
          if (filter.type && item.type !== filter.type) return false;
          if (!search) return true;

          return [item.evidenceNumber, item.caseNumber, item.description].some((field) =>
            field?.toLowerCase().includes(search),
          );
        }),
      };
    },

    'evidence.get': (input) => {
      const { id } = input as { id: number };

      return {
        id,
        item: evidenceItems.find((item) => item.id === id) ?? null,
        analyses: labQueue.filter((analysis) => analysis.evidenceId === id),
      };
    },

    'evidence.custody': (input) => {
      const { id } = input as { id: number };
      return { id, custody: custodyLog[id] ?? [] };
    },

    'evidence.collect': (input) => {
      const body = input as {
        sceneId?: number;
        packaging: string;
        markerNumber?: number;
        description?: string;
      };

      // The type is the server's to decide, from its own grid. The fixture
      // stands in for that: it is not read from the call.
      const item: EvidenceItem = {
        id: nextEvidenceId,
        ref: `fixture${String(nextEvidenceId).padStart(26, '0')}`,
        evidenceNumber: `LSPD-2026-${String(120 + nextEvidenceId).padStart(6, '0')}`,
        type: 'print',
        packaging: body.packaging,
        sealState: 'sealed',
        markerNumber: body.markerNumber ?? null,
        description: body.description ?? null,
        caseNumber: scenes.find((scene) => scene.id === body.sceneId)?.caseNumber ?? null,
        sceneId: body.sceneId ?? null,
        collectedAt: new Date().toISOString(),
        storageLocation: null,
        status: 'collected',
      };

      evidenceItems = [item, ...evidenceItems];
      appendCustody(item.id, {
        action: 'collect',
        fromParty: scenes.find((scene) => scene.id === body.sceneId)?.sceneNumber ?? null,
        toParty: '100000000000000001',
        reason: null,
        signedBy: '100000000000000001',
        occurredAt: item.collectedAt,
      });

      nextEvidenceId += 1;

      return { id: item.id, item };
    },

    'evidence.intake': (input) => {
      const body = input as {
        id: number;
        accepted: boolean;
        storageLocation?: string;
        reason?: string;
      };

      const holder = custodyLog[body.id]?.at(-1)?.toParty ?? null;

      if (body.accepted && body.storageLocation) {
        evidenceItems = evidenceItems.map((item) =>
          item.id === body.id
            ? { ...item, status: 'in_property', storageLocation: body.storageLocation ?? null }
            : item,
        );
      }

      // A rejection is part of the chain, not the absence of one.
      appendCustody(body.id, {
        action: 'intake',
        fromParty: holder,
        toParty: body.accepted ? (body.storageLocation ?? null) : holder,
        reason: body.reason ?? null,
        signedBy: '100000000000000002',
        occurredAt: new Date().toISOString(),
      });

      return { id: body.id, accepted: body.accepted };
    },

    'evidence.transfer': (input) => {
      const body = input as { id: number; destination: string; toParty?: string; reason: string };
      const status = TRANSFER_STATUS[body.destination] ?? 'collected';
      const holder = custodyLog[body.id]?.at(-1)?.toParty ?? null;

      evidenceItems = evidenceItems.map((item) =>
        item.id === body.id ? { ...item, status } : item,
      );

      appendCustody(body.id, {
        action: body.destination === 'locker' ? 'deposit' : 'checkout',
        fromParty: holder,
        toParty: body.toParty ?? body.destination,
        reason: body.reason,
        signedBy: '100000000000000001',
        occurredAt: new Date().toISOString(),
      });

      return { id: body.id, status };
    },

    'scene.list': (input) => {
      const filter = (input ?? {}) as { status?: string };

      return {
        scenes: filter.status ? scenes.filter((scene) => scene.status === filter.status) : scenes,
      };
    },

    'scene.create': (input) => {
      const body = (input ?? {}) as { caseNumber?: string; radius?: number };

      // No coordinates in the call: the perimeter is where the server says the
      // officer is standing.
      const scene: Scene = {
        id: nextSceneId,
        sceneNumber: `LSPD-S-2026-${String(nextSceneId).padStart(4, '0')}`,
        caseNumber: body.caseNumber ?? null,
        x: 0,
        y: 0,
        z: 0,
        radius: body.radius ?? 25,
        status: 'open',
        createdBy: '100000000000000001',
        createdAt: new Date().toISOString(),
        releasedBy: null,
        releasedAt: null,
        evidenceCount: 0,
        entryCount: 0,
      };

      scenes = [scene, ...scenes];
      nextSceneId += 1;

      return { id: scene.id, scene };
    },

    'scene.release': (input) => {
      const { id } = input as { id: number };

      scenes = scenes.map((scene) =>
        scene.id === id
          ? {
              ...scene,
              status: 'released',
              releasedBy: '100000000000000002',
              releasedAt: new Date().toISOString(),
            }
          : scene,
      );

      return { id };
    },

    // ------------------------------------------------------------------ lab

    'lab.queue': (input) => {
      const filter = (input ?? {}) as { status?: string; analysis?: string; mine?: boolean };

      return {
        queue: labQueue.filter((row) => {
          if (filter.status && row.status !== filter.status) return false;
          if (filter.analysis && row.analysis !== filter.analysis) return false;
          if (filter.mine && row.assignedTo !== '100000000000000001') return false;
          return true;
        }),
      };
    },

    'lab.request.create': (input) => {
      const body = input as {
        evidenceIds: string[];
        analyses: string[];
        priority?: string;
        caseNumber?: string;
      };

      const queued: LabAnalysis[] = [];

      for (const rawId of body.evidenceIds) {
        const evidenceId = Number.parseInt(rawId, 10);
        const item = evidenceItems.find((candidate) => candidate.id === evidenceId);

        for (const analysis of body.analyses) {
          queued.push({
            id: nextAnalysisId++,
            requestId: nextRequestId,
            evidenceId,
            evidenceNumber: item?.evidenceNumber ?? null,
            analysis,
            status: 'queued',
            assignedTo: null,
            startedAt: null,
            dueAt: null,
            completedAt: null,
            priority: body.priority ?? 'routine',
            caseNumber: body.caseNumber ?? item?.caseNumber ?? null,
          });
        }
      }

      labQueue = [...queued, ...labQueue];

      return { id: nextRequestId++, queued: queued.length };
    },

    'lab.analysis.start': (input) => {
      const { id } = input as { id: number };
      const seconds = 1800;
      const row = labQueue.find((candidate) => candidate.id === id);

      labQueue = labQueue.map((candidate) =>
        candidate.id === id
          ? {
              ...candidate,
              status: 'in_progress',
              assignedTo: '100000000000000001',
              startedAt: new Date().toISOString(),
              // Persisted as a time, never counted down in the interface.
              dueAt: new Date(Date.now() + seconds * 1000).toISOString(),
            }
          : candidate,
      );

      return { id, analysis: row?.analysis ?? 'dna', seconds };
    },

    'lab.analysis.complete': (input) => {
      const body = input as { id: number; observations?: string };
      const row = labQueue.find((candidate) => candidate.id === body.id);
      const resultCode = FIXTURE_RESULT[row?.analysis ?? 'dna'] ?? 'insufficient';

      // The real route refuses until the due time has genuinely passed. The
      // fixture lets it through so the finished state can be walked in a
      // browser; the conflict path is exercised with ?fail=conflict.
      labQueue = labQueue.map((candidate) =>
        candidate.id === body.id
          ? {
              ...candidate,
              status: 'complete',
              completedAt: new Date().toISOString(),
              resultCode,
              observations: body.observations ?? null,
            }
          : candidate,
      );

      return { id: body.id, analysis: row?.analysis ?? 'dna', resultCode };
    },

    // ------------------------------------------------------ permission groups

    'admin.group.list': () => ({ groups: groupRows }),

    'admin.permission.list': () => ({ permissions: permissionCatalogue }),

    'admin.group.create': (input) => {
      const body = input as {
        key: string;
        name: string;
        inherits?: string;
        description?: string;
        permissions: string[];
      };

      groupRows = [
        ...groupRows,
        {
          key: body.key,
          name: body.name,
          inherits: body.inherits ?? null,
          description: body.description ?? null,
          createdAt: new Date().toISOString(),
          childCount: 0,
          roleMapCount: 0,
          agencyRoleMapCount: 0,
          permissions: body.permissions,
          effective: body.permissions,
          locked: false,
          editable: true,
        },
      ].sort((left, right) => left.key.localeCompare(right.key));

      return { id: body.key, key: body.key, permissions: body.permissions };
    },

    'admin.group.update': (input) => {
      const body = input as {
        key: string;
        name?: string;
        inherits?: string;
        description?: string;
        permissions?: string[];
      };

      groupRows = groupRows.map((group) =>
        group.key === body.key
          ? {
              ...group,
              name: body.name ?? group.name,
              inherits: body.inherits === undefined ? group.inherits : body.inherits || null,
              description:
                body.description === undefined ? group.description : body.description || null,
              permissions: body.permissions ?? group.permissions,
              effective: body.permissions ?? group.effective,
            }
          : group,
      );

      return { id: body.key, key: body.key, permissions: body.permissions ?? [], added: [], removed: [] };
    },

    'admin.group.delete': (input) => {
      const { key } = input as { key: string };
      groupRows = groupRows.filter((group) => group.key !== key);

      return { id: key, key, permissions: [] };
    },

    // ----------------------------------------------------------- motor pool

    'garage.fleet.manage': () => ({
      fleet: fleetRows,
      groups: groupRows.map((group) => group.key),
    }),

    'garage.fleet.add': (input) => {
      const body = input as Partial<FleetEntry> & { model: string; labelKey: string };

      const entry: FleetEntry = {
        id: nextFleetId,
        model: body.model,
        labelKey: body.labelKey,
        permission: body.permission || null,
        certification: body.certification || null,
        livery: body.livery ?? null,
        sortOrder: body.sortOrder ?? 0,
        enabled: body.enabled ?? true,
        requiredGroup: body.requiredGroup || null,
        requiredDiscordRole: body.requiredDiscordRole || null,
      };

      fleetRows = [...fleetRows, entry].sort(
        (left, right) => left.sortOrder - right.sortOrder || left.model.localeCompare(right.model),
      );

      nextFleetId += 1;

      return { id: entry.id, model: entry.model };
    },

    'garage.fleet.update': (input) => {
      const body = input as Partial<FleetEntry> & { id: number };

      fleetRows = fleetRows.map((entry) =>
        entry.id === body.id
          ? {
              ...entry,
              model: body.model ?? entry.model,
              labelKey: body.labelKey ?? entry.labelKey,
              // An empty string clears the gate; an absent field leaves it.
              permission: body.permission === undefined ? entry.permission : body.permission || null,
              certification:
                body.certification === undefined ? entry.certification : body.certification || null,
              livery: body.livery === undefined ? entry.livery : body.livery,
              sortOrder: body.sortOrder ?? entry.sortOrder,
              enabled: body.enabled ?? entry.enabled,
              requiredGroup:
                body.requiredGroup === undefined ? entry.requiredGroup : body.requiredGroup || null,
              requiredDiscordRole:
                body.requiredDiscordRole === undefined
                  ? entry.requiredDiscordRole
                  : body.requiredDiscordRole || null,
            }
          : entry,
      );

      return { id: body.id, model: body.model };
    },

    'garage.fleet.remove': (input) => {
      const { id } = input as { id: number };
      const entry = fleetRows.find((candidate) => candidate.id === id);

      fleetRows = fleetRows.filter((candidate) => candidate.id !== id);

      return { id, model: entry?.model };
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
