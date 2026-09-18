import type { ErrorCode } from '@fredpd/schema';

import type { IntelCase, IntelNote, IntelOrg, IntelPerson, IntelTag, PermissionGroup, RoleMapping } from '../types';
import type { FleetEntry, GroupRow, PermissionRow } from '../../modules/admin/types';
import type { CustodyEntry, EvidenceItem, Scene } from '../../modules/evidence/types';
import type { LabAnalysis } from '../../modules/lab/types';
import { isStub } from '../../modules/records/types';
import type { Maybe, PersonResult, VehicleResult } from '../../modules/records/types';

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

/**
 * Pushes a message the way the game would (spec 3.6).
 *
 * A route that writes something also pushes it to the sessions allowed to see
 * it, and until this existed no fixture could do the second half: the mock
 * bridge's own emitter is private to its closure and only ever fires
 * `fredpd:open`. So a console driven by fixtures showed the answer to the call
 * it had just made and nothing that a *push* produces — which is how the CAD
 * module reached a milestone with an officer-down banner that had never been
 * drawn outside the game.
 *
 * `window.postMessage` is the real transport's own shape: inside FiveM a push
 * arrives at the NUI as exactly this message and `real.ts` fans it out. The
 * CAD subscriptions pick it up through `modules/cad/push.ts`, which listens for
 * it in mock mode only, so nothing about the game path changes.
 *
 * Asynchronous on purpose. A route's own answer has not been returned yet when
 * a fixture calls this, and a push that arrived before the write it belongs to
 * would let a component see an ordering the server can never produce.
 */
function push(message: Record<string, unknown> & { type: string }): void {
  if (typeof window === 'undefined') return;

  setTimeout(() => window.postMessage(message, window.location.origin), 0);
}

/** A route that should answer with a failure, to exercise the error paths. */
export interface FixtureFailure {
  err: ErrorCode;
  fields?: Record<string, string>;
}

/**
 * A refusal a fixture decides on, rather than one the route always gives.
 *
 * `fail` above marks a whole route as refusing. Some refusals depend on the
 * call: saving a group whose version has moved on answers `conflict`, and that
 * is the only thing the version column exists for. A fixture that always
 * accepted would make it the one path nobody can walk without a game server.
 */
const REFUSAL = Symbol('fixture refusal');

export interface FixtureRefusal extends FixtureFailure {
  [REFUSAL]: true;
}

export function refuse(err: ErrorCode, fields?: Record<string, string>): FixtureRefusal {
  return { [REFUSAL]: true, err, ...(fields ? { fields } : {}) };
}

export function isRefusal(value: unknown): value is FixtureRefusal {
  return typeof value === 'object' && value !== null && REFUSAL in value;
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
  modules: ['records', 'dispatch', 'evidence', 'lab', 'intel', 'comms', 'admin'],
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
    version: 1,
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
    version: 1,
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
    version: 1,
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
    version: 1,
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
    version: 1,
    name: 'FredPD administration',
    inherits: null,
    description: null,
    createdAt: '2026-08-01T10:00:00.000Z',
    childCount: 0,
    roleMapCount: 0,
    agencyRoleMapCount: 0,
    // The keys the seed actually grants `admin` (database/seeds/0001): the
    // module itself, and the two editing powers held apart from each other.
    permissions: ['admin.groups.edit', 'admin.permissions.edit', 'garage.fleet.edit', 'page.admin'],
    effective: ['admin.groups.edit', 'admin.permissions.edit', 'garage.fleet.edit', 'page.admin'],
    // The administration group. It cannot be renamed, emptied or deleted.
    locked: true,
    editable: true,
  },
];

