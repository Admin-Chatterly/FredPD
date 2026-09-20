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
  // The department's clock. Every timestamp the interface draws is rendered in
  // this zone rather than in the one the player's machine is set to, so the
  // fixture sends it exactly as `session.get` does.
  timezone: 'Europe/Stockholm',
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

// Four calls are seeded below, so the first one raised in the browser is 5. A
// stale counter here would hand `unit.emergency` an id a seeded row already
// holds, and `findCall` returns the first match — so the panic would open
// somebody else's card.
let nextCallId = 5;
let nextLogId = 20;
let nextAssignmentId = 10;
let nextBroadcastId = 3;
let nextLinkId = 3;
let callSequence = 44;

const shotsFired = minutesAgo(4);
const collision = minutesAgo(26);
const welfare = minutesAgo(52);
const colleaguePanic = minutesAgo(2);

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
  {
    /**
     * Somebody else's panic, still unacknowledged.
     *
     * The console could not reach this state before, and that is why the call
     * card's Acknowledge button shipped ungated: the only emergency a browser
     * could produce was the session's own, raised through the button on the
     * unit board, and `call.acknowledge` refuses that one on `created_by`
     * whatever permission the presser holds. So the one card that has a live
     * Acknowledge on it — a colleague's panic, opened by somebody who may sign
     * it off — had never been drawn outside the game, in a module whose whole
     * failure mode is a button drawn to more people than may press it.
     *
     * `2L-30` raised it, which is what `mayAcknowledge` below reads: the unit
     * row and the lead assignment are seeded to match, because
     * `unit.emergency` writes all three (the call, the assignment, the status)
     * and a fixture that seeded one of them would be a board state the route
     * cannot produce.
     */
    id: 4,
    agencyId: 'lspd',
    callNumber: callNumberFor(44),
    type: 'officer_emergency',
    priority: 1,
    status: 'dispatched',
    x: 402.8,
    y: -996.1,
    z: 29.4,
    locationText: null,
    beatId: 2,
    callerName: null,
    callerPhone: null,
    source: 'panic',
    sourceResource: null,
    receivedAt: colleaguePanic.at,
    receivedAtUnix: colleaguePanic.unix,
    dispatchedAt: colleaguePanic.at,
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
  {
    // The officer who pressed the button, on their own call and lead on it,
    // exactly as `unit.emergency` attaches them.
    id: 2,
    callId: 4,
    officerId: 3,
    callsign: '2L-30',
    isLead: 1,
    joinedAt: colleaguePanic.at,
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
  {
    id: 7,
    callId: 4,
    entryType: 'created',
    body: null,
    messageKey: 'cad.log.created',
    messageArgs: null,
    callsign: '2L-30',
    createdAt: colleaguePanic.at,
    createdAtUnix: colleaguePanic.unix,
  },
  {
    id: 8,
    callId: 4,
    entryType: 'unit_status',
    body: null,
    messageKey: 'cad.log.unit_status',
    messageArgs: { callsign: '2L-30', status: 'emergency' },
    callsign: '2L-30',
    createdAt: colleaguePanic.at,
    createdAtUnix: colleaguePanic.unix,
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
    // In distress, on the call they raised. `Cad.CALL_ENDED` is the only rule
    // that frees `emergency`, so this row stays as it is until call 4 closes —
    // which is the state a dispatcher is looking at when they acknowledge.
    status: 'emergency',
    statusSince: colleaguePanic.at,
    statusSinceUnix: colleaguePanic.unix,
    beatId: 2,
    division: 'traffic',
    vehiclePlate: 'LSPD0501',
    vehicleModel: 'police2',
    x: 402.8,
    y: -996.1,
    z: 29.4,
    heading: 10,
    positionAtUnix: minutesAgo(1).unix,
    onCallId: 4,
    onCallLead: 1,
    onCallNumber: callNumberFor(44),
    onCallPriority: 1,
    onCallStatus: 'dispatched',
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
 * `call.get`'s answer to "may this session sign this emergency off?" (7.16).
 *
 * `Cad.canAcknowledge` makes four tests and three of them are answerable here,
 * in the same order: only a `panic` call has anything to acknowledge, a second
 * press is refused because `acknowledged_at IS NULL` is in the repo's WHERE,
 * and the officer named in `created_by` may not sign off their own distress
 * call. The fourth is the permission — `cad.unit.manage`, which neither
 * `patrol` nor `patrol_basic` holds — and fixtures are not a permission model
 * (see the header): they describe what an authorized session sees, so that one
 * is taken as satisfied.
 *
 * Who raised it is read off the lead assignment rather than a `createdBy` field
 * invented for the fixture: `unit.emergency` attaches the caller to the call it
 * creates and makes them lead in the same breath, so on a panic call the two
 * are the same officer by construction.
 */
function mayAcknowledge(call: CadCall): boolean {
  if (call.source !== 'panic' || call.acknowledgedAt !== null) return false;

  const raisedBy = cadAssignments.find((row) => row.callId === call.id && row.isLead === 1);

  return raisedBy?.officerId !== OWN_OFFICER_ID;
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

/** Whose session the fixtures answer as, for the own-report rule. */
const FIXTURE_VIEWER = '100000000000000001';

interface FixtureAnmalan {
  id: number;
  number: string;
  title: string;
  status: string;
  createdBy: string;
  version: number;
  /** The supervisor's reason, on a report that came back. */
  returnedNote?: string | null;
  brott: {
    id: number;
    code: string;
    labelKey: string;
    citation: string;
    grad: string;
    stage: string;
  }[];
  personer: { personId: number; roll: string; personNumber: string }[];
}

const anmalningar: FixtureAnmalan[] = [
  {
    id: 1,
    number: 'LSPD-26-000101',
    title: 'Stöld ur bil, Grove Street',
    status: 'utkast',
    createdBy: FIXTURE_VIEWER,
    version: 1,
    brott: [
      {
        id: 11,
        code: 'BRB-8-1',
        labelKey: 'brott.rubrik.stold',
        citation: 'BrB 8:1',
        grad: 'normal',
        stage: 'fullbordat',
      },
    ],
    personer: [{ personId: 1, roll: 'malsagande', personNumber: 'P-000431' }],
  },
  {
    id: 2,
    number: 'LSPD-26-000102',
    title: 'Misshandel utanför Vanilla Unicorn',
    status: 'inlamnad',
    // Somebody else's, so it can be approved.
    createdBy: '100000000000000002',
    version: 3,
    brott: [
      {
        id: 12,
        code: 'BRB-3-5',
        labelKey: 'brott.rubrik.misshandel',
        citation: 'BrB 3:5',
        grad: 'normal',
        stage: 'fullbordat',
      },
    ],
    personer: [{ personId: 2, roll: 'misstankt', personNumber: 'P-000512' }],
  },
  {
    id: 3,
    number: 'LSPD-26-000103',
    title: 'Skadegörelse, busshållplats',
    status: 'inlamnad',
    // The viewer's own, submitted. The case that must not be approvable.
    createdBy: FIXTURE_VIEWER,
    version: 2,
    brott: [
      {
        id: 13,
        code: 'BRB-12-1',
        labelKey: 'brott.rubrik.skadegorelse',
        citation: 'BrB 12:1',
        grad: 'normal',
        stage: 'fullbordat',
      },
    ],
    personer: [],
  },
];

/**
 * Two records the reader may be told about and may not read (4.5).
 *
 * **Two, not one, deliberately.** A stub carries no `id`, so a list keyed by
 * `row.id` gives them the same `undefined` key and Svelte refuses to render the
 * list at all — the whole tab goes blank. One stub would not have caught it.
 */
const restrictedAnmalningar = [
  { restricted: true as const, recordType: 'report', contact: 'internal_affairs' },
  { restricted: true as const, recordType: 'report', contact: 'narcotics' },
];

/**
 * A workflow transition against the fixture rows.
 *
 * Enforces the two rules the screen is tested against: an approved anmälan is
 * locked, and nobody approves their own.
 */
function moveAnmalan(input: unknown, to: string): unknown {
  const { id, note } = (input ?? {}) as { id?: number; note?: string };
  const row = anmalningar.find((entry) => entry.id === id);

  if (!row) return refuse('not_found');
  if (row.status === 'godkand') return refuse('conflict', { status: 'locked' });

  if (to === 'godkand' && row.createdBy === FIXTURE_VIEWER) {
    return refuse('forbidden', { status: 'own_report' });
  }

  // The note follows the same rule `Repo.transition` applies on the server:
  // a return carries the supervisor's reason, and resubmitting clears it, so
  // an approved report never displays an objection to the version approved.
  if (to === 'atersand') {
    row.returnedNote = note ?? null;
  } else if (to === 'inlamnad') {
    row.returnedNote = null;
  }

  row.status = to;
  row.version += 1;

  return { id: row.id, status: to };
}

// ------------------------------------------------------- frihetsberövande

interface FixtureFrihet {
  id: number;
  number: string;
  status: string;
  personId: number;
  personNumber: string;
  gripandeGrund: string;
  /** Where the arrest happened. Free text — `repo.lua` selects it as this. */
  gripandePlats?: string;
  anhallandeGrund?: string;
  frigivenGrund?: string;
  version: number;
  /** Seconds before "now" each stage happened; absent means it has not. */
  gripenAgo?: number;
  anhallenAgo?: number;
  framstallanAgo?: number;
  haktadAgo?: number;
  frigivenAgo?: number;
  gripenBy?: string;
  anhallenBy?: string;
  haktadBy?: string;
  frigivenBy?: string;
  underrattadAgo?: number;
  brott: { id: number; brottId: number; code: string; labelKey: string; citation: string; grad: string; stage: string }[];
  log: {
    id: number;
    kind: string;
    note: string | null;
    loggedByCallsign: string | null;
    loggedByName: string | null;
    loggedAgo: number;
  }[];
}

const HOUR = 3600;

/**
 * Four chains, chosen for the four things the screen draws differently.
 *
 * Every timestamp is relative to the moment the fixture is read, because the
 * whole screen is a countdown: a fixture with fixed dates would be comfortably
 * in hand on the day it was written and years overdue by the time anybody ran
 * the test again.
 */
const frihetsberovanden: FixtureFrihet[] = [
  {
    // Just arrested. RB 24:13 has most of its four dygn left, and there is no
    // RB 24:12 clock yet because no prosecutor has decided anything.
    id: 1,
    number: 'A26-00041',
    status: 'gripen',
    personId: 2,
    personNumber: 'P-000512',
    gripandeGrund: 'pa_bar_garning',
    gripandePlats: 'Kvarngatan 3B, outside the stairwell',
    version: 1,
    gripenAgo: 3 * HOUR,
    gripenBy: FIXTURE_VIEWER,
    brott: [
      {
        id: 21,
        brottId: 12,
        code: 'BRB-3-5',
        labelKey: 'brott.rubrik.misshandel',
        citation: 'BrB 3:5',
        grad: 'normal',
        stage: 'fullbordat',
      },
    ],
    log: [
      {
        id: 201,
        kind: 'frihet.logKind.maltid',
        note: null,
        loggedByCallsign: '1-ADAM-12',
        loggedByName: 'Berg',
        loggedAgo: 1 * HOUR,
      },
    ],
  },
  {
    // **Overdue.** Anhållen four days ago with no häktningsframställan, so RB
    // 24:12's noon is long past. This is the red row, and the one the whole
    // screen exists to put in front of somebody.
    id: 2,
    number: 'A26-00039',
    status: 'anhallen',
    personId: 1,
    personNumber: 'P-000431',
    gripandeGrund: 'flyktfara',
    anhallandeGrund: 'flyktfara',
    version: 2,
    gripenAgo: 100 * HOUR,
    anhallenAgo: 96 * HOUR,
    gripenBy: '100000000000000002',
    anhallenBy: '100000000000000003',
    underrattadAgo: 99 * HOUR,
    brott: [
      {
        id: 22,
        brottId: 11,
        code: 'BRB-8-4',
        labelKey: 'brott.rubrik.grov_stold',
        citation: 'BrB 8:4',
        grad: 'grov',
        stage: 'fullbordat',
      },
    ],
    log: [],
  },
  {
    // Inside the warning window but not yet past it: the amber case, which is
    // what `needsAttention` is generous about on purpose.
    id: 3,
    number: 'A26-00040',
    status: 'framstalld',
    personId: 3,
    personNumber: 'P-000733',
    gripandeGrund: 'kollusionsfara',
    anhallandeGrund: 'kollusionsfara',
    version: 3,
    gripenAgo: 92 * HOUR,
    anhallenAgo: 90 * HOUR,
    framstallanAgo: 2 * HOUR,
    gripenBy: FIXTURE_VIEWER,
    anhallenBy: '100000000000000003',
    brott: [],
    log: [],
  },
  {
    // Closed. Only reachable with the "currently held" filter off, and its
    // `heldFor` must stop growing — a released chain reports what it was.
    id: 4,
    number: 'A26-00038',
    status: 'frigiven',
    personId: 4,
    personNumber: 'P-000108',
    gripandeGrund: 'identitet_oklar',
    frigivenGrund: 'ej_anhallen',
    version: 4,
    gripenAgo: 200 * HOUR,
    frigivenAgo: 194 * HOUR,
    gripenBy: FIXTURE_VIEWER,
    frigivenBy: FIXTURE_VIEWER,
    brott: [],
    log: [],
  },
];

/** Two stubs, for the reason `restrictedAnmalningar` gives: one would not collide. */
const restrictedFrihet = [
  { restricted: true as const, recordType: 'arrest', contact: 'internal_affairs' },
  { restricted: true as const, recordType: 'arrest', contact: 'homicide' },
];

/**
 * The derived fields `withClocks` adds on the server, computed the same way.
 *
 * RB 24:12 is approximated here as noon on the third day in UTC — the fixture
 * does not need the server's daylight-saving correctness, it needs a deadline
 * that is plainly in the past for row 2 and plainly ahead for row 3. The real
 * arithmetic is pinned by `frihet_spec.lua` against fixed instants.
 */
function withFixtureClocks(row: FixtureFrihet): Record<string, unknown> {
  const now = Date.now();
  const at = (ago?: number) => (ago === undefined ? null : new Date(now - ago * 1000).toISOString());
  const seconds = (ago?: number) => (ago === undefined ? null : now / 1000 - ago);

  const deadlines: Record<string, { at: number; remaining: number; passed: boolean }> = {};

  // A released chain carries no deadline, as `Frihet.deadlines` does not. The
  // fixture has to agree or the e2e suite asserts a screen the server cannot
  // produce -- which is exactly how the `grund` drift went unnoticed.
  const released = row.status === 'frigiven';

  const anhallenAt = released ? null : seconds(row.anhallenAgo);
  if (anhallenAt !== null && row.framstallanAgo === undefined) {
    const noon = new Date(anhallenAt * 1000);
    noon.setUTCDate(noon.getUTCDate() + 3);
    noon.setUTCHours(12, 0, 0, 0);

    const deadlineAt = noon.getTime() / 1000;
    const remaining = deadlineAt - now / 1000;

    deadlines.framstallan = { at: deadlineAt, remaining, passed: remaining < 0 };
  }

  const start = released ? null : (seconds(row.gripenAgo) ?? anhallenAt);
  if (start !== null && row.haktadAgo === undefined) {
    const deadlineAt = start + 96 * HOUR;
    const remaining = deadlineAt - now / 1000;

    deadlines.forhandling = { at: deadlineAt, remaining, passed: remaining < 0 };
  }

  // The nearer of the two, with a passed one always winning — `nextDeadline`.
  // Reduced over entries rather than keys so the lookup cannot be undefined.
  const best = Object.entries(deadlines).reduce<
    [string, { at: number; remaining: number; passed: boolean }] | null
  >((winner, entry) => {
    if (!winner) return entry;
    if (entry[1].passed !== winner[1].passed) return entry[1].passed ? entry : winner;

    return entry[1].at < winner[1].at ? entry : winner;
  }, null);

  const nextDeadline = best ? best[0] : null;

  const heldStart = row.gripenAgo ?? row.anhallenAgo;
  const heldFor =
    heldStart === undefined
      ? null
      : row.frigivenAgo === undefined
        ? heldStart
        : heldStart - row.frigivenAgo;

  const next = best ? best[1] : null;

  return {
    id: row.id,
    number: row.number,
    status: row.status,
    personId: row.personId,
    personNumber: row.personNumber,
    gripandeGrund: row.gripandeGrund,
    gripandePlats: row.gripandePlats ?? null,
    anhallandeGrund: row.anhallandeGrund ?? null,
    frigivenGrund: row.frigivenGrund ?? null,
    version: row.version,
    gripenAt: at(row.gripenAgo),
    gripenBy: row.gripenBy ?? null,
    anhallenAt: at(row.anhallenAgo),
    anhallenBy: row.anhallenBy ?? null,
    framstallanAt: at(row.framstallanAgo),
    haktadAt: at(row.haktadAgo),
    haktadBy: row.haktadBy ?? null,
    frigivenAt: at(row.frigivenAgo),
    frigivenBy: row.frigivenBy ?? null,
    underrattadAt: at(row.underrattadAgo),
    deadlines,
    nextDeadline,
    heldFor,
    needsAttention: next ? next.passed || next.remaining <= 6 * HOUR : false,
  };
}

/**
 * A decision against the fixture rows.
 *
 * Enforces the two rules the screen is tested against: the chain's order, and
 * the capacity each decision requires. The viewer is an ordinary officer, so
 * `anhallande` and `haktning` are refused — which is the refusal path the
 * screen has to draw as "that decision is not yours to take" rather than as a
 * Discord role problem.
 */
const FIXTURE_CAPACITY = 'polis';

const NEXT_STATUS: Record<string, Record<string, string>> = {
  gripen: { anhallande: 'anhallen', frigiv: 'frigiven' },
  anhallen: { framstallan: 'framstalld', frigiv: 'frigiven' },
  framstalld: { haktning: 'haktad', frigiv: 'frigiven' },
  haktad: { frigiv: 'frigiven' },
};

const CAPACITY_FOR: Record<string, string> = {
  anhallande: 'aklagare',
  framstallan: 'aklagare',
  haktning: 'domare',
};

function decideFrihet(input: unknown, action: string): unknown {
  const { id, grund } = (input ?? {}) as { id?: number; grund?: string };
  const row = frihetsberovanden.find((entry) => entry.id === id);

  if (!row) return refuse('not_found');
  if (row.status === 'frigiven') return refuse('conflict', { status: 'already_released' });

  const to = NEXT_STATUS[row.status]?.[action];
  if (!to) return refuse('conflict', { status: 'out_of_order' });

  const required = CAPACITY_FOR[action];
  if (required && required !== FIXTURE_CAPACITY) {
    return refuse('forbidden', { status: 'wrong_capacity' });
  }

  if ((to === 'anhallen' || to === 'frigiven') && !grund) {
    return refuse('invalid', { grund: 'required' });
  }

  row.status = to;
  row.version += 1;

  if (to === 'anhallen') {
    row.anhallenAgo = 0;
    if (grund) row.anhallandeGrund = grund;
  }
  if (to === 'framstalld') row.framstallanAgo = 0;
  if (to === 'haktad') row.haktadAgo = 0;
  if (to === 'frigiven') {
    row.frigivenAgo = 0;
    if (grund) row.frigivenGrund = grund;
  }

  return { id: row.id, status: to };
}

// ------------------------------------------ brottskatalogen (spec 7.10)

/**
 * An offence as `brott/repo.lua` selects one, plus the `citation` the route
 * derives. Both halves matter: the citation is computed on the server so there
 * is one definition of `BrB 8:1`, and a fixture that invented its own format
 * would let the screen be built against a server that does not exist.
 */
interface FixtureBrott {
  id: number;
  code: string;
  version: number;
  balk: string;
  kapitel: number;
  paragraf: number;
  stycke: number | null;
  labelKey: string;
  grad: string;
  boter: boolean;
  fangelseMinMonths: number | null;
  fangelseMaxMonths: number | null;
  forsok: boolean;
  forberedelse: boolean;
  preskriptionYears: number;
  supersededAt: string | null;
}

const brottskatalog: FixtureBrott[] = [
  {
    id: 11,
    code: 'BRB-8-4',
    version: 2,
    balk: 'BrB',
    kapitel: 8,
    paragraf: 4,
    stycke: null,
    labelKey: 'brott.rubrik.grov_stold',
    grad: 'grov',
    boter: false,
    fangelseMinMonths: 6,
    fangelseMaxMonths: 72,
    forsok: true,
    forberedelse: true,
    preskriptionYears: 10,
    supersededAt: null,
  },
  {
    id: 12,
    code: 'BRB-3-5',
    version: 1,
    balk: 'BrB',
    kapitel: 3,
    paragraf: 5,
    stycke: null,
    labelKey: 'brott.rubrik.misshandel',
    grad: 'normal',
    boter: false,
    fangelseMinMonths: 0,
    fangelseMaxMonths: 24,
    forsok: false,
    forberedelse: false,
    preskriptionYears: 5,
    supersededAt: null,
  },
  {
    // Fines only, which is the other shape a straffskala takes.
    id: 13,
    code: 'BRB-8-2',
    version: 1,
    balk: 'BrB',
    kapitel: 8,
    paragraf: 2,
    stycke: null,
    labelKey: 'brott.rubrik.ringa_stold',
    grad: 'ringa',
    boter: true,
    fangelseMinMonths: 0,
    fangelseMaxMonths: 6,
    forsok: false,
    forberedelse: false,
    preskriptionYears: 2,
    supersededAt: null,
  },
];

/** The version this offence had before the current one. */
const supersededBrott: FixtureBrott[] = [
  {
    ...(brottskatalog[0] as FixtureBrott),
    id: 10,
    version: 1,
    fangelseMinMonths: 6,
    fangelseMaxMonths: 48,
    supersededAt: '2026-04-01T00:00:00.000Z',
  },
];

/** `Brott.citation` — `BrB 8:4`, with the stycke where there is one. */
function citationOf(row: FixtureBrott): string {
  const base = `${row.balk} ${row.kapitel}:${row.paragraf}`;

  return row.stycke ? `${base} ${row.stycke} st` : base;
}

function brottRow(row: FixtureBrott): Record<string, unknown> {
  return {
    id: row.id,
    agencyId: session.agencyId,
    code: row.code,
    version: row.version,
    balk: row.balk,
    kapitel: row.kapitel,
    paragraf: row.paragraf,
    stycke: row.stycke,
    labelKey: row.labelKey,
    descriptionKey: null,
    grad: row.grad,
    boter: row.boter,
    fangelseMinMonths: row.fangelseMinMonths,
    fangelseMaxMonths: row.fangelseMaxMonths,
    forsok: row.forsok,
    forberedelse: row.forberedelse,
    preskriptionYears: row.preskriptionYears,
    supersededAt: row.supersededAt,
    createdAt: '2026-01-02T00:00:00.000Z',
    citation: citationOf(row),
  };
}

/**
 * BrB 26:2's gemensam straffskala, mirroring `Brott.gemensamStraffskala`.
 *
 * Four rules, in the statute's order, and getting any of them wrong here would
 * teach the screen an arithmetic the server does not do:
 *
 *   1. **The floor is the heaviest floor**, not the sum. Three offences each
 *      carrying six months still have a six-month floor.
 *   2. **The ceiling is the heaviest ceiling plus an uplift** — a year where
 *      the heaviest is under four, two years under eight, four above that.
 *   3. **Capped by the sum of the maxima.** Two six-month offences cannot
 *      reach eighteen months however generous the band is.
 *   4. **Then capped at eighteen years**, which BrB 26:1 allows for a fixed
 *      term. Rule 3 before rule 4, because applying the statutory cap first
 *      would let the sum push back above it.
 *
 * A single offence is not konkurrens at all and keeps its own span exactly.
 */
function konkurrensUplift(heaviestMax: number): number {
  if (heaviestMax < 4 * 12) return 12;
  if (heaviestMax < 8 * 12) return 24;

  return 48;
}

const MAX_FIXED_MONTHS = 18 * 12;

function gemensamStraffskala(rows: FixtureBrott[]): {
  boter: boolean;
  min: number;
  max: number | null;
} {
  const floor = Math.max(...rows.map((row) => row.fangelseMinMonths ?? 0));
  const boter = rows.every((row) => row.boter);

  // A `null` maximum is life imprisonment, and it swallows everything.
  if (rows.some((row) => row.fangelseMaxMonths === null)) {
    return { boter: false, min: floor, max: null };
  }

  const maxima = rows.map((row) => row.fangelseMaxMonths as number);

  if (rows.length === 1) {
    return {
      boter: rows[0]?.boter ?? false,
      min: rows[0]?.fangelseMinMonths ?? 0,
      max: maxima[0] ?? 0,
    };
  }

  const heaviest = Math.max(...maxima);
  const sum = maxima.reduce((total, value) => total + value, 0);

  let ceiling = heaviest + konkurrensUplift(heaviest);

  if (ceiling > sum) ceiling = sum;
  if (ceiling > MAX_FIXED_MONTHS) ceiling = MAX_FIXED_MONTHS;

  return { boter, min: floor, max: ceiling };
}

// --------------------------------------------- förundersökning (spec 7.8)

/**
 * A förundersökning as `FU_SELECT` sends one, column for column.
 *
 * `opened_at` and the rest are plain DATETIME here — this repo does not go
 * through `UNIX_TIMESTAMP` — so the fixture sends ISO strings, which is what
 * the server sends. The unit matters as much as the name.
 */
interface FixtureFu {
  id: number;
  number: string;
  title: string;
  status: string;
  fuLedare: string | null;
  ledareKind: string | null;
  openedAt: string;
  closedAt: string | null;
  closedReason: string | null;
  closedNote: string | null;
  version: number;
  /** The reports gathered under it, by anmälan id. */
  anmalanIds: number[];
}

const forundersokningar: FixtureFu[] = [
  {
    // Open, led by the police. The ordinary case, and the one the three
    // endings are drawn for.
    id: 1,
    number: 'FU26-00031',
    title: 'Serial burglaries, Kvarngatan',
    status: 'inledd',
    fuLedare: FIXTURE_VIEWER,
    ledareKind: 'polis',
    openedAt: '2026-09-12T08:20:00.000Z',
    closedAt: null,
    closedReason: null,
    closedNote: null,
    version: 1,
    anmalanIds: [1, 2],
  },
  {
    // Led by a prosecutor, which is what happens once somebody is anhållen.
    id: 2,
    number: 'FU26-00028',
    title: 'Aggravated assault, Sandstensvägen',
    status: 'slutdelgiven',
    fuLedare: '100000000000000003',
    ledareKind: 'aklagare',
    openedAt: '2026-08-30T14:05:00.000Z',
    closedAt: null,
    closedReason: null,
    closedNote: null,
    version: 2,
    anmalanIds: [],
  },
  {
    // Discontinued, and it says why — which is what the suspect is told.
    id: 3,
    number: 'FU26-00019',
    title: 'Criminal damage, the ferry terminal',
    status: 'nedlagd',
    fuLedare: FIXTURE_VIEWER,
    ledareKind: 'polis',
    openedAt: '2026-07-02T19:40:00.000Z',
    closedAt: '2026-08-11T11:00:00.000Z',
    closedReason: 'brott_kan_ej_styrkas',
    closedNote: 'No usable camera footage and the complainant withdrew.',
    version: 3,
    anmalanIds: [],
  },
];

const restrictedFu = [
  { restricted: true as const, recordType: 'fu', contact: 'internal_affairs' },
  { restricted: true as const, recordType: 'fu', contact: 'homicide' },
];

function fuRow(row: FixtureFu): Record<string, unknown> {
  return {
    id: row.id,
    agencyId: session.agencyId,
    number: row.number,
    title: row.title,
    status: row.status,
    fuLedare: row.fuLedare,
    ledareKind: row.ledareKind,
    intelCaseId: null,
    openedBy: row.fuLedare,
    openedAt: row.openedAt,
    closedBy: row.closedAt ? FIXTURE_VIEWER : null,
    closedAt: row.closedAt,
    closedReason: row.closedReason,
    closedNote: row.closedNote,
    classification: 'internal',
    version: row.version,
    updatedAt: row.openedAt,
  };
}

/** Mirrors the server's transitions: two endings are final. */
const FU_NEXT: Record<string, Record<string, string>> = {
  inledd: { slutdelge: 'slutdelgiven', redovisa: 'redovisad', lagg_ned: 'nedlagd' },
  slutdelgiven: { redovisa: 'redovisad', lagg_ned: 'nedlagd' },
};

function decideFu(input: unknown, action: string): unknown {
  const { id, version, reason, note } = (input ?? {}) as {
    id?: number;
    version?: number;
    reason?: string;
    note?: string;
  };

  const row = forundersokningar.find((entry) => entry.id === id);

  if (!row) return refuse('not_found');

  const to = FU_NEXT[row.status]?.[action];
  if (!to) return refuse('conflict', { status: 'out_of_order' });
  if (row.version !== version) return refuse('conflict', { version: 'stale' });

  row.status = to;
  row.version += 1;

  // Only a discontinuation closes it. Slutdelgivning is a step in an
  // investigation that carries on afterwards.
  if (to === 'nedlagd' || to === 'redovisad') {
    row.closedAt = new Date().toISOString();
    row.closedReason = reason ?? null;
    row.closedNote = note ?? null;
  }

  return { id: row.id, status: to };
}

// ------------------------------------------------- the unified query (7.2)

/**
 * The hits the fixture raises, by the record they sit on.
 *
 * Shaped like `Query.hit`: `hitType`, `hitId`, `kind`, `recordType`,
 * `recordId`, `confirmed`. `kind` is the flag kind, the firearm status, the
 * caution kind or the efterlysning ground — the thing the banner names.
 *
 * Only hits the *server* would raise are here, which is the part worth being
 * careful about: the four efterlysning grounds that are not "detain on sight"
 * never become a hit at all, and a lookout only does at priority 1. A fixture
 * that raised a banner for a missing person would let the screen be built
 * against a server that does not exist.
 */
interface FixtureHit {
  hitType: string;
  hitId: number;
  kind: string;
  recordType: string;
  recordId: number;
  confirmed: boolean;
}

const queryHits: Record<string, FixtureHit[]> = {
  // John Doe: anhållen i sin frånvaro. The one that ends with an officer
  // stopping somebody, and the reason the confirmation step exists.
  'person:1': [
    {
      hitType: 'efterlysning',
      hitId: 1,
      kind: 'anhallen_i_franvaro',
      recordType: 'person',
      recordId: 1,
      confirmed: false,
    },
  ],
  // Ellen Doe carries a caution, which is a different kind of warning: it is
  // about how to approach somebody, not about detaining them.
  'person:2': [
    {
      hitType: 'person_caution',
      hitId: 7,
      kind: 'violent',
      recordType: 'person',
      recordId: 2,
      confirmed: false,
    },
  ],
};

/**
 * `fpd_query_log`, named the way `Repo.queryLog` selects it.
 *
 * Every query writes one, including the query that found nothing and the one
 * refused for want of a reason — that is the whole point of the table, which
 * answers "who has been looking up their ex-partner".
 */
interface FixtureQueryLog {
  id: number;
  queryType: string;
  term: string;
  accessPoint: string | null;
  restricted: boolean;
  resultCount: number;
  hitCount: number;
  confirmationCount: number;
  confirmedCount: number;
  reason: string | null;
  caseNumber: string | null;
  createdAt: string;
}

const queryLog: FixtureQueryLog[] = [
  {
    id: 401,
    queryType: 'plate',
    term: '47ANX291',
    accessPoint: null,
    restricted: false,
    resultCount: 1,
    hitCount: 1,
    confirmationCount: 1,
    confirmedCount: 1,
    reason: 'Traffic stop, Alta Street',
    caseNumber: 'K26-00512',
    createdAt: '2026-09-19T21:04:00.000Z',
  },
  {
    // Found nothing, and is logged anyway. A query that matched nothing is
    // part of the answer to "who has been looking somebody up".
    id: 400,
    queryType: 'person',
    term: 'nilsson',
    accessPoint: null,
    restricted: false,
    resultCount: 0,
    hitCount: 0,
    confirmationCount: 0,
    confirmedCount: 0,
    reason: null,
    caseNumber: null,
    createdAt: '2026-09-19T18:41:00.000Z',
  },
];

let nextQueryId = 401;

/** Which registers a term could mean, the way `Query.plan` decides it. */
function planQuery(term: string, explicit?: string): { type: string; sources: string[] } {
  if (explicit) {
    const sources =
      explicit === 'person' || explicit === 'phone' || explicit === 'address'
        ? ['person']
        : explicit === 'firearm'
          ? ['firearm']
          : ['vehicle'];

    return { type: explicit, sources };
  }

  // A plate is short and alphanumeric; a person is words. The real planner is
  // `Query.plan` and is considerably more careful — this only has to be
  // consistent enough that the screen renders what the server would send.
  if (/^[a-z0-9]{2,8}$/i.test(term.trim()) && /\d/.test(term)) {
    return { type: 'plate', sources: ['vehicle'] };
  }

  return { type: 'person', sources: ['person', 'vehicle', 'firearm'] };
}

// ------------------------------------------- tvångsmedel och efterlysning

/**
 * A measure as `TVANG_SELECT` sends one — column for column, **and in the
 * server's units**.
 *
 * `tvangsmedel/repo.lua` selects every timestamp through `UNIX_TIMESTAMP`,
 * which is epoch *seconds*. The fixture stores offsets and renders seconds for
 * the same reason it mirrors the column names: a fixture that sent ISO strings
 * would exercise a branch of the formatter the server never reaches, and the
 * screen would pass every test while rendering 1970 in game. That is precisely
 * how the missing `grund` survived a full test suite.
 */
interface FixtureTvang {
  id: number;
  number: string;
  kind: string;
  targetKind: string;
  targetId: number;
  targetLabel: string | null;
  fuId: number | null;
  deciderKind: string;
  grund: string;
  scope: string | null;
  /** Seconds before "now"; negative is in the future. */
  validFromAgo: number;
  validUntilAgo: number;
  verkstalldAgo?: number;
  verkstalldNote?: string | null;
  upphavdAgo?: number;
  version: number;
}

const DAY = 24 * HOUR;

const tvangsmedel: FixtureTvang[] = [
  {
    // In force, not yet carried out: the ordinary case, and the one the
    // execution form is drawn for.
    id: 1,
    number: 'W26-00114',
    kind: 'husrannsakan_reell',
    targetKind: 'address',
    targetId: 41,
    targetLabel: 'Sandstensvägen 7',
    fuId: 1,
    deciderKind: 'fu_ledare',
    grund: 'sakra_bevis',
    scope: 'Kitchen, garage and the outbuilding. Tools and stolen goods.',
    validFromAgo: 6 * HOUR,
    validUntilAgo: -5 * DAY,
    version: 1,
  },
  {
    // Revoked. The row an officer at a door must not read as valid, and the
    // reason the detail panel says *which* way it stopped being valid.
    id: 2,
    number: 'W26-00110',
    kind: 'husrannsakan_personell',
    targetKind: 'address',
    targetId: 12,
    targetLabel: 'Kvarngatan 3B',
    fuId: 1,
    deciderKind: 'aklagare',
    grund: 'eftersokande_person',
    scope: null,
    validFromAgo: 2 * DAY,
    validUntilAgo: -2 * DAY,
    upphavdAgo: 4 * HOUR,
    version: 2,
  },
  {
    // Carried out, and still valid: RB allows a husrannsakan to be resumed, so
    // execution is a record and not a state change.
    id: 3,
    number: 'W26-00108',
    kind: 'kroppsvisitation',
    targetKind: 'person',
    targetId: 2,
    targetLabel: null,
    fuId: null,
    deciderKind: 'fu_ledare',
    grund: 'skalig_misstanke',
    scope: null,
    validFromAgo: 3 * DAY,
    validUntilAgo: -4 * DAY,
    verkstalldAgo: 2 * DAY,
    verkstalldNote: 'Nothing found.',
    version: 2,
  },
];

const restrictedTvang = [
  { restricted: true as const, recordType: 'warrant', contact: 'internal_affairs' },
  { restricted: true as const, recordType: 'warrant', contact: 'homicide' },
];

/** Epoch seconds for an offset, the way `UNIX_TIMESTAMP` would answer. */
function secondsAgo(ago: number): number {
  return Math.floor(Date.now() / 1000) - ago;
}

/** `Tvang.isValid`, computed the way the server computes it. */
function tvangLiveness(row: FixtureTvang): { live: boolean; why: string | null } {
  if (row.upphavdAgo !== undefined) return { live: false, why: 'upphavd' };
  if (row.validFromAgo < 0) return { live: false, why: 'not_yet' };
  if (row.validUntilAgo > 0) return { live: false, why: 'expired' };

  return { live: true, why: null };
}

function tvangRow(row: FixtureTvang, withReason: boolean): Record<string, unknown> {
  const { live, why } = tvangLiveness(row);

  const shaped: Record<string, unknown> = {
    id: row.id,
    agencyId: session.agencyId,
    number: row.number,
    kind: row.kind,
    targetKind: row.targetKind,
    targetId: row.targetId,
    targetLabel: row.targetLabel,
    fuId: row.fuId,
    decidedBy: FIXTURE_VIEWER,
    deciderKind: row.deciderKind,
    grund: row.grund,
    scope: row.scope,
    validFrom: secondsAgo(row.validFromAgo),
    validUntil: secondsAgo(row.validUntilAgo),
    verkstalldAt: row.verkstalldAgo === undefined ? null : secondsAgo(row.verkstalldAgo),
    verkstalldBy: row.verkstalldAgo === undefined ? null : FIXTURE_VIEWER,
    verkstalldNote: row.verkstalldNote ?? null,
    upphavdAt: row.upphavdAgo === undefined ? null : secondsAgo(row.upphavdAgo),
    upphavdBy: row.upphavdAgo === undefined ? null : FIXTURE_VIEWER,
    classification: 'internal',
    version: row.version,
    live,
  };

  // Only `tvang.get` sends the reason. A list row that is not live says just
  // that, because the route does not compute why for fifty rows.
  if (withReason) shaped.notLiveBecause = why;

  return shaped;
}

/**
 * The capacity the fixture session decides in.
 *
 * `capacityOf` falls through to `fu_ledare` for an officer holding neither the
 * prosecutor nor the judge grant, which is this viewer. It is what makes
 * kroppsbesiktning refuse with `wrong_capacity` — the measure FredPD holds
 * back because it reaches inside somebody's body.
 */
const FIXTURE_TVANG_CAPACITY = 'fu_ledare';

const TVANG_ALLOWED: Record<string, string[]> = {
  fu_ledare: ['husrannsakan_reell', 'husrannsakan_personell', 'kroppsvisitation', 'beslag'],
  aklagare: [
    'husrannsakan_reell',
    'husrannsakan_personell',
    'kroppsvisitation',
    'kroppsbesiktning',
    'beslag',
  ],
};

interface FixtureEfterlysning {
  id: number;
  number: string;
  personId: number;
  personNumber: string;
  grund: string;
  note: string | null;
  priority: number;
  issuedAgo: number;
  /** Absent means it stands until it is lifted, which is the real default. */
  expiresAgo?: number;
  cancelledAgo?: number;
  cancelledGrund?: string | null;
  version: number;
}

const efterlysningar: FixtureEfterlysning[] = [
  {
    // Detain on sight: a prosecutor's decision, and the row the officer acts
    // on.
    id: 1,
    number: 'W26-00115',
    personId: 1,
    personNumber: 'P-000431',
    grund: 'anhallen_i_franvaro',
    note: 'Believed to be staying with family in the north of the city.',
    priority: 1,
    issuedAgo: 2 * DAY,
    version: 1,
  },
  {
    // Wanted, and emphatically not for arrest. The distinction this register
    // exists to draw: somebody to be handed a document is not somebody to
    // put in a cell.
    id: 2,
    number: 'W26-00112',
    personId: 3,
    personNumber: 'P-000733',
    grund: 'delgivning',
    note: null,
    priority: 3,
    issuedAgo: 9 * DAY,
    expiresAgo: -20 * DAY,
    version: 1,
  },
  {
    // A missing person — wanted for their own sake, and the second way the
    // detain-on-sight line has to stay off.
    id: 3,
    number: 'W26-00105',
    personId: 4,
    personNumber: 'P-000108',
    grund: 'forsvunnen',
    note: 'Last seen at the ferry terminal.',
    priority: 2,
    issuedAgo: 30 * DAY,
    version: 1,
  },
  {
    // Lifted, and it says why. Only reachable with the filter off.
    id: 4,
    number: 'W26-00099',
    personId: 2,
    personNumber: 'P-000512',
    grund: 'anhallen_i_franvaro',
    note: null,
    priority: 1,
    issuedAgo: 40 * DAY,
    cancelledAgo: 38 * DAY,
    cancelledGrund: 'gripen',
    version: 2,
  },
];

const restrictedEfterlysning = [
  { restricted: true as const, recordType: 'efterlysning', contact: 'internal_affairs' },
  { restricted: true as const, recordType: 'efterlysning', contact: 'homicide' },
];

/** The two grounds that mean "detain on sight" — `Tvang.detainOnSight`. */
const DETAIN_ON_SIGHT = ['anhallen_i_franvaro', 'haktad_i_franvaro'];

function efterlysningRow(row: FixtureEfterlysning): Record<string, unknown> {
  const cancelled = row.cancelledAgo !== undefined;
  const expired = row.expiresAgo !== undefined && row.expiresAgo > 0;
  const live = !cancelled && !expired;

  return {
    id: row.id,
    agencyId: session.agencyId,
    number: row.number,
    personId: row.personId,
    grund: row.grund,
    frihetId: null,
    fuId: null,
    note: row.note,
    priority: row.priority,
    issuedBy: FIXTURE_VIEWER,
    issuedAt: secondsAgo(row.issuedAgo),
    expiresAt: row.expiresAgo === undefined ? null : secondsAgo(row.expiresAgo),
    cancelledAt: cancelled ? secondsAgo(row.cancelledAgo as number) : null,
    cancelledBy: cancelled ? FIXTURE_VIEWER : null,
    cancelledGrund: row.cancelledGrund ?? null,
    classification: 'internal',
    version: row.version,
    personNumber: row.personNumber,
    live,
    detainOnSight: DETAIN_ON_SIGHT.includes(row.grund),
  };
}

// ---------------------------------------------------------------- spaning

interface FixtureSpaning {
  id: number;
  number: string;
  targetKind: string;
  targetId: number | null;
  description: string | null;
  grund: string;
  priority: number;
  areaNote: string | null;
  issuedAgo: number;
  expiresAgo: number;
  resolvedAgo?: number;
  resolvedGrund?: string | null;
  version: number;
}

const spaningsuppdrag: FixtureSpaning[] = [
  {
    // Priority 1: the only level that reaches a banner, and the only one the
    // list draws in the alert colour.
    id: 1,
    number: 'S26-00042',
    targetKind: 'vehicle',
    targetId: 7,
    description: null,
    grund: 'stulet_fordon',
    priority: 1,
    areaNote: 'Southside, around the docks',
    issuedAgo: 3 * HOUR,
    expiresAgo: -6 * DAY,
    version: 1,
  },
  {
    // A description and no record behind it — the commonest lookout there is,
    // and the case a foreign key cannot express.
    id: 2,
    number: 'S26-00041',
    targetKind: 'other',
    targetId: null,
    description: 'Silver estate, no plate seen, three occupants',
    grund: 'iakttagelse',
    priority: 3,
    areaNote: null,
    issuedAgo: 2 * DAY,
    expiresAgo: -5 * DAY,
    version: 1,
  },
  {
    // Closed, with the ground that closed it. Only reachable with the filter
    // off.
    id: 3,
    number: 'S26-00033',
    targetKind: 'person',
    targetId: 3,
    description: null,
    grund: 'eftersokt_person',
    priority: 2,
    areaNote: null,
    issuedAgo: 20 * DAY,
    expiresAgo: -3 * DAY,
    resolvedAgo: 9 * DAY,
    resolvedGrund: 'gripen',
    version: 2,
  },
];

const restrictedSpaning = [
  { restricted: true as const, recordType: 'spaning', contact: 'internal_affairs' },
  { restricted: true as const, recordType: 'spaning', contact: 'homicide' },
];

/** `Spaning.bannerFor`: priority alone decides, and 1 is the only `alert`. */
function bannerFor(priority: number): string {
  if (priority <= 1) return 'alert';
  if (priority <= 3) return 'notice';

  return 'quiet';
}

function spaningRow(row: FixtureSpaning): Record<string, unknown> {
  const live = row.resolvedAgo === undefined && row.expiresAgo < 0;
  const banner = bannerFor(row.priority);

  return {
    id: row.id,
    agencyId: session.agencyId,
    number: row.number,
    targetKind: row.targetKind,
    targetId: row.targetId,
    description: row.description,
    grund: row.grund,
    priority: row.priority,
    beatId: null,
    areaNote: row.areaNote,
    fuId: null,
    anmalanId: null,
    issuedBy: FIXTURE_VIEWER,
    issuedAt: secondsAgo(row.issuedAgo),
    expiresAt: secondsAgo(row.expiresAgo),
    resolvedAt: row.resolvedAgo === undefined ? null : secondsAgo(row.resolvedAgo),
    resolvedBy: row.resolvedAgo === undefined ? null : FIXTURE_VIEWER,
    resolvedGrund: row.resolvedGrund ?? null,
    classification: 'internal',
    version: row.version,
    live,
    banner,
    needsConfirmation: banner === 'alert',
  };
}

export const fixtures: FixtureSet = {
  ok: {
    'session.get': () => session,

    // ------------------------------------------------- frihetsberövande

    /**
     * Everybody the agency is holding (spec 7.9). No filter — the route takes
     * none, because "who is in our cells right now" has one answer.
     */
    'frihet.open': () => ({
      frihetsberovanden: [
        ...frihetsberovanden
          .filter((row) => row.status !== 'frigiven')
          .map((row) => withFixtureClocks(row)),
        ...restrictedFrihet,
      ],
    }),

    'frihet.list': (input) => {
      const filter = (input ?? {}) as { status?: string };

      return {
        frihetsberovanden: [
          ...frihetsberovanden
            .filter((row) => !filter.status || row.status === filter.status)
            .map((row) => withFixtureClocks(row)),
          ...restrictedFrihet,
        ],
      };
    },

    'frihet.get': (input) => {
      const { id } = (input ?? {}) as { id?: number };
      const row = frihetsberovanden.find((entry) => entry.id === id);

      if (!row) return refuse('not_found');

      const now = Date.now();

      return {
        frihetsberovande: withFixtureClocks(row),
        brott: row.brott,
        straffskala: row.brott.length > 0 ? { boter: false, min: 6, max: 72 } : null,
        log: row.log.map((entry) => ({
          id: entry.id,
          kind: entry.kind,
          note: entry.note,
          loggedByCallsign: entry.loggedByCallsign,
          loggedByName: entry.loggedByName,
          loggedAt: new Date(now - entry.loggedAgo * 1000).toISOString(),
        })),
      };
    },

    'frihet.gripande': (input) => {
      const { personId, grund, plats } = (input ?? {}) as {
        personId?: number;
        grund?: string;
        plats?: string;
      };

      if (!personId) return refuse('invalid', { personId: 'required' });
      if (!grund) return refuse('invalid', { grund: 'required' });

      const id = frihetsberovanden.length + 1;
      const number = `A26-000${41 + id}`;

      frihetsberovanden.unshift({
        id,
        number,
        status: 'gripen',
        personId,
        personNumber: `P-00${1000 + personId}`,
        gripandeGrund: grund,
        // Omitted rather than set to undefined: `exactOptionalPropertyTypes`
        // distinguishes the two, and so does the server — the column is
        // nullable and an arrest with no place recorded is a real state.
        ...(plats ? { gripandePlats: plats } : {}),
        version: 1,
        gripenAgo: 0,
        gripenBy: FIXTURE_VIEWER,
        brott: [],
        log: [],
      });

      // 7.13's auto-resolve: a gripande is what an efterlysning existed to
      // produce, and the server takes every live one on the person down. The
      // fixture does the same, or the next query would still raise a "detain
      // on sight" banner for somebody already in a cell.
      for (const notice of efterlysningar) {
        if (notice.personId === personId && notice.cancelledAgo === undefined) {
          notice.cancelledAgo = 0;
          notice.cancelledGrund = 'gripen';
          notice.version += 1;
        }
      }

      return { id, number };
    },

    'frihet.anhallande': (input) => decideFrihet(input, 'anhallande'),
    'frihet.framstallan': (input) => decideFrihet(input, 'framstallan'),
    'frihet.haktning': (input) => decideFrihet(input, 'haktning'),
    'frihet.frigiv': (input) => decideFrihet(input, 'frigiv'),

    'frihet.underratta': (input) => {
      const { id } = (input ?? {}) as { id?: number };
      const row = frihetsberovanden.find((entry) => entry.id === id);

      if (!row) return refuse('not_found');

      // Written once (RB 24:9). A second press is not an error and does not
      // move the timestamp: the question asked later is when they were *first*
      // told.
      if (row.underrattadAgo !== undefined) return { id: row.id, alreadyRecorded: true };

      row.underrattadAgo = 0;

      return { id: row.id };
    },

    'frihet.log.add': (input) => {
      const { id, kind, note } = (input ?? {}) as {
        id?: number;
        kind?: string;
        note?: string;
      };

      const row = frihetsberovanden.find((entry) => entry.id === id);
      if (!row) return refuse('not_found');

      // Mirrors `Frihet.isLogKind`: a key under the module's prefix, never
      // prose. `t()` prints an unknown key verbatim, so a free string here
      // reached a custody record as a label.
      if (!/^frihet\.logKind\.[a-z][a-z0-9_]*$/.test(kind ?? '')) {
        return refuse('invalid', { kind: 'not_a_key' });
      }

      row.log = [
        {
          id: 900 + row.log.length,
          kind: kind ?? 'frihet.logKind.annan',
          note: note ?? null,
          loggedByCallsign: '1-ADAM-12',
          loggedByName: 'Berg',
          loggedAgo: 0,
        },
        ...row.log,
      ];

      return { id: row.id };
    },

    // ------------------------------------------------------ brottskatalogen

    'brott.list': () => ({ brott: brottskatalog.map(brottRow) }),

    'brott.versions': (input) => {
      const { code } = (input ?? {}) as { code?: string };

      const rows = [...brottskatalog, ...supersededBrott]
        .filter((row) => row.code === code)
        .sort((left, right) => right.version - left.version);

      if (rows.length === 0) return refuse('not_found');

      return { versions: rows.map(brottRow) };
    },

    'brott.straffskala': (input) => {
      const { brottIds } = (input ?? {}) as { brottIds?: string[] };

      if (!brottIds || brottIds.length === 0) {
        return refuse('invalid', { brottIds: 'empty' });
      }

      // One row per *count*, duplicates kept: BrB 26:2 is computed over counts
      // rather than over distinct offences.
      const rows = brottIds.map((id) => brottskatalog.find((row) => row.id === Number(id)));

      if (rows.some((row) => row === undefined)) {
        return refuse('not_found', { brottIds: 'unknown' });
      }

      const found = rows as FixtureBrott[];

      return { straffskala: gemensamStraffskala(found), brott: found.map(brottRow) };
    },

    // ------------------------------------------------------ förundersökning

    'fu.list': (input) => {
      const filter = (input ?? {}) as { status?: string; mine?: boolean };

      const found = forundersokningar.filter(
        (row) =>
          (!filter.status || row.status === filter.status) &&
          (!filter.mine || row.fuLedare === FIXTURE_VIEWER),
      );

      return { forundersokningar: [...found.map(fuRow), ...restrictedFu] };
    },

    'fu.get': (input) => {
      const { id } = (input ?? {}) as { id?: number };
      const row = forundersokningar.find((entry) => entry.id === id);

      if (!row) return refuse('not_found');

      return {
        fu: fuRow(row),
        anmalningar: anmalningar
          .filter((report) => row.anmalanIds.includes(report.id))
          .map((report) => ({
            id: report.id,
            number: report.number,
            title: report.title,
            status: report.status,
          })),
      };
    },

    'fu.create': (input) => {
      const { title, ledareKind } = (input ?? {}) as { title?: string; ledareKind?: string };

      if (!title?.trim()) return refuse('invalid', { title: 'required' });

      const id = forundersokningar.length + 1;
      const number = `FU26-000${31 + id}`;

      forundersokningar.unshift({
        id,
        number,
        title,
        status: 'inledd',
        fuLedare: FIXTURE_VIEWER,
        ledareKind: ledareKind ?? 'polis',
        openedAt: new Date().toISOString(),
        closedAt: null,
        closedReason: null,
        closedNote: null,
        version: 1,
        anmalanIds: [],
      });

      return { id, number };
    },

    'fu.assign': (input) => {
      const { id, version, fuLedare, ledareKind } = (input ?? {}) as {
        id?: number;
        version?: number;
        fuLedare?: string;
        ledareKind?: string;
      };

      const row = forundersokningar.find((entry) => entry.id === id);

      if (!row) return refuse('not_found');
      if (row.version !== version) return refuse('conflict', { version: 'stale' });

      row.fuLedare = fuLedare ?? row.fuLedare;
      row.ledareKind = ledareKind ?? row.ledareKind;
      row.version += 1;

      return { id: row.id };
    },

    'fu.slutdelge': (input) => decideFu(input, 'slutdelge'),
    'fu.redovisa': (input) => decideFu(input, 'redovisa'),
    'fu.lagg_ned': (input) => decideFu(input, 'lagg_ned'),

    // --------------------------------------------------- the unified query

    'query.run': (input) => {
      const { term, type, reason, caseNumber } = (input ?? {}) as {
        term?: string;
        type?: string;
        reason?: string;
        caseNumber?: string;
      };

      if (!term || term.trim().length < 2) return refuse('invalid', { term: 'too_short' });

      const plan = planQuery(term, type);
      const results: Record<string, unknown>[] = [];

      if (plan.sources.includes('person')) {
        for (const entry of matches(registerPersons, term)) {
          const row = entry.row as unknown as Record<string, unknown> & { id?: number };

          // A stub passes through as it is: no id, no name, no hits (4.5).
          results.push(
            row.id === undefined
              ? row
              : { ...row, kind: 'person', score: 3, hits: queryHits[`person:${row.id}`] ?? [] },
          );
        }
      }

      if (plan.sources.includes('vehicle')) {
        for (const entry of matches(registerVehicles, term)) {
          const row = entry.row as unknown as Record<string, unknown> & {
            id?: number;
            hits?: string[];
          };

          results.push(
            row.id === undefined
              ? row
              : {
                  ...row,
                  kind: 'vehicle',
                  score: 2,
                  // The register's own `hits` is a list of flag *kinds*; the
                  // query sends hit rows. Shaped here the way the server
                  // shapes them rather than passed through.
                  hits: (row.hits ?? []).map((kind, index) => ({
                    hitType: 'vehicle_flag',
                    hitId: 500 + index,
                    kind,
                    recordType: 'vehicle',
                    recordId: row.id as number,
                    confirmed: false,
                  })),
                },
          );
        }
      }

      const hits = results.reduce<number>(
        (total, row) => total + ((row.hits as unknown[] | undefined)?.length ?? 0),
        0,
      );

      // 7.2: a query that reaches a restricted record needs a reason or a case
      // number, and the refusal happens before anything is returned — so the
      // officer learns nothing, not even that there was something worth a
      // reason. The fixture's restricted row is the third Doe.
      const reachesRestricted = results.some((row) => row.restricted === true);

      if (reachesRestricted && !reason?.trim() && !caseNumber?.trim()) {
        return refuse('invalid', { reason: 'required' });
      }

      nextQueryId += 1;

      queryLog.unshift({
        id: nextQueryId,
        queryType: plan.type,
        term,
        accessPoint: null,
        restricted: reachesRestricted,
        resultCount: results.length,
        hitCount: hits,
        confirmationCount: 0,
        confirmedCount: 0,
        reason: reason?.trim() || null,
        caseNumber: caseNumber?.trim() || null,
        createdAt: new Date().toISOString(),
      });

      return {
        queryId: nextQueryId,
        type: plan.type,
        derived: type === undefined,
        sources: plan.sources,
        results,
        hits,
      };
    },

    'query.hit.confirm': (input) => {
      const { queryId, hitType, hitId, outcome, caseNumber, detail } = (input ?? {}) as {
        queryId?: number;
        hitType?: string;
        hitId?: number;
        outcome?: string;
        caseNumber?: string;
        detail?: string;
      };

      if (!hitType || !hitId) return refuse('invalid', { hitId: 'required' });
      if (!outcome || !['confirmed', 'not_confirmed', 'unable'].includes(outcome)) {
        return refuse('invalid', { outcome: 'not_allowed' });
      }

      // `Query.validateConfirm`: "it came back confirmed" is not an answer to
      // "confirmed against what?".
      if (outcome === 'confirmed' && !detail?.trim() && !caseNumber?.trim()) {
        return refuse('invalid', { detail: 'required' });
      }

      for (const list of Object.values(queryHits)) {
        for (const hit of list) {
          if (hit.hitType === hitType && hit.hitId === hitId) hit.confirmed = true;
        }
      }

      const entry = queryLog.find((row) => row.id === queryId);

      if (entry) {
        entry.confirmationCount += 1;
        if (outcome === 'confirmed') entry.confirmedCount += 1;
      }

      return { id: hitId };
    },

    'query.log': (input) => {
      const { limit } = (input ?? {}) as { mine?: boolean; limit?: number };

      // `mine` is decided on the server from the session and never from the
      // input, so the fixture has one officer's log and no way to ask for
      // somebody else's.
      return { entries: queryLog.slice(0, limit ?? 50) };
    },

    // --------------------------------------------------------- tvångsmedel

    'tvang.list': (input) => {
      const filter = (input ?? {}) as { kind?: string; liveOnly?: boolean };

      const found = tvangsmedel.filter(
        (row) =>
          (!filter.kind || row.kind === filter.kind) &&
          (!filter.liveOnly || tvangLiveness(row).live),
      );

      return {
        tvangsmedel: [...found.map((row) => tvangRow(row, false)), ...restrictedTvang],
      };
    },

    'tvang.get': (input) => {
      const { id } = (input ?? {}) as { id?: number };
      const row = tvangsmedel.find((entry) => entry.id === id);

      if (!row) return refuse('not_found');

      return { tvangsmedel: tvangRow(row, true) };
    },

    'tvang.decide': (input) => {
      const measure = (input ?? {}) as {
        kind?: string;
        targetKind?: string;
        targetId?: number;
        targetLabel?: string;
        grund?: string;
        scope?: string;
        validSeconds?: number;
      };

      if (!measure.kind) return refuse('invalid', { kind: 'unknown' });
      if (!measure.targetId) return refuse('invalid', { targetId: 'required' });
      if (!measure.grund) return refuse('invalid', { grund: 'required' });

      // `Tvang.validate`'s two target rules. The screen does not offer the
      // combinations that trip these, and the server refuses them anyway.
      const entersPlace =
        measure.kind === 'husrannsakan_reell' || measure.kind === 'husrannsakan_personell';

      if (entersPlace && measure.targetKind === 'person') {
        return refuse('invalid', { targetKind: 'not_a_place' });
      }

      if (
        (measure.kind === 'kroppsvisitation' || measure.kind === 'kroppsbesiktning') &&
        measure.targetKind !== 'person'
      ) {
        return refuse('invalid', { targetKind: 'not_a_person' });
      }

      // The capacity rule. A kroppsbesiktning needs at least a prosecutor,
      // and this viewer is an investigation leader — so the screen has to
      // draw "that decision is not yours to take" rather than a role problem.
      if (!(TVANG_ALLOWED[FIXTURE_TVANG_CAPACITY] ?? []).includes(measure.kind)) {
        return refuse('forbidden', { kind: 'wrong_capacity' });
      }

      const id = tvangsmedel.length + 1;
      const validSeconds = measure.validSeconds ?? 7 * DAY;

      tvangsmedel.unshift({
        id,
        number: `W26-001${20 + id}`,
        kind: measure.kind,
        targetKind: measure.targetKind ?? 'address',
        targetId: measure.targetId,
        targetLabel: measure.targetLabel ?? null,
        fuId: null,
        deciderKind: FIXTURE_TVANG_CAPACITY,
        grund: measure.grund,
        scope: measure.scope ?? null,
        validFromAgo: 0,
        validUntilAgo: -validSeconds,
        version: 1,
      });

      return { id, number: `W26-001${20 + id}` };
    },

    'tvang.verkstall': (input) => {
      const { id, note } = (input ?? {}) as { id?: number; note?: string };
      const row = tvangsmedel.find((entry) => entry.id === id);

      if (!row) return refuse('not_found');

      const { live, why } = tvangLiveness(row);
      if (!live) return refuse('conflict', { status: why ?? 'expired' });

      // Pressed twice is not an error: the first execution stays the recorded
      // one, exactly as `Repo.verkstall`'s `verkstalld_at IS NULL` decides.
      if (row.verkstalldAgo !== undefined) return { id: row.id, alreadyRecorded: true };

      row.verkstalldAgo = 0;
      row.verkstalldNote = note ?? null;
      row.version += 1;

      return { id: row.id };
    },

    'tvang.upphav': (input) => {
      const { id, version } = (input ?? {}) as { id?: number; version?: number };
      const row = tvangsmedel.find((entry) => entry.id === id);

      if (!row) return refuse('not_found');
      if (row.upphavdAgo !== undefined || row.version !== version) return refuse('conflict');

      row.upphavdAgo = 0;
      row.version += 1;

      return { id: row.id };
    },

    // -------------------------------------------------------- efterlysning

    'efterlysning.list': (input) => {
      const filter = (input ?? {}) as { grund?: string; includeCancelled?: boolean };

      const found = efterlysningar.filter(
        (row) =>
          (!filter.grund || row.grund === filter.grund) &&
          (filter.includeCancelled || row.cancelledAgo === undefined),
      );

      return {
        efterlysningar: [...found.map(efterlysningRow), ...restrictedEfterlysning],
      };
    },

    'efterlysning.create': (input) => {
      const notice = (input ?? {}) as {
        personId?: number;
        grund?: string;
        priority?: number;
        note?: string;
        expiresInSeconds?: number;
      };

      if (!notice.personId) return refuse('invalid', { personId: 'required' });
      if (!notice.grund) return refuse('invalid', { grund: 'required' });
      if (!DETAIN_ON_SIGHT.includes(notice.grund) && !['delgivning', 'forsvunnen', 'oidentifierad', 'annan'].includes(notice.grund)) {
        return refuse('invalid', { grund: 'unknown' });
      }

      const id = efterlysningar.length + 1;

      const row: FixtureEfterlysning = {
        id,
        number: `W26-002${10 + id}`,
        personId: notice.personId,
        personNumber: `P-00${1000 + notice.personId}`,
        grund: notice.grund,
        note: notice.note ?? null,
        priority: notice.priority ?? 3,
        issuedAgo: 0,
        version: 1,
      };

      // Absent means it stands until lifted, so the field stays absent rather
      // than becoming a very distant expiry.
      if (notice.expiresInSeconds) row.expiresAgo = -notice.expiresInSeconds;

      efterlysningar.unshift(row);

      return { id, number: row.number };
    },

    'efterlysning.cancel': (input) => {
      const { id, version, grund } = (input ?? {}) as {
        id?: number;
        version?: number;
        grund?: string;
      };

      const row = efterlysningar.find((entry) => entry.id === id);

      if (!row) return refuse('not_found');
      if (row.cancelledAgo !== undefined || row.version !== version) return refuse('conflict');

      row.cancelledAgo = 0;
      row.cancelledGrund = grund ?? null;
      row.version += 1;

      return { id: row.id };
    },

    // ------------------------------------------------------------- spaning

    'spaning.list': (input) => {
      const filter = (input ?? {}) as { targetKind?: string; includeResolved?: boolean };

      const found = spaningsuppdrag.filter(
        (row) =>
          (!filter.targetKind || row.targetKind === filter.targetKind) &&
          (filter.includeResolved || (row.resolvedAgo === undefined && row.expiresAgo < 0)),
      );

      return {
        spaningsuppdrag: [...found.map(spaningRow), ...restrictedSpaning],
      };
    },

    'spaning.get': (input) => {
      const { id } = (input ?? {}) as { id?: number };
      const row = spaningsuppdrag.find((entry) => entry.id === id);

      if (!row) return refuse('not_found');

      return { spaning: spaningRow(row) };
    },

    'spaning.create': (input) => {
      const lookout = (input ?? {}) as {
        targetKind?: string;
        targetId?: number;
        description?: string;
        grund?: string;
        priority?: number;
        areaNote?: string;
        validSeconds?: number;
      };

      if (!lookout.grund) return refuse('invalid', { grund: 'required' });

      // `Spaning.validate`: a lookout has to be for something, and `other`
      // names no record so it takes no id.
      if (!lookout.targetId && !lookout.description?.trim()) {
        return refuse('invalid', { description: 'required_without_target' });
      }

      if (lookout.targetKind === 'other' && lookout.targetId) {
        return refuse('invalid', { targetId: 'not_allowed' });
      }

      const id = spaningsuppdrag.length + 1;

      spaningsuppdrag.unshift({
        id,
        number: `S26-000${50 + id}`,
        targetKind: lookout.targetKind ?? 'other',
        targetId: lookout.targetId ?? null,
        description: lookout.description ?? null,
        grund: lookout.grund,
        priority: lookout.priority ?? 3,
        areaNote: lookout.areaNote ?? null,
        issuedAgo: 0,
        expiresAgo: -(lookout.validSeconds ?? 7 * DAY),
        version: 1,
      });

      return { id, number: `S26-000${50 + id}` };
    },

    'spaning.resolve': (input) => {
      const { id, version, grund } = (input ?? {}) as {
        id?: number;
        version?: number;
        grund?: string;
      };

      const row = spaningsuppdrag.find((entry) => entry.id === id);

      if (!row) return refuse('not_found');
      if (row.resolvedAgo !== undefined || row.version !== version) return refuse('conflict');

      row.resolvedAgo = 0;
      row.resolvedGrund = grund ?? null;
      row.version += 1;

      return { id: row.id };
    },

    // ------------------------------------------------------------- anmälan

    /**
     * The report workflow (spec 7.7).
     *
     * Three rows covering the three states the screen draws differently: a
     * draft the viewer wrote, one submitted by somebody else (so it can be
     * approved), and one the viewer submitted themselves -- the case that must
     * NOT be approvable, and the one the screen explains before the button is
     * pressed rather than after.
     */
    'anmalan.list': (input) => {
      const filter = (input ?? {}) as { status?: string; mine?: boolean };

      const found = anmalningar.filter(
        (row) =>
          (!filter.status || row.status === filter.status) &&
          (!filter.mine || row.createdBy === FIXTURE_VIEWER),
      );

      return {
        anmalningar: [
          ...found.map(({ brott: _brott, personer: _personer, ...row }) => row),
          // Appended rather than interleaved so the readable rows keep stable
          // positions in the tests that click them.
          ...restrictedAnmalningar,
        ],
      };
    },

    'anmalan.get': (input) => {
      const { id } = (input ?? {}) as { id?: number };
      const row = anmalningar.find((entry) => entry.id === id);

      if (!row) return refuse('not_found');

      const { brott, personer, ...anmalan } = row;

      // `may` is the server's answer rather than the screen's inference -- see
      // the route. `ownReport` is what makes the own-approval note render.
      const ownReport = row.createdBy === FIXTURE_VIEWER;

      return {
        anmalan,
        brott,
        personer,
        supplements: [],
        straffskala: brott.length > 0 ? { boter: false, min: 0, max: 36 } : null,
        aklagareIndicated: brott.length > 0,
        may: {
          approve: row.status === 'inlamnad' && !ownReport,
          submit: row.status === 'utkast' || row.status === 'atersand',
          edit: row.status === 'utkast' || row.status === 'atersand',
          ownReport,
        },
      };
    },

    'anmalan.submit': (input) => moveAnmalan(input, 'inlamnad'),
    'anmalan.approve': (input) => moveAnmalan(input, 'godkand'),
    'anmalan.atersand': (input) => moveAnmalan(input, 'atersand'),

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
        // Whether this card may offer 7.16's supervisor sign-off, decided here
        // and not on the card. Sent on every call and not only on a panic, the
        // way the route sends it: a field that appeared and vanished with the
        // call's source would have the card reasoning about why it is missing,
        // and absent already means something — no.
        mayAcknowledge: mayAcknowledge(call),
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
      // `mayAcknowledge: true`, or open call 4, which is seeded as one.
      // `tests/emergency.spec.ts` covers both, on the banner and on the card.
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