const permissionCatalogue: PermissionRow[] = [
  { key: 'admin.groups.edit', area: 'admin', groupCount: 1, grantable: true },
  { key: 'admin.permissions.edit', area: 'admin', groupCount: 1, grantable: true },
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
  // Which module rail entries a group opens is a permission like any other, and
  // the editor has to be able to draw the one the admin group itself holds.
  { key: 'page.admin', area: 'page', groupCount: 1, grantable: true },
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

// ----------------------------------------------------------------- dispatch

/**
 * Dispatch fixtures (spec 7.16, 7.17).
 *
 * The shapes below mirror the columns `server/modules/cad/repo.lua` selects,
 * and they are declared here rather than imported because the console's types
 * live in the module script of `modules/cad/Dispatch.svelte`: a `.svelte` file
 * is not something `tsc --noEmit` can resolve, so importing from one would fail
 * `pnpm typecheck` while passing `svelte-check`. Anything that drifts between
 * the two is a fixture that lies about the server, which is the one thing a
 * fixture must not do.
 *
 * The browser session is a dispatcher who is **also signed on as a unit**
 * (`12-40`, the callsign `session` above already carries). That is a real state
 * on a real server, and it is the one that leaves every path walkable without a
 * game server: a session with no `fpd_units` row would answer `no_unit` to
 * self-assign, to progress, to the status form and to the emergency button, and
 * four of the console's screens could never be seen working.
 */

interface CadCall {
  id: number;
  agencyId: string;
  callNumber: string;
  type: string;
  priority: number;
  status: string;
  x: number | null;
  y: number | null;
  z: number | null;
  locationText: string | null;
  beatId: number | null;
  callerName: string | null;
  callerPhone: string | null;
  source: string;
  sourceResource: string | null;
  receivedAt: string;
  receivedAtUnix: number;
  dispatchedAt: string | null;
  enRouteAt: string | null;
  onSceneAt: string | null;
  clearedAt: string | null;
  disposition: string | null;
  acknowledgedBy: string | null;
  acknowledgedAt: string | null;
}

interface CadAssignment {
  id: number;
  callId: number;
  officerId: number;
  callsign: string;
  isLead: number | null;
  joinedAt: string;
  leftAt: string | null;
  active: number | null;
}

interface CadLogEntry {
  id: number;
  callId: number;
  entryType: string;
  body: string | null;
  messageKey: string | null;
  messageArgs: Record<string, string | number> | null;
  callsign: string | null;
  createdAt: string;
  createdAtUnix: number;
}

interface CadLink {
  id: number;
  callId: number;
  targetType: string;
  targetId: number;
  role: string;
  label: string;
  detail: string | null;
  createdAt: string;
}

interface CadUnit {
  officerId: number;
  agencyId: string;
  callsign: string;
  status: string;
  statusSince: string;
  statusSinceUnix: number;
  beatId: number | null;
  division: string | null;
  vehiclePlate: string | null;
  vehicleModel: string | null;
  x: number | null;
  y: number | null;
  z: number | null;
  heading: number | null;
  positionAtUnix: number | null;
  onCallId: number | null;
  onCallLead: number | null;
  onCallNumber: string | null;
  onCallPriority: number | null;
  onCallStatus: string | null;
}

interface CadBroadcast {
  id: number;
  kind: string;
  priority: number;
  title: string;
  body: string;
  plate: string | null;
  callId: number | null;
  expiresAt: string | null;
  cancelledAt: string | null;
  createdAt: string;
}

/** The session's own unit. `call.self_assign` names no officer; this is it. */
const OWN_OFFICER_ID = 1;

function minutesAgo(minutes: number): { at: string; unix: number } {
  const date = new Date(Date.now() - minutes * 60_000);

  return { at: date.toISOString(), unix: Math.floor(date.getTime() / 1000) };
}

function inMinutes(minutes: number): string {
  return new Date(Date.now() + minutes * 60_000).toISOString();
}

/** `260917-0042`, as `fpd_counters` allocates one. Never from input. */
function callNumberFor(sequence: number): string {
  const now = new Date();
  const stamp = [now.getFullYear() % 100, now.getMonth() + 1, now.getDate()]
    .map((part) => String(part).padStart(2, '0'))
    .join('');

  return `${stamp}-${String(sequence).padStart(4, '0')}`;
}

let nextCallId = 4;
let nextLogId = 20;
let nextAssignmentId = 10;
let nextBroadcastId = 3;
let nextLinkId = 3;
let callSequence = 44;

const shotsFired = minutesAgo(4);
const collision = minutesAgo(26);
const welfare = minutesAgo(52);

let cadCalls: CadCall[] = [
  {
    id: 1,
    agencyId: 'lspd',
    callNumber: callNumberFor(41),
    type: 'shots_fired',
    priority: 1,
    status: 'pending',
    x: 232.4,
    y: -868.1,
    z: 30.5,
    locationText: 'Vespucci Boulevard at Prosperity Street',
    beatId: 1,
    callerName: 'L. Nyberg',
    callerPhone: '555-0142',
    source: 'phone',
    sourceResource: null,
    receivedAt: shotsFired.at,
    receivedAtUnix: shotsFired.unix,
    dispatchedAt: null,
    enRouteAt: null,
    onSceneAt: null,
    clearedAt: null,
    disposition: null,
    acknowledgedBy: null,
    acknowledgedAt: null,
  },
  {
    id: 2,
    agencyId: 'lspd',
    callNumber: callNumberFor(42),
    type: 'traffic_collision',
    priority: 2,
    status: 'on_scene',
    x: 128.9,
    y: -1040.7,
    z: 29.3,
    locationText: 'Alta Street at Power Street',
    beatId: 1,
    callerName: 'Anonymous',
    callerPhone: null,
    source: 'dispatcher',
    sourceResource: null,
    receivedAt: collision.at,
    receivedAtUnix: collision.unix,
    dispatchedAt: minutesAgo(24).at,
    enRouteAt: minutesAgo(23).at,
    onSceneAt: minutesAgo(18).at,
    clearedAt: null,
    disposition: null,
    acknowledgedBy: null,
    acknowledgedAt: null,
  },
  {
    /**
     * A call taken over the phone that the caller could only describe. It has
     * no coordinates, which is why `call.get` answers it with no
     * recommendation at all — the console draws no panel rather than an empty
     * one, and this row is what makes that path walkable.
     */
    id: 3,
    agencyId: 'lspd',
    callNumber: callNumberFor(43),
    type: 'welfare_check',
    priority: 3,
    status: 'pending',
    x: null,
    y: null,
    z: null,
    locationText: 'Somewhere on Grove Street, the caller was not sure which house',
    beatId: 2,
    callerName: 'M. Ek',
    callerPhone: '555-0198',
    source: 'phone',
    sourceResource: null,
    receivedAt: welfare.at,
    receivedAtUnix: welfare.unix,
    dispatchedAt: null,
    enRouteAt: null,
    onSceneAt: null,
    clearedAt: null,
    disposition: null,
    acknowledgedBy: null,
    acknowledgedAt: null,
  },
];

let cadAssignments: CadAssignment[] = [
  {
    id: 1,
    callId: 2,
    officerId: 2,
    callsign: '3A-12',
    isLead: 1,
    joinedAt: minutesAgo(24).at,
    leftAt: null,
    active: 1,
  },
];

let cadLog: CadLogEntry[] = [
  {
    id: 1,
    callId: 1,
    entryType: 'created',
    body: 'Caller heard four or five shots from the car park behind the shop and saw two people run east.',
    messageKey: 'cad.log.created',
    messageArgs: null,
    callsign: null,
    createdAt: shotsFired.at,
    createdAtUnix: shotsFired.unix,
  },
  {
    id: 2,
    callId: 2,
    entryType: 'created',
    body: null,
    messageKey: 'cad.log.created',
    messageArgs: null,
    callsign: null,
    createdAt: collision.at,
    createdAtUnix: collision.unix,
  },
  {
    id: 3,
    callId: 2,
    entryType: 'dispatched',
    body: null,
    messageKey: 'cad.log.dispatched',
    messageArgs: { callsign: '3A-12' },
    callsign: '12-40',
    createdAt: minutesAgo(24).at,
    createdAtUnix: minutesAgo(24).unix,
  },
  {
    id: 4,
    callId: 2,
    entryType: 'unit_status',
    body: null,
    // The argument names a vocabulary, so it carries the enum member and the
    // console resolves it through `cad.unitStatus.*` in the reader's language.
    messageKey: 'cad.log.unit_status',
    messageArgs: { callsign: '3A-12', status: 'on_scene' },
    callsign: '3A-12',
    createdAt: minutesAgo(18).at,
    createdAtUnix: minutesAgo(18).unix,
  },
  {
    id: 5,
    callId: 2,
    entryType: 'note',
    body: 'Two vehicles, no injuries. Tow requested for the second one.',
    messageKey: null,
    messageArgs: null,
    callsign: '3A-12',
    createdAt: minutesAgo(16).at,
    createdAtUnix: minutesAgo(16).unix,
  },
  {
    id: 6,
    callId: 3,
    entryType: 'created',
    body: null,
    messageKey: 'cad.log.created',
    messageArgs: null,
    callsign: null,
    createdAt: welfare.at,
    createdAtUnix: welfare.unix,
  },
];

/**
 * The persons and vehicles on the collision call.
 *
 * This was a `const`, and said so at length: `call.link` was a route with a
 * schema, a permission and a grant that nothing in the interface called,
 * because linking needs the register's row id and the card had no picker to
 * produce one. The card has one now, so the list moves — and the register rows
 * it picks from are the `registerPersons` and `registerVehicles` fixtures
 * below, deliberately the same ids these two rows already point at, so a
 * dispatcher searching the picker meets the records the collision call is
 * already linked to rather than a second, parallel department.
 */
let cadLinks: CadLink[] = [
  {
    id: 1,
    callId: 2,
    targetType: 'person',
    targetId: 1,
    role: 'involved',
    // As `Repo.linkTarget` builds it: `TRIM(CONCAT(first_name, ' ',
    // last_name))`, and the plate on the row below. It read `DOE, John A.`
    // here, which is how a records index prints a name and not how this column
    // is filled — a fixture inventing a format the server does not write is
    // how a screen gets built around one.
    label: 'John Doe',
    detail: null,
    createdAt: minutesAgo(17).at,
  },
  {
    id: 2,
    callId: 2,
    targetType: 'vehicle',
    targetId: 1,
    role: 'involved',
    label: '45ABC123',
    detail: null,
    createdAt: minutesAgo(17).at,
  },
];

let cadUnits: CadUnit[] = [
  {
    officerId: OWN_OFFICER_ID,
    agencyId: 'lspd',
    callsign: '12-40',
    status: 'available',
    statusSince: minutesAgo(11).at,
    statusSinceUnix: minutesAgo(11).unix,
    beatId: 1,
    division: 'patrol',
    vehiclePlate: 'LSPD0412',
    vehicleModel: 'police3',
    x: 215.7,
    y: -810.2,
    z: 30.7,
    heading: 120,
    positionAtUnix: minutesAgo(0.2).unix,
    onCallId: null,
    onCallLead: null,
    onCallNumber: null,
    onCallPriority: null,
    onCallStatus: null,
  },
  {
    officerId: 2,
    agencyId: 'lspd',
    callsign: '3A-12',
    status: 'on_scene',
    statusSince: minutesAgo(18).at,
    statusSinceUnix: minutesAgo(18).unix,
    beatId: 1,
    division: 'patrol',
    vehiclePlate: 'LSPD0388',
    vehicleModel: 'police3',
    x: 131.2,
    y: -1036.4,
    z: 29.3,
    heading: 250,
    positionAtUnix: minutesAgo(0.3).unix,
    onCallId: 2,
    onCallLead: 1,
    onCallNumber: callNumberFor(42),
    onCallPriority: 2,
    onCallStatus: 'on_scene',
  },
  {
    officerId: 3,
    agencyId: 'lspd',
    callsign: '2L-30',
    status: 'busy',
    statusSince: minutesAgo(6).at,
    statusSinceUnix: minutesAgo(6).unix,
    beatId: 2,
    division: 'traffic',
    vehiclePlate: 'LSPD0501',
    vehicleModel: 'police2',
    x: 402.8,
    y: -996.1,
    z: 29.4,
    heading: 10,
    positionAtUnix: minutesAgo(1).unix,
    onCallId: null,
    onCallLead: null,
    onCallNumber: null,
    onCallPriority: null,
    onCallStatus: null,
  },
  {
    officerId: 4,
    agencyId: 'lspd',
    callsign: '5X-11',
    status: 'out_of_service',
    statusSince: minutesAgo(74).at,
    statusSinceUnix: minutesAgo(74).unix,
    beatId: null,
    division: 'k9',
    vehiclePlate: null,
    vehicleModel: null,
    x: 461.3,
    y: -986.2,
    z: 24.9,
    heading: 90,
    positionAtUnix: minutesAgo(12).unix,
    onCallId: null,
    onCallLead: null,
    onCallNumber: null,
    onCallPriority: null,
    onCallStatus: null,
  },
];

/**
 * Two districts. `polygon` is `[[x, y], …]` and the bounding box beside it is
 * computed on the server from that polygon and never sent in — the fixture
 * carries both because the row does.
 */
const cadBeats = [
  {
    id: 1,
    code: 'A1',
    labelKey: 'beat.downtown',
    kind: 'beat',
    polygon: [
      [60, -1120],
      [330, -1120],
      [330, -760],
      [60, -760],
    ] as [number, number][],
    minX: 60,
    minY: -1120,
    maxX: 330,
    maxY: -760,
  },
  {
    id: 2,
    code: 'B2',
    labelKey: 'beat.east',
    kind: 'district',
    polygon: [
      [330, -1120],
      [620, -1120],
      [620, -760],
      [330, -760],
    ] as [number, number][],
    minX: 330,
    minY: -1120,
    maxX: 620,
    maxY: -760,
  },
];

let cadBroadcasts: CadBroadcast[] = [
  {
    id: 1,
    kind: 'bolo',
    priority: 2,
    title: 'Silver saloon, no plates, Vespucci',
    body: 'Two occupants, both in dark clothing. Seen leaving the shots-fired call eastbound. Do not approach alone.',
    plate: null,
    callId: 1,
    expiresAt: inMinutes(180),
    cancelledAt: null,
    createdAt: minutesAgo(3).at,
  },
  {
    id: 2,
    kind: 'information',
    priority: 4,
    title: 'Power Street closed between Alta and Sinner',
    body: 'Road closed for the collision on Alta. Use Sinner Street until further notice.',
    plate: null,
    callId: 2,
    expiresAt: inMinutes(60),
    cancelledAt: null,
    createdAt: minutesAgo(15).at,
  },
];

/** Who is live on a call right now. */
function liveOn(callId: number): CadAssignment[] {
  return cadAssignments.filter(
    (assignment) => assignment.callId === callId && assignment.active === 1,
  );
}

function findCall(id: number): CadCall | undefined {
  return cadCalls.find((call) => call.id === id);
}

/** The refusal `openCall` gives for a call that has already been closed. */
function closedRefusal(call: CadCall | undefined, field: string): FixtureRefusal | null {
  if (!call) return refuse('not_found');
  if (call.status === 'cleared') return refuse('conflict', { [field]: 'call_cleared' });
  if (call.status === 'cancelled') return refuse('conflict', { [field]: 'call_cancelled' });

  return null;
}

function addLog(
  callId: number,
  entry: Omit<CadLogEntry, 'id' | 'callId' | 'createdAt' | 'createdAtUnix'>,
): CadLogEntry {
  const now = minutesAgo(0);
  const line: CadLogEntry = { id: nextLogId++, callId, ...entry, createdAt: now.at, createdAtUnix: now.unix };

  cadLog = [...cadLog, line];

  return line;
}

/** Keeps the joined columns of the board in step with the assignments. */
function refreshUnitAssignments(): void {
  cadUnits = cadUnits.map((unit) => {
    const assignment = cadAssignments.find(
      (row) => row.officerId === unit.officerId && row.active === 1,
    );
    const call = assignment ? findCall(assignment.callId) : undefined;

    return {
      ...unit,
      onCallId: call ? call.id : null,
      onCallLead: assignment?.isLead ?? null,
      onCallNumber: call ? call.callNumber : null,
      onCallPriority: call ? call.priority : null,
      onCallStatus: call ? call.status : null,
    };
  });
}

/**
 * The closest units that could be sent (`Cad.recommendUnits`).
 *
 * Free units first, then the ones on a lower-priority call that this one
 * outranks, nearest first — and never more than the configured three.
 */
function recommendFor(call: CadCall): unknown[] {
  if (call.x === null || call.y === null) return [];

  const x = call.x;
  const y = call.y;

  return cadUnits
    .filter((unit) => unit.x !== null && unit.y !== null)
    .filter((unit) => {
      const free =
        unit.onCallId === null && ['available', 'at_station'].includes(unit.status);
      const divertible =
        unit.onCallId !== null &&
        unit.onCallPriority !== null &&
        call.priority < unit.onCallPriority;

      return free || divertible;
    })
    .map((unit) => ({
      officerId: unit.officerId,
      callsign: unit.callsign,
      status: unit.status,
      distance: Math.hypot((unit.x ?? 0) - x, (unit.y ?? 0) - y),
      stale: (unit.positionAtUnix ?? 0) < Math.floor(Date.now() / 1000) - 60,
      divertFromCallId: unit.onCallId,
    }))
    .sort((left, right) => left.distance - right.distance)
    .slice(0, 3);
}

// ---------------------------------------------------------------- registers

/**
 * The master name index and the vehicle register, as `person.search` and
 * `vehicle.search` answer them (7.2–7.4).
 *
 * These were missing, and the gap is what let the call card ship with a link
 * picker nobody could work. The mock answers an unmocked route with
 * `not_found`, so in the browser every Search on the picker failed — the same
 * dead end the seed produced in game by granting `cad.call.link` to a group
 * without `rms.person.view`, and neither was noticed because the one place the
 * interface is meant to be walkable end to end could not reach the screen
 * either. web/CLAUDE.md states the rule these rows satisfy: a fixture for every
 * route the NUI calls.
 *
 * `terms` is what the server matched on *before* access control ran, and it
 * sits beside the row instead of being read off it. A stub carries no name, no
 * number and no id — `Access.stub` builds it from nothing (4.5) — so a fixture
 * that filtered on the row's own columns could never return one, and the
 * withheld line on the picker would be unreachable in the browser and in the
 * Playwright suite alike. That line is the honest answer to "the name I can see
 * in front of me is not in this list", so it has to be walkable.
 */
interface RegisterRow<T extends { id: number }> {
  /** Lower-case fragments the row matches, as the server's LIKE would. */
  terms: string[];
  row: Maybe<T>;
  /**
   * A row this reader *is* cleared for, held back until the query carries a
   * reason or a case number (7.2). A different thing from the stub above and
   * told apart the same way the server tells them apart: a stub is returned
   * and says so, while this is simply absent and sets `restrictedWithheld`,
   * which the register screen draws as an offer to search again with a reason.
   */
  breakGlass?: boolean;
}

/** The columns every register row carries, stamped once so the rows read short. */
const RECORD_KEEPING = {
  agencyId: 'lspd',
  version: 1,
  createdBy: 'OFF-1042',
  createdAt: '2026-02-11T09:14:00.000Z',
  updatedBy: 'OFF-1042',
  updatedAt: '2026-08-03T16:40:00.000Z',
};

const registerPersons: RegisterRow<PersonResult>[] = [
  {
    // The person the collision call is already linked to, with the id that
    // link carries. Linking from the picker therefore lands on the row the
    // card already shows, which is what a second link to the same record does
    // on the server: `Repo.setLink` upserts and changes the role.
    terms: ['doe', 'john', 'p-000431', '555-0134'],
    row: {
      ...RECORD_KEEPING,
      id: 1,
      personNumber: 'P-000431',
      firstName: 'John',
      middleName: 'A.',
      lastName: 'Doe',
      dateOfBirth: '1989-04-12',
      sex: 'm',
      phone: '555-0134',
      address: 'Alta Street 12, Apartment 3',
      deceasedAt: null,
      missingSince: null,
      classification: 'internal',
      recordType: 'person',
      matchScore: 3,
      matchedAlias: null,
      cautions: [],
    },
  },
  {
    terms: ['doe', 'ellen', 'p-000512'],
    row: {
      ...RECORD_KEEPING,
      id: 2,
      personNumber: 'P-000512',
      firstName: 'Ellen',
      middleName: null,
      lastName: 'Doe',
      dateOfBirth: '1994-11-30',
      sex: 'f',
      phone: null,
      address: null,
      deceasedAt: null,
      missingSince: null,
      classification: 'internal',
      recordType: 'person',
      matchScore: 2,
      // A caution reaches a search result as its kind and expiry and never as
      // its detail: what a person is flagged for is on the record, not in a
      // list somebody glanced at.
      cautions: [{ kind: 'violent', expiresAt: null }],
      matchedAlias: null,
    },
  },
  {
    // The third Doe, and the reason the picker has a withheld line at all: a
    // dispatcher who knows this person exists gets told the search reached
    // something and not what. No id, so nothing to link.
    terms: ['doe', 'p-000633'],
    row: { restricted: true, recordType: 'person', contact: 'homicide' },
  },
  {
    terms: ['petrov', 'marko', 'p-000588'],
    row: {
      ...RECORD_KEEPING,
      id: 3,
      personNumber: 'P-000588',
      firstName: 'Marko',
      middleName: null,
      lastName: 'Petrov',
      dateOfBirth: '1982-06-02',
      sex: 'm',
      phone: '555-0177',
      address: null,
      deceasedAt: null,
      missingSince: null,
      classification: 'internal',
      recordType: 'person',
      matchScore: 3,
      matchedAlias: null,
      cautions: [],
    },
  },
  {
    // Cleared for, and still not handed over without a reason (7.2).
    breakGlass: true,
    terms: ['lind', 'sofia', 'p-000701'],
    row: {
      ...RECORD_KEEPING,
      id: 4,
      personNumber: 'P-000701',
      firstName: 'Sofia',
      middleName: null,
      lastName: 'Lind',
      dateOfBirth: '1976-01-19',
      sex: 'f',
      phone: null,
      address: null,
      deceasedAt: null,
      missingSince: null,
      classification: 'restricted',
      recordType: 'person',
      matchScore: 2,
      matchedAlias: null,
      cautions: [],
    },
  },
];

const registerVehicles: RegisterRow<VehicleResult>[] = [
  {
    terms: ['45abc123', 'sultan'],
    row: {
      ...RECORD_KEEPING,
      id: 1,
      plate: '45ABC123',
      vin: 'WBA3A5C51DF123456',
      model: 'Sultan',
      colour: 'black',
      colourSecondary: null,
      ownerPersonId: 1,
      ownerIdentifier: null,
      registrationStatus: 'valid',
      registrationExpires: '2027-03-31',
      insuranceStatus: 'valid',
      insuranceExpires: '2027-01-31',
      classification: 'internal',
      recordType: 'vehicle',
      hits: [],
      flags: [],
    },
  },
  {
    terms: ['45xyz777', 'sandking'],
    row: {
      ...RECORD_KEEPING,
      id: 2,
      plate: '45XYZ777',
      vin: 'JH4KA8260MC001827',
      model: 'Sandking',
      colour: 'white',
      colourSecondary: null,
      ownerPersonId: null,
      ownerIdentifier: null,
      registrationStatus: 'expired',
      registrationExpires: '2025-09-30',
      insuranceStatus: 'none',
      insuranceExpires: null,
      classification: 'internal',
      recordType: 'vehicle',
      // The hot file, computed by the server off the live flags. The count in
      // the answer is how many rows carry one, which is what puts the banner
      // over the register's result list.
      hits: ['stolen'],
      flags: [
        {
          id: 1,
          agencyId: 'lspd',
          vehicleId: 2,
          kind: 'stolen',
          detail: 'Taken from the Alta Street multi-storey overnight.',
          caseNumber: 'LSPD-C26-00045',
          classification: 'internal',
          expiresAt: null,
          createdBy: 'OFF-1042',
          createdAt: '2026-09-02T04:20:00.000Z',
        },
      ],
    },
  },
  {
    terms: ['45', '45qqr410'],
    row: { restricted: true, recordType: 'vehicle', contact: 'narcotics' },
  },
];

/**
 * How the two search routes match.
 *
 * Both normalize before comparing — `Repo.parseTerm` lower-cases and collapses
 * whitespace, `Registry.searchTerm` upper-cases and strips it — so the fixture
 * does the same once here rather than twice, differently, below.
 */
function matches<T extends { id: number }>(rows: RegisterRow<T>[], term: string): RegisterRow<T>[] {
  const needle = term.trim().toLowerCase().replace(/\s+/g, ' ');
  if (needle === '') return [];

  return rows.filter((entry) => entry.terms.some((candidate) => candidate.includes(needle)));
}

/**
 * The label `Repo.linkTarget` selects, or null for a target that cannot be
 * linked: `TRIM(CONCAT(first_name, ' ', last_name))` for a person and the plate
 * for a vehicle, so the row the card lists afterwards is the one the server
 * would have written.
 *
 * A stub never answers here, and that is the server's behaviour rather than a
 * shortcut: `call.link` runs the same access check the register runs, and a
 * record the session may not read is refused with `not_found` — the same code
 * as one that is not there, because telling the two apart is the disclosure
 * (4.5).
 */
function linkLabel(kind: string, targetId: number): string | null {
  if (kind === 'person') {
    for (const entry of registerPersons) {
      const row = entry.row;
      if (!isStub(row) && row.id === targetId) {
        return [row.firstName, row.lastName].filter(Boolean).join(' ');
      }
    }

    return null;
  }

  if (kind === 'vehicle') {
    for (const entry of registerVehicles) {
      const row = entry.row;
      if (!isStub(row) && row.id === targetId) return row.plate;
    }
  }

  return null;
}

export const fixtures: FixtureSet = {
  ok: {
    'session.get': () => session,

    // ------------------------------------------------------------- dispatch

    'call.list': (input) => {
      const filter = (input ?? {}) as {
        status?: string;
        priority?: number;
        beatId?: number;
        mine?: boolean;
      };

      const calls = cadCalls
        .filter((call) =>
          filter.status
            ? call.status === filter.status
            : call.status !== 'cleared' && call.status !== 'cancelled',
        )
        .filter((call) => (filter.priority ? call.priority === filter.priority : true))
        .filter((call) => (filter.beatId ? call.beatId === filter.beatId : true))
        .filter((call) =>
          filter.mine
            ? liveOn(call.id).some((unit) => unit.officerId === OWN_OFFICER_ID)
            : true,
        )
        .map((call) => ({ ...call, unitCount: liveOn(call.id).length }))
        .sort(
          (left, right) =>
            left.priority - right.priority || left.receivedAtUnix - right.receivedAtUnix,
        );

      return { calls };
    },

    'call.get': (input) => {
      const { id } = input as { id: number };
      const call = findCall(id);

      if (!call) return refuse('not_found');

      return {
        id,
        call,
        units: cadAssignments.filter((assignment) => assignment.callId === id),
        log: cadLog.filter((entry) => entry.callId === id),
        links: cadLinks.filter((link) => link.callId === id),
        // Present for a session that may dispatch, and only for a call with
        // coordinates to measure from — the welfare check above has none, so
        // opening it draws no recommendation panel at all.
        ...(call.x === null ? {} : { recommended: recommendFor(call) }),
      };
    },

    'call.create': (input) => {
      const body = input as {
        placementId?: number;
        type: string;
        priority: number;
        locationText: string;
        beatId?: number;
        callerName?: string;
        callerPhone?: string;
        details?: string;
      };

      // Pinned to the console (3.10): the id is a claim the server checks
      // against where the dispatcher is actually standing.
      if (!body.placementId) return refuse('context');

      const now = minutesAgo(0);
      const call: CadCall = {
        id: nextCallId++,
        agencyId: 'lspd',
        callNumber: callNumberFor(++callSequence),
        type: body.type,
        priority: body.priority,
        status: 'pending',
        x: null,
        y: null,
        z: null,
        locationText: body.locationText,
        beatId: body.beatId ?? null,
        callerName: body.callerName ?? null,
        callerPhone: body.callerPhone ?? null,
        source: 'dispatcher',
        sourceResource: null,
        receivedAt: now.at,
        receivedAtUnix: now.unix,
        dispatchedAt: null,
        enRouteAt: null,
        onSceneAt: null,
        clearedAt: null,
        disposition: null,
        acknowledgedBy: null,
        acknowledgedAt: null,
      };

      cadCalls = [...cadCalls, call];

      addLog(call.id, {
        entryType: 'created',
        // What the caller said opens the narrative: it is content, so it goes
        // in `body` beside the generated line's own key.
        body: body.details ?? null,
        messageKey: 'cad.log.created',
        messageArgs: null,
        callsign: null,
      });

      return { id: call.id, call };
    },

    'call.dispatch': (input) => {
      const body = input as {
        placementId?: number;
        callId: number;
        officerIds?: string[];
        removeOfficerIds?: string[];
        leadOfficerId?: string;
      };

      if (!body.placementId) return refuse('context');

      const call = findCall(body.callId);
      const closed = closedRefusal(call, 'callId');
      if (closed || !call) return closed ?? refuse('not_found');

      const join = (body.officerIds ?? []).map(Number);
      const leave = (body.removeOfficerIds ?? []).map(Number);

      if (join.length === 0 && leave.length === 0 && !body.leadOfficerId) {
        return refuse('invalid', { officerIds: 'nothing_to_change' });
      }

      for (const officerId of join) {
        const unit = cadUnits.find((row) => row.officerId === officerId);
        if (!unit) return refuse('invalid', { officerIds: 'unknown' });

        // A unit that is off duty or off the road cannot be sent, and the two
        // are told apart because the fix differs.
        if (unit.status === 'off_duty') return refuse('conflict', { officerIds: 'off_duty' });
        if (unit.status === 'out_of_service') {
          return refuse('conflict', { officerIds: 'unavailable' });
        }

        if (liveOn(call.id).some((assignment) => assignment.officerId === officerId)) {
          return refuse('conflict', { officerIds: 'already_assigned' });
        }

        cadAssignments = [
          ...cadAssignments,
          {
            id: nextAssignmentId++,
            callId: call.id,
            officerId,
            callsign: unit.callsign,
            isLead: null,
            joinedAt: minutesAgo(0).at,
            leftAt: null,
            active: 1,
          },
        ];

        addLog(call.id, {
          entryType: 'dispatched',
          body: null,
          messageKey: 'cad.log.dispatched',
          messageArgs: { callsign: unit.callsign },
          callsign: session.callsign,
        });
      }

      for (const officerId of leave) {
        const assignment = liveOn(call.id).find((row) => row.officerId === officerId);
        if (!assignment) return refuse('conflict', { removeOfficerIds: 'not_assigned' });

        cadAssignments = cadAssignments.map((row) =>
          row.id === assignment.id
            ? { ...row, active: null, isLead: null, leftAt: minutesAgo(0).at }
            : row,
        );

        addLog(call.id, {
          entryType: 'unit_left',
          body: null,
          messageKey: 'cad.log.unit_left',
          messageArgs: { callsign: assignment.callsign },
          callsign: session.callsign,
        });
      }

      if (body.leadOfficerId) {
        const lead = Number(body.leadOfficerId);
        const assignment = liveOn(call.id).find((row) => row.officerId === lead);

        // The lead has to be on the call after the dispatch is applied, which
        // is a rule no schema can state.
        if (!assignment) return refuse('conflict', { leadOfficerId: 'not_assigned' });

        cadAssignments = cadAssignments.map((row) =>
          row.callId === call.id && row.active === 1
            ? { ...row, isLead: row.officerId === lead ? 1 : null }
            : row,
        );

        addLog(call.id, {
          entryType: 'lead_changed',
          body: null,
          messageKey: 'cad.log.lead_changed',
          messageArgs: { callsign: assignment.callsign },
          callsign: session.callsign,
        });
      }

      // The first unit on the call stamps `dispatched_at`, and the stamp never
      // moves again: a response-time report is arithmetic on it.
      if (call.status === 'pending' && liveOn(call.id).length > 0) {
        cadCalls = cadCalls.map((row) =>
          row.id === call.id
            ? { ...row, status: 'dispatched', dispatchedAt: row.dispatchedAt ?? minutesAgo(0).at }
            : row,
        );

        addLog(call.id, {
          entryType: 'call_status',
          body: null,
          messageKey: 'cad.log.call_status',
          messageArgs: { status: 'dispatched' },
          callsign: session.callsign,
        });
      }

      refreshUnitAssignments();

      return { id: call.id, joined: join.length, left: leave.length };
    },

    'call.self_assign': (input) => {
      const { callId } = input as { callId: number };
      const call = findCall(callId);
      const closed = closedRefusal(call, 'callId');
      if (closed || !call) return closed ?? refuse('not_found');

      if (liveOn(callId).some((row) => row.officerId === OWN_OFFICER_ID)) {
        return refuse('conflict', { callId: 'already_assigned' });
      }

      const own = cadUnits.find((unit) => unit.officerId === OWN_OFFICER_ID);
      if (!own) return refuse('conflict', { callId: 'no_unit' });
      if (own.status === 'off_duty') return refuse('conflict', { callId: 'off_duty' });

      cadAssignments = [
        ...cadAssignments,
        {
          id: nextAssignmentId++,
          callId,
          officerId: OWN_OFFICER_ID,
          callsign: own.callsign,
          isLead: liveOn(callId).length === 0 ? 1 : null,
          joinedAt: minutesAgo(0).at,
          leftAt: null,
          active: 1,
        },
      ];

      // A unit that took the call and one that was sent to it are different
      // facts, and the log is read back to tell them apart.
      addLog(callId, {
        entryType: 'unit_joined',
        body: null,
        messageKey: 'cad.log.self_assigned',
        messageArgs: { callsign: own.callsign },
        callsign: own.callsign,
      });

      if (call.status === 'pending') {
        cadCalls = cadCalls.map((row) =>
          row.id === callId
            ? { ...row, status: 'dispatched', dispatchedAt: row.dispatchedAt ?? minutesAgo(0).at }
            : row,
        );
      }

      refreshUnitAssignments();

      return { id: callId, callNumber: call.callNumber };
    },

    'call.status': (input) => {
      const { callId, status } = input as { callId: number; status: string };
      const call = findCall(callId);
      const closed = closedRefusal(call, 'callId');
      if (closed || !call) return closed ?? refuse('not_found');

      const own = cadUnits.find((unit) => unit.officerId === OWN_OFFICER_ID);
      if (!own) return refuse('conflict', { status: 'no_unit' });

      // Progress is reported by the unit that is on the call; moving somebody
      // else is `unit.manage`, a different key held by different people.
      if (!liveOn(callId).some((row) => row.officerId === OWN_OFFICER_ID)) {
        return refuse('conflict', { callId: 'not_assigned' });
      }

      const now = minutesAgo(0);

      cadUnits = cadUnits.map((unit) =>
        unit.officerId === OWN_OFFICER_ID
          ? { ...unit, status, statusSince: now.at, statusSinceUnix: now.unix }
          : unit,
      );

      // The call's stamps are the first unit to get there, not the latest.
      cadCalls = cadCalls.map((row) =>
        row.id === callId
          ? {
              ...row,
              status,
              enRouteAt: status === 'en_route' ? (row.enRouteAt ?? now.at) : row.enRouteAt,
              onSceneAt: status === 'on_scene' ? (row.onSceneAt ?? now.at) : row.onSceneAt,
            }
          : row,
      );

      addLog(callId, {
        entryType: 'unit_status',
        body: null,
        messageKey: 'cad.log.unit_status',
        messageArgs: { callsign: own.callsign, status },
        callsign: own.callsign,
      });

      refreshUnitAssignments();

      return { id: callId, status };
    },

    'call.clear': (input) => {
      const body = input as { callId: number; disposition: string; note?: string };
      const call = findCall(body.callId);
      const closed = closedRefusal(call, 'callId');
      if (closed || !call) return closed ?? refuse('not_found');

      // 7.16: an emergency call cannot be cleared until a supervisor has
      // acknowledged it, and cancelling is refused on the same terms or it
      // would be the way around the rule.
      if (call.source === 'panic' && call.acknowledgedAt === null) {
        return refuse('conflict', { callId: 'needs_acknowledgement' });
      }

      const status =
        body.disposition === 'duplicate' || body.disposition === 'cancelled'
          ? 'cancelled'
          : 'cleared';

      cadCalls = cadCalls.map((row) =>
        row.id === body.callId
          ? { ...row, status, disposition: body.disposition, clearedAt: minutesAgo(0).at }
          : row,
      );

      cadAssignments = cadAssignments.map((row) =>
        row.callId === body.callId && row.active === 1
          ? { ...row, active: null, leftAt: minutesAgo(0).at }
          : row,
      );

      if (body.note) {
        addLog(body.callId, {
          entryType: 'note',
          body: body.note,
          messageKey: null,
          messageArgs: null,
          callsign: session.callsign,
        });
      }

      addLog(body.callId, {
        entryType: 'cleared',
        body: null,
        messageKey: status === 'cancelled' ? 'cad.log.cancelled' : 'cad.log.cleared',
        messageArgs: { disposition: body.disposition },
        callsign: session.callsign,
      });

      refreshUnitAssignments();

      return { id: body.callId, disposition: body.disposition, status };
    },

    'call.acknowledge': (input) => {
      const { callId } = input as { callId: number };
      const call = findCall(callId);

      if (!call) return refuse('not_found');

      // Only an emergency has anything to acknowledge.
      if (call.source !== 'panic') return refuse('invalid', { callId: 'not_supported' });
      if (call.acknowledgedAt !== null) {
        return refuse('conflict', { callId: 'nothing_to_change' });
      }

      cadCalls = cadCalls.map((row) =>
        row.id === callId
          ? { ...row, acknowledgedAt: minutesAgo(0).at, acknowledgedBy: session.callsign }
          : row,
      );

      addLog(callId, {
        entryType: 'unit_status',
        body: null,
        messageKey: 'cad.log.acknowledged',
        messageArgs: { callsign: session.callsign },
        callsign: session.callsign,
      });

      return { id: callId };
    },

    'call.note': (input) => {
      const { callId, body } = input as { callId: number; body: string };
      const call = findCall(callId);
      const closed = closedRefusal(call, 'callId');
      if (closed || !call) return closed ?? refuse('not_found');

      // The kind is not a field: this route writes a note, and the server
      // writes every other kind from what it has just done (invariant 11).
      addLog(callId, {
        entryType: 'note',
        body,
        messageKey: null,
        messageArgs: null,
        callsign: session.callsign,
      });

      return { id: callId };
    },

    'call.link': (input) => {
      const { callId, kind, targetId, role, remove } = input as {
        callId: number;
        kind: string;
        targetId: number;
        role?: string;
        remove?: boolean;
      };

      const call = findCall(callId);
      const closed = closedRefusal(call, 'callId');
      if (closed || !call) return closed ?? refuse('not_found');

      const label = linkLabel(kind, targetId);
      if (label === null) return refuse('not_found', { targetId: 'unknown' });

      const existing = cadLinks.find(
        (link) =>
          link.callId === callId && link.targetType === kind && link.targetId === targetId,
      );

      if (remove) {
        // Checked before anything is written, because the log is append-only:
        // an `unlinked` line about a link that was never there stays for good.
        if (!existing) return refuse('not_found', { targetId: 'unknown' });

        cadLinks = cadLinks.filter((link) => link !== existing);
        addLog(callId, {
          entryType: 'unlinked',
          body: null,
          messageKey: 'cad.log.unlinked',
          messageArgs: { label: existing.label },
          callsign: session.callsign,
        });

        return { id: callId };
      }

      const chosen = role ?? 'involved';

      // The upsert on `uq_fpd_call_links_target`: linking the same record twice
      // changes the role rather than stacking a second row nobody would think
      // to remove, and the narrative gets a line saying who decided the witness
      // was a suspect (7.16.1).
      cadLinks = existing
        ? cadLinks.map((link) => (link === existing ? { ...link, role: chosen } : link))
        : [
            ...cadLinks,
            {
              id: nextLinkId++,
              callId,
              targetType: kind,
              targetId,
              role: chosen,
              label,
              detail: null,
              createdAt: minutesAgo(0).at,
            },
          ];

      addLog(callId, {
        entryType: 'linked',
        body: null,
        messageKey: 'cad.log.linked',
        // `role` names a vocabulary and carries the enum member; `label` is
        // data and is printed as the server recorded it (7.16.1).
        messageArgs: { label, role: chosen },
        callsign: session.callsign,
      });

      return { id: callId };
    },

    // -------------------------------------------------------- the registers

    'person.search': (input) => {
      const { term, reason, caseNumber } = (input ?? {}) as {
        term?: string;
        reason?: string;
        caseNumber?: string;
      };

      // `Repo.parseTerm` refuses a term under two characters before it reaches
      // the database, and the card reads the field code out rather than leaving
      // a button that does nothing.
      if ((term ?? '').trim().length < 2) return refuse('invalid', { term: 'too_short' });

      const authorized = Boolean(reason?.trim() || caseNumber?.trim());
      const found = matches(registerPersons, term ?? '');

      return {
        persons: found.filter((entry) => authorized || !entry.breakGlass).map((entry) => entry.row),
        // Only ever about rows this reader is cleared for. A stub above is not
        // counted here: for the reader it is an answer, not something withheld.
        restrictedWithheld: !authorized && found.some((entry) => entry.breakGlass === true),
      };
    },

    'vehicle.search': (input) => {
      const { term, reason, caseNumber } = (input ?? {}) as {
        term?: string;
        reason?: string;
        caseNumber?: string;
      };

      const authorized = Boolean(reason?.trim() || caseNumber?.trim());
      // `Registry.searchTerm` answers nil for anything under two characters and
      // the handler then searches without one, so a short term is a wide search
      // here rather than a refusal — the opposite of `person.search` above, and
      // the difference is the server's, not this file's.
      const found =
        (term ?? '').trim().length < 2
          ? registerVehicles
          : matches(registerVehicles, term ?? '');

      const vehicles = found
        .filter((entry) => authorized || !entry.breakGlass)
        .map((entry) => entry.row);

      return {
        vehicles,
        // How many rows carry a hot-file hit. The server counts; the screen
        // draws what it is told.
        hits: vehicles.filter((row) => !isStub(row) && row.hits.length > 0).length,
      };
    },

    'unit.list': () => ({ units: cadUnits.filter((unit) => unit.status !== 'off_duty') }),

    'unit.status': (input) => {
      const { status } = input as { status: string };
      const own = cadUnits.find((unit) => unit.officerId === OWN_OFFICER_ID);

      if (!own) return refuse('conflict', { status: 'no_unit' });
      // The same status again is not a change, and `status_since` must not be
      // restamped for it or the welfare timer resets on every press.
      if (own.status === status) return refuse('conflict', { status: 'nothing_to_change' });

      const now = minutesAgo(0);

      cadUnits = cadUnits.map((unit) =>
        unit.officerId === OWN_OFFICER_ID
          ? { ...unit, status, statusSince: now.at, statusSinceUnix: now.unix }
          : unit,
      );

      return { id: OWN_OFFICER_ID, status };
    },

    'unit.manage': (input) => {
      const body = input as {
        officerId: number;
        status?: string;
        callsign?: string;
        beatId?: number;
        reason?: string;
      };

      const unit = cadUnits.find((row) => row.officerId === body.officerId);
      if (!unit) return refuse('not_found', { officerId: 'unknown' });

      if (!body.status && !body.callsign && !body.beatId) {
        return refuse('invalid', { status: 'nothing_to_change' });
      }

      // The two changes that read as discipline afterwards need a reason, and
      // a schema cannot say "required unless".
      if ((body.status === 'out_of_service' || body.status === 'off_duty') && !body.reason) {
        return refuse('invalid', { reason: 'required' });
      }

      const now = minutesAgo(0);

      cadUnits = cadUnits.map((row) =>
        row.officerId === body.officerId
          ? {
              ...row,
              callsign: body.callsign ?? row.callsign,
              beatId: body.beatId ?? row.beatId,
              status: body.status ?? row.status,
              statusSince: body.status ? now.at : row.statusSince,
              statusSinceUnix: body.status ? now.unix : row.statusSinceUnix,
            }
          : row,
      );

      return { id: body.officerId };
    },

    /**
     * The emergency button (7.16). It takes nothing at all: the position, the
     * type, the priority and the officer are all the server's.
     */
    'unit.emergency': () => {
      const own = cadUnits.find((unit) => unit.officerId === OWN_OFFICER_ID);
      if (!own) return refuse('conflict', { status: 'no_unit' });
      if (own.status === 'off_duty') return refuse('conflict', { status: 'off_duty' });

      const now = minutesAgo(0);
      const call: CadCall = {
        id: nextCallId++,
        agencyId: 'lspd',
        callNumber: callNumberFor(++callSequence),
        type: 'officer_emergency',
        priority: 1,
        status: 'dispatched',
        x: own.x,
        y: own.y,
        z: own.z,
        locationText: null,
        beatId: own.beatId,
        callerName: null,
        callerPhone: null,
        source: 'panic',
        sourceResource: null,
        receivedAt: now.at,
        receivedAtUnix: now.unix,
        dispatchedAt: now.at,
        enRouteAt: null,
        onSceneAt: null,
        clearedAt: null,
        disposition: null,
        acknowledgedBy: null,
        acknowledgedAt: null,
      };

      cadCalls = [...cadCalls, call];
      cadAssignments = [
        ...cadAssignments,
        {
          id: nextAssignmentId++,
          callId: call.id,
          officerId: OWN_OFFICER_ID,
          callsign: own.callsign,
          isLead: 1,
          joinedAt: now.at,
          leftAt: null,
          active: 1,
        },
      ];

      cadUnits = cadUnits.map((unit) =>
        unit.officerId === OWN_OFFICER_ID
          ? { ...unit, status: 'emergency', statusSince: now.at, statusSinceUnix: now.unix }
          : unit,
      );

      addLog(call.id, {
        entryType: 'created',
        body: null,
        messageKey: 'cad.log.created',
        messageArgs: null,
        callsign: own.callsign,
      });

      refreshUnitAssignments();

      // The tone, as `unit.emergency` sends it (7.16): to dispatchers and
      // supervisors wherever they are, and to the units inside 800 m.
      //
      // `mayAcknowledge` is false here and could never be anything else. The
      // server computes it per recipient and refuses two people: anybody
      // without `cad.unit.manage`, and the officer named in `created_by` — and
      // in a browser the session pressing the button *is* that officer, so a
      // fixture that sent true would be modelling a state the route cannot
      // produce. The banner therefore arrives with Respond and no Acknowledge,
      // which is exactly what the officer who pressed panic should see.
      //
      // For the other half — a colleague's emergency, which a supervisor may
      // sign off — post one from the devtools console with the same shape and
      // `mayAcknowledge: true`; `tests/dispatch.spec.ts` covers both.
      push({
        type: 'fredpd:cad:emergency',
        call,
        callsign: own.callsign,
        mayAcknowledge: false,
      });

      return { id: call.id, call };
    },

    'broadcast.list': (input) => {
      const filter = (input ?? {}) as { includeExpired?: boolean; kind?: string };

      return {
        broadcasts: cadBroadcasts
          .filter((entry) => (filter.includeExpired ? true : entry.cancelledAt === null))
          .filter((entry) => (filter.kind ? entry.kind === filter.kind : true))
          .sort((left, right) => left.priority - right.priority),
      };
    },

    'broadcast.create': (input) => {
      const body = input as {
        kind: string;
        priority?: number;
        title: string;
        body: string;
        plate?: string;
        expiresInMinutes?: number;
      };

      const broadcast: CadBroadcast = {
        id: nextBroadcastId++,
        kind: body.kind,
        priority: body.priority ?? 3,
        title: body.title,
        body: body.body,
        // Upper-cased and trimmed, like every other plate column in the suite.
        plate: body.plate ? body.plate.trim().toUpperCase() : null,
        callId: null,
        // Minutes on the server's clock, never a date from the client. Absent
        // takes the agency's configured default rather than "no expiry".
        expiresAt: inMinutes(body.expiresInMinutes ?? 240),
        cancelledAt: null,
        createdAt: minutesAgo(0).at,
      };

      cadBroadcasts = [broadcast, ...cadBroadcasts];

      return { id: broadcast.id, broadcast };
    },

    'broadcast.cancel': (input) => {
      const { id } = input as { id: number };
      const entry = cadBroadcasts.find((row) => row.id === id);

      if (!entry || entry.cancelledAt !== null) return refuse('not_found');

      // Nothing is deleted: the row is stamped and stays, so what was out on
      // the air at the time survives the shift it was asked about.
      cadBroadcasts = cadBroadcasts.map((row) =>
        row.id === id ? { ...row, cancelledAt: minutesAgo(0).at } : row,
      );

      return { id };
    },

    'beat.list': () => ({ beats: cadBeats }),

    'map.view': (input) => {
      const { subscribe } = (input ?? {}) as { subscribe?: boolean };

      // The close half is a field rather than a second route, so there is one
      // place the subscription is written.
      if (subscribe === false) return { subscribed: false };

      return {
        subscribed: true,
        units: cadUnits.filter((unit) => unit.status !== 'off_duty'),
        calls: cadCalls.filter(
          (call) => call.status !== 'cleared' && call.status !== 'cancelled',
        ),
      };
    },

    'admin.rolemap.list': () => ({
      mappings,
      groups,
      snapshotAgeSeconds: 12,
    }),

    /**
     * A server with a busy evening behind it.
     *
     * The numbers are chosen to be read rather than to be round: `destroyed`
     * sits well above `collected`, which is the picture ADR-013 says this
     * screen exists to make visible — traces are being wiped off surfaces
     * faster than technicians are securing them, and no audit row anywhere
     * records any of it, because the callers doing the wiping have no session.
     */
    'admin.health': () => ({
      version: '0.3.0',
      env: 'development',
      routes: 96,
      sessions: { open: 7, stale: 1, readOnly: 0 },
      discord: { enabled: true, snapshotAgeSeconds: 12 },
      grid: {
        items: 42,
        cells: 19,
        subscribers: 5,
        placed: 631,
        merged: 88,
        evicted: 24,
        refused: 3,
        collected: 47,
        destroyed: 112,
      },
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
      // `placementId` is the property room terminal the call is being made at.
      // The real route refuses without it, before the handler runs, and checks
      // the officer is standing there; the fixture only records that the page
      // sends it. It cannot refuse on it yet, because the mock bridge's own
      // `fredpd:open` message carries no placement for the page to read.
      const body = input as {
        placementId?: number;
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
          // A new row starts at 1, the column default. The browser session has
          // to move it the way the server does, or saving a group twice in a
          // row would answer `conflict` here and nowhere else.
          version: 1,
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
        version: number;
        name?: string;
        inherits?: string;
        description?: string;
        permissions?: string[];
      };

      // The stale-write refusal, in the browser as on the server. A fixture
      // that always accepted would make the one path this column exists for
      // the only path nobody can walk without a game server.
      const current = groupRows.find((group) => group.key === body.key);
      if (current && current.version !== body.version) {
        return refuse('conflict', { version: 'stale' });
      }

      groupRows = groupRows.map((group) =>
        group.key === body.key
          ? {
              ...group,
              version: group.version + 1,
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
        // `-1` is "no livery": `Repo.addFleet` writes it as NULLIF(?, -1), and
        // the fixture has to store the same thing the database would.
        livery: body.livery === undefined || body.livery === -1 ? null : body.livery,
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
              // An absent livery leaves it; `-1` clears it (NULLIF(?, -1)).
              livery:
                body.livery === undefined ? entry.livery : body.livery === -1 ? null : body.livery,
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

  /**
   * Routes that always refuse.
   *
   * Empty, and deliberately so. It held `records.person.search` — "proves the
   * shell renders a forbidden state rather than an empty panel" — and there has
   * never been a route by that name: the search is `person.search`, and
   * `records.person.search` is the *locale* prefix for the form's labels.
   * Keyed to nothing, it proved nothing, and it sat next to a register with no
   * fixtures at all, which is the shape a gap takes when it looks covered.
   *
   * The refusal path is walked by `?fail=forbidden`, which refuses every route
   * at once and is what `tests/shell.spec.ts` asserts on. A route pinned to a
   * refusal here would instead make that route unwalkable in the browser for
   * everybody, which is the more expensive half of the trade.
   */
  fail: {},
};
