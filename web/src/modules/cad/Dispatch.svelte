<script module lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';

  /**
   * The dispatch console (spec 7.16, 7.17).
   *
   * This module script holds three things the whole console shares: the
   * placement it was opened from, the shapes the CAD routes answer with, and
   * the handful of formatters every screen needs. They live here rather than in
   * a file of their own because a type that is only ever a prop belongs beside
   * the component that hands it over.
   *
   * ## The placement (spec 3.10, ADR-006)
   *
   * `call.create` and `call.dispatch` carry
   * `context = { accessPoint = 'dispatch_console' }`, so both take the id of
   * the console the dispatcher is standing at and the server then checks they
   * really are standing there. Nothing else in dispatch is pinned: an officer
   * in a car is not at a console, and pinning the field routes would refuse
   * exactly the person they were written for.
   *
   * It is captured in module scope, as the property room terminal is, because
   * the game pushes `fredpd:open` once at the moment the console is opened,
   * while this component exists only while Dispatch is the module on screen. A
   * dispatcher who opens the console and then picks another rail entry and
   * comes back would otherwise mount after the message and never see it.
   *
   * The id is a *claim*, never a grant: naming a console you are not at is
   * refused on the server (invariant 4).
   */
  let openedAt: number | null = null;

  nui.on('fredpd:open', (message) => {
    openedAt = typeof message['placementId'] === 'number' ? message['placementId'] : null;
  });

  nui.on('fredpd:close', () => {
    openedAt = null;
  });

  /** The console this session is standing at, or null for an MDT in a car. */
  export function consolePlacement(): number | null {
    return openedAt;
  }

  // ---------------------------------------------------------------- shapes

  /**
   * A call, as `Repo.getCall` and `Repo.listCalls` return one.
   *
   * `receivedAtUnix` is beside `receivedAt` on purpose: the queue's age and the
   * board's time in status are arithmetic, and epoch seconds are the only form
   * of a timestamp that is the same number on the server and in the browser
   * whatever time zone the database is running in.
   */
  export interface Call {
    id: number;
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
    /** Only on a list row: the units live on the call right now. */
    unitCount?: number;
  }

  /**
   * One assignment. `active` is 1 while the unit is on the call and null once
   * it has left — the closed rows come back too, because "who was sent" is one
   * of the questions a call is read back to answer.
   */
  export interface CallUnit {
    id: number;
    officerId: number;
    callsign: string;
    isLead: number | null;
    joinedAt: string;
    leftAt: string | null;
    active: number | null;
  }

  /**
   * A line of the narrative log (7.16.1).
   *
   * Two kinds, and only ever one of them: a note carries `body`, which is what
   * a person typed and is never translated, and everything else carries
   * `messageKey` plus its arguments so the line reads in the *reader's*
   * language.
   *
   * The arguments arrive under two different names, which is not a mistake in
   * either place: `call.get` returns the `message_args` column as `messageArgs`,
   * while the `fredpd:cad:log` push sends the entry in the shape the repo takes
   * it in, where the field is `args`. A card that read only one of them would
   * render a status change as a bare "{callsign}: {status}." for as long as it
   * stayed open, and would look correct again on the next refresh.
   */
  export interface LogEntry {
    id?: number;
    entryType: string;
    body: string | null;
    messageKey: string | null;
    messageArgs?: Record<string, string | number> | null;
    args?: Record<string, string | number> | null;
    callsign: string | null;
    createdAt?: string;
    createdAtUnix?: number;
  }

  /** A person or a vehicle attached to the call (7.16). */
  export interface CallLink {
    id: number;
    targetType: string;
    targetId: number;
    role: string;
    label: string;
    detail: string | null;
    createdAt: string;
  }

  /**
   * One of the closest available units (7.16 "recommend closest available
   * units"), as `Cad.recommendUnits` ranks them.
   */
  export interface Recommendation {
    officerId: number;
    callsign: string;
    status: string;
    distance: number;
    stale: boolean;
    /** Set when this unit would have to be pulled off a lower-priority call. */
    divertFromCallId?: number | null;
  }

  /**
   * What `call.get` answers.
   *
   * `recommended` is **absent** for a session that may not dispatch, and for a
   * call with no coordinates — a call taken over the phone that the caller
   * could only describe has nothing to measure a distance from. Absent and
   * empty are different answers and the card draws them differently: no panel
   * at all, against a panel that says no unit can be recommended.
   *
   * `mayAcknowledge` is the same arrangement for 7.16's supervisor sign-off,
   * and it is on the card because the banner's flag was not enough. The banner
   * and the card carry the identical button, the banner's own Respond opens the
   * card, and the card is drawn to every session holding `page.dispatch` —
   * which is `patrol_basic` upwards — while `call.acknowledge` is gated on
   * `cad.unit.manage` and refuses the officer named in `created_by`. So a
   * patrol officer who pressed Respond on a colleague's panic met the button
   * the banner had correctly withheld one component earlier, directly above the
   * line telling them the call cannot be cleared until somebody acknowledges
   * it. Pressing it answered `forbidden` with no field, so there was nothing to
   * read, and wrote an `audit.denied` row against them — in a log that is
   * append-only (invariant 11), so it cannot be taken back out.
   *
   * Optional because absent must read as no: see `CallCard`'s `=== true`.
   */
  export interface CallCardData {
    id: number;
    call: Call;
    units: CallUnit[];
    log: LogEntry[];
    links: CallLink[];
    recommended?: Recommendation[] | null;
    mayAcknowledge?: boolean;
    /** Standing premise hazards at the call (7.6), for this reader. */
    hazards?: PremiseHazards[];
  }

  /** The hazards on one premise the call is at. */
  export interface PremiseHazards {
    locationId: number;
    label: string;
    hazards: { kind: string; note?: string | null }[];
  }

  /** A row of the unit board, with whatever call it is on joined on. */
  export interface Unit {
    officerId: number;
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

  /**
   * One row per unit, which is what a board is.
   *
   * `Repo.listUnits` joins `fpd_call_units` on `active = 1`, and
   * `uq_fpd_call_units_live` is `(call_id, discord_id, active)` — per *call*.
   * A unit that is live on two calls at once is therefore a legal database
   * state and comes back as two rows for one unit: the emergency button
   * attaches an officer to the panic call without releasing whatever they were
   * already on, and `call.dispatch` only checks that a unit is not already on
   * *this* call. A keyed `{#each}` over that throws, which would take the whole
   * console down at the moment an officer pressed the button.
   *
   * The first row wins, so the board keeps the assignment the unit has held
   * longest rather than flickering between two. The milestone report asks for
   * the server-side fix; this is what stops it being a crash in the meantime.
   */
  export function oneRowPerUnit(rows: Unit[]): Unit[] {
    return rows.filter(
      (row, index) => rows.findIndex((other) => other.officerId === row.officerId) === index,
    );
  }

  /** A beat or district polygon (7.17). `polygon` is `[[x, y], …]`. */
  export interface Beat {
    id: number;
    code: string;
    labelKey: string;
    kind: string;
    polygon: [number, number][];
    minX: number;
    minY: number;
    maxX: number;
    maxY: number;
  }

  /** A message out on the air (7.16 [S]). */
  export interface Broadcast {
    id: number;
    kind: string;
    priority: number;
    title: string;
    body: string;
    plate: string | null;
    callId: number | null;
    expiresAt: string | null;
    cancelledAt: string | null;
    createdAt?: string;
  }

  /** A unit dispatch has been asked to check on (7.16 status timers). */
  export interface WelfarePrompt {
    officerId: number;
    callsign: string;
    callId: number | null;
    callNumber: string | null;
    status: string;
    minutes: number;
  }

  // ------------------------------------------------------------ formatting

  /**
   * Which form label a rejected field belongs to.
   *
   * Shared by every screen in the module, because the routes share fields: a
   * `status` refused by `unit.status` and one refused by `call.status` are the
   * same word on two forms, and one map means the two cannot describe it
   * differently.
   */
  export const FIELD_LABELS: Record<string, string> = {
    placementId: 'placement.dispatch_console',
    callId: 'cad.column.number',
    id: 'cad.column.number',
    officerId: 'cad.manage.unit',
    officerIds: 'cad.dispatch.units',
    removeOfficerIds: 'cad.dispatch.units',
    leadOfficerId: 'cad.dispatch.lead',
    type: 'cad.create.type',
    priority: 'cad.create.priority',
    locationText: 'cad.create.location',
    beatId: 'cad.create.beat',
    callerName: 'cad.create.callerName',
    callerPhone: 'cad.create.callerPhone',
    details: 'cad.create.details',
    status: 'cad.column.status',
    disposition: 'cad.clear.disposition',
    // The link picker on the call card (7.16). `targetId` is the register row
    // `call.link` refuses as `unknown` — which is both "no such record" and
    // "not yours to read", deliberately one answer — and `term` is the box the
    // two search routes refuse as `too_short`. Without these two the officer
    // would be told "targetId — unknown" over a form that has no such box.
    targetId: 'cad.card.links',
    role: 'cad.card.links',
    term: 'records.search.term',
    note: 'cad.clear.note',
    body: 'cad.broadcast.body',
    callsign: 'cad.manage.callsign',
    reason: 'cad.manage.reason',
    kind: 'cad.broadcast.kind',
    title: 'cad.broadcast.headline',
    plate: 'cad.broadcast.plate',
    expiresInMinutes: 'cad.broadcast.expiresIn',
  };

  const PRIORITY_LABELS: Record<number, string> = {
    1: 'cad.priority.p1',
    2: 'cad.priority.p2',
    3: 'cad.priority.p3',
    4: 'cad.priority.p4',
  };

  const PRIORITY_SHORT: Record<number, string> = {
    1: 'cad.priorityShort.p1',
    2: 'cad.priorityShort.p2',
    3: 'cad.priorityShort.p3',
    4: 'cad.priorityShort.p4',
  };

  /** "P1", and the sentence behind it for the tooltip and the screen reader. */
  export function priorityShort(priority: number): string {
    return t(PRIORITY_SHORT[priority] ?? 'cad.priorityShort.p3');
  }

  export function priorityLabel(priority: number): string {
    return t(PRIORITY_LABELS[priority] ?? 'cad.priority.p3');
  }

  /**
   * How a priority is told apart without colour (6.7: no meaning by colour
   * alone).
   *
   * The left rule differs in weight *and* in style — solid, solid, plain,
   * dashed — so the four are distinguishable on a monochrome screen and to a
   * reader who cannot tell red from amber, and the `P1`–`P4` label is there in
   * words besides.
   */
  export function priorityRule(priority: number): string {
    if (priority === 1) return 'border-l-8 border-l-[var(--color-alert)]';
    if (priority === 2) return 'border-l-4 border-l-[var(--color-caution)]';
    if (priority === 3) return 'border-l-2 border-l-[var(--color-ink-muted)]';

    return 'border-l-2 border-l-[var(--color-border)] border-dashed';
  }

  /** The ink a priority is written in. Never the only signal (see above). */
  export function priorityInk(priority: number): string {
    if (priority === 1) return 'text-[var(--color-alert)]';
    if (priority === 2) return 'text-[var(--color-caution)]';

    return 'text-[var(--color-ink)]';
  }

  function pad(value: number): string {
    return value < 10 ? `0${value}` : String(value);
  }

  /**
   * How long ago, as a running clock.
   *
   * Digits and colons only, so it carries no language of its own and needs no
   * locale key — the sentence around it (`cad.queue.waiting`,
   * `cad.board.inStatus`) is what is translated.
   *
   * `from` is epoch seconds from the server; `now` is the browser clock in
   * milliseconds, ticking once a second. Clamped at zero, because the two
   * clocks are not the same clock and a call must never be shown as arriving
   * in the future.
   */
  export function elapsed(from: number | null | undefined, now: number): string {
    if (typeof from !== 'number' || !Number.isFinite(from)) return '';

    const total = Math.max(0, Math.floor(now / 1000) - Math.floor(from));
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);

    if (hours > 0) return `${hours}:${pad(minutes)}:${pad(total % 60)}`;

    return `${minutes}:${pad(total % 60)}`;
  }

  /** A server timestamp as a wall clock. A dispatcher reads times, not dates. */
  export function clockOf(value: string | null | undefined): string {
    if (!value) return '';

    return value.replace('T', ' ').slice(11, 16);
  }

  /** A server timestamp with its date, for the timestamps a card is read for. */
  export function stamp(value: string | null | undefined): string {
    if (!value) return '';

    return value.replace('T', ' ').slice(0, 16);
  }

  /**
   * A beat as it is written on a card: its code, and the agency's own name for
   * it.
   *
   * `fpd_beats.label_key` is a locale key the *agency* owns — the districts a
   * server draws are its own, and their names are in its own locale file
   * rather than in FredPD's. An unknown key renders as itself (`lib/i18n`), so
   * a server that has drawn a beat and not named it would otherwise put
   * `beat.downtown` on a call card. The code alone is the honest fallback:
   * every beat has one, and it is what goes out over the radio anyway.
   */
  export function beatName(beat: Beat): string {
    const label = t(beat.labelKey);

    return label === beat.labelKey ? beat.code : `${beat.code} ${label}`;
  }

  export function beatLabel(beats: Beat[], beatId: number | null | undefined): string {
    if (beatId == null) return t('cad.beat.none');

    const beat = beats.find((candidate) => candidate.id === beatId);
    if (!beat) return t('cad.beat.none');

    return beatName(beat);
  }
</script>

<script lang="ts">
  import type { ErrorCode } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import { onPush } from './push';
  import { onIntent, peekIntent, takeIntent } from '../../lib/intent';
  import CallQueue from './CallQueue.svelte';
  import CallCard from './CallCard.svelte';
  import UnitBoard from './UnitBoard.svelte';
  import Broadcasts from './Broadcasts.svelte';

  /**
   * Dispatch (spec 7.16, 7.17).
   *
   * Four screens over one live picture: the pending queue beside the card of
   * the call that is open, the unit board, the map, and the broadcast board.
   *
   * **The data is live rather than polled.** Every route that writes anything
   * to a call sends `fredpd:cad:call`, and the server sends it only to the
   * sessions that may read that call — a push is a read nobody asked for
   * (invariants 4 and 5). So this component subscribes once, keeps the queue
   * and the board in step from the pushes, and refetches the open card when the
   * push says the call it is showing has changed. Budget 12.1 is the reason it
   * is not a timer: two hundred players with a console open is two hundred
   * queue reads a second, and the only thing a poll would add is latency.
   *
   * **Nothing here decides what may be done.** Every action is drawn for
   * everybody and refused by the server, which answers with a field code the
   * card reads out (`no_unit`, `off_duty`, `already_assigned`,
   * `needs_acknowledgement`). Hiding a button would be a second access control
   * in the one place it cannot be enforced (invariant 4).
   *
   * The officer-down banner is the one exception, and it is not this screen
   * deciding anything — it is this screen drawing the answer the server already
   * sent. See `emergencies` below: `unit.emergency` pushes `mayAcknowledge`
   * per recipient, because the tone deliberately reaches officers who cannot
   * hold `cad.unit.manage` and a button that can only ever be refused is not an
   * action, it is a dead end that writes an `audit.denied` row per press.
   */

  type Tab = 'queue' | 'board' | 'map' | 'alpr' | 'broadcasts';

  const TABS: Tab[] = ['queue', 'board', 'map', 'alpr', 'broadcasts'];

  let tab = $state<Tab>('queue');

  let calls = $state<Call[]>([]);
  let units = $state<Unit[]>([]);
  let beats = $state<Beat[]>([]);

  let selectedId = $state<number | null>(null);
  let card = $state<CallCardData | null>(null);
  let cardError = $state<ErrorCode | null>(null);
  let cardLoading = $state(false);

  let error = $state<ErrorCode | null>(null);
  let loading = $state(true);

  interface QueueFilter {
    status: string;
    priority: string;
    beatId: string;
    mine: boolean;
  }

  /** The queue as it is read before anybody narrows it: everything still open. */
  const WHOLE_QUEUE: QueueFilter = { status: '', priority: '', beatId: '', mine: false };

  /** The filter the queue was last asked for, so a refresh keeps it. */
  let queryFilter = $state<QueueFilter>({ ...WHOLE_QUEUE });

  /**
   * The officer emergencies this session has been told about (7.16).
   *
   * Only the sessions the server chose are in this list at all: dispatchers and
   * supervisors wherever they are, and the units close enough to get there,
   * with the distance measured server-side off each recipient's own ped. The
   * banner stays up until the call is acknowledged or closed, because a tone
   * that can be clicked away is a tone nobody hears twice.
   *
   * `mayAcknowledge` is the server's own answer for *this* recipient, and it is
   * why the two buttons on the banner are not drawn alike. Respond is for
   * everybody — an officer 200 m from a panic running to it is the entire point
   * of the range test. Acknowledge is `call.acknowledge`, gated on
   * `cad.unit.manage` and refused to the officer who pressed the button in the
   * first place, so most of the people this tone reaches can never give it.
   * Drawing it for them meant a banner whose only button answered `forbidden`
   * with no field reason — and because the banner clears on `acknowledgedAt` or
   * a terminal status and on nothing else, it then sat there for the rest of
   * the incident while every press wrote an `audit.denied` row against an
   * officer who had done nothing wrong.
   *
   * A missing flag is false, not true. Invariant 4 says the UI is never the
   * access control, so the failure this defaults away from is the UI offering
   * something the server never authorised; the safe default is the one that
   * draws less. An older server that has not learned to send the field yet
   * costs a supervisor one extra click through the call card, which is the
   * cheap half of being wrong.
   */
  let emergencies = $state<{ call: Call; callsign: string; mayAcknowledge: boolean }[]>([]);

  /** Units dispatch has been asked to check on (7.16 status timers). */
  let welfare = $state<WelfarePrompt[]>([]);

  /**
   * Why the acknowledgement on the banner was refused.
   *
   * It is drawn under the banner rather than sent to the card, because the
   * refusals this button meets are all about *who is pressing it*: a second
   * supervisor cannot overwrite the first one's name, and a session whose
   * Discord roles changed between the push and the press is answered
   * `forbidden` by a server that no longer agrees with the flag it sent. None
   * of it is anything the card could explain better, and a refusal with
   * nowhere to appear is the defect this console was told twice not to ship.
   *
   * The two refusals `mayAcknowledge` now keeps off the screen entirely are the
   * ones that used to be met constantly: a recipient without `cad.unit.manage`,
   * and the officer in distress being offered their own sign-off.
   */
  let emergencyFailure = $state<Failure | null>(null);

  /**
   * One clock for the whole console.
   *
   * The queue's age and the board's time in status are the two numbers a
   * dispatcher actually watches, and they have to move without a reload — but
   * they are the same second everywhere on the screen, so there is one timer
   * and not one per row.
   */
  let now = $state(Date.now());

  $effect(() => {
    const timer = setInterval(() => {
      now = Date.now();
    }, 1000);

    return () => clearInterval(timer);
  });

  /**
   * The queue.
   *
   * The filter is an argument rather than a read of the state above, and that
   * is what keeps the first load a *first* load: an effect that read
   * `queryFilter` would re-run on every change to it, and the Apply button
   * already reads the queue itself — two reads of a route with a ceiling of
   * sixty a minute (12.1).
   */
  async function loadCalls(filter: QueueFilter): Promise<void> {
    const response = await nui.call<{ calls: Call[] }>('call.list', {
      status: filter.status || undefined,
      priority: filter.priority ? Number(filter.priority) : undefined,
      beatId: filter.beatId ? Number(filter.beatId) : undefined,
      mine: filter.mine || undefined,
    });

    if (response.ok) {
      calls = response.data.calls;
      error = null;
    } else {
      error = response.err;
    }
  }

  async function loadUnits(): Promise<void> {
    const response = await nui.call<{ units: Unit[] }>('unit.list', {});

    if (response.ok) units = oneRowPerUnit(response.data.units);
    else error ??= response.err;
  }

  async function loadBeats(): Promise<void> {
    const response = await nui.call<{ beats: Beat[] }>('beat.list');

    if (response.ok) beats = response.data.beats;
  }

  async function loadCard(id: number | null): Promise<void> {
    if (id === null) {
      card = null;
      cardError = null;
      return;
    }

    cardLoading = true;

    const response = await nui.call<CallCardData>('call.get', { id });

    if (response.ok) {
      card = response.data;
      cardError = null;
    } else {
      // A card that cannot be read is not a blank pane: the call may have been
      // reclassified, or it may never have been this reader's to see, and
      // `not_found` covers both deliberately.
      card = null;
      cardError = response.err;
    }

    cardLoading = false;
  }

  /** Everything the console shows, after a write that could have moved any of it. */
  async function reload(): Promise<void> {
    await Promise.all([loadCalls(queryFilter), loadUnits(), loadCard(selectedId)]);
  }

  $effect(() => {
    void (async () => {
      await Promise.all([loadCalls(WHOLE_QUEUE), loadUnits(), loadBeats()]);
      loading = false;
    })();
  });

  $effect(() => {
    void loadCard(selectedId);
  });

  /**
   * Puts a call the server pushed into the queue in the right place.
   *
   * A closed call leaves the queue when the queue is what is being shown —
   * `queue_priority` goes NULL on the server for exactly these two statuses, so
   * the next read would not return it either. When a terminal status is being
   * reviewed on purpose, it stays.
   */
  function mergeCall(incoming: Call): void {
    const closed = incoming.status === 'cleared' || incoming.status === 'cancelled';
    const rest = calls.filter((existing) => existing.id !== incoming.id);

    if (closed && !queryFilter.status) {
      calls = rest;
      return;
    }

    const previous = calls.find((existing) => existing.id === incoming.id);

    // The push carries the row, not the list's derived `unitCount`; keeping the
    // count from the row it replaces is better than showing "no unit" on a call
    // that has three until the next full read.
    const unitCount = incoming.unitCount ?? previous?.unitCount;

    calls = [...rest, unitCount === undefined ? incoming : { ...incoming, unitCount }];
  }

  $effect(() =>
    onPush('fredpd:cad:call', (message) => {
      const incoming = message['call'] as Call | undefined;
      if (!incoming) return;

      mergeCall(incoming);

      if (incoming.id === selectedId) void loadCard(selectedId);

      // An emergency that has been acknowledged or closed stops shouting.
      emergencies = emergencies.filter(
        (banner) =>
          banner.call.id !== incoming.id ||
          (incoming.acknowledgedAt == null &&
            incoming.status !== 'cleared' &&
            incoming.status !== 'cancelled'),
      );
    }),
  );

  $effect(() =>
    onPush('fredpd:cad:log', (message) => {
      const callId = message['callId'];
      const entry = message['entry'] as LogEntry | undefined;

      if (!entry || callId !== selectedId || !card) return;

      // Appended rather than refetched: a long call's log is hundreds of lines
      // and the push carries the one that was just written.
      card = { ...card, log: [...card.log, entry] };
    }),
  );

  $effect(() =>
    onPush('fredpd:cad:unit', (message) => {
      const unit = message['unit'] as Unit | undefined;
      if (!unit) return;

      const rest = units.filter((existing) => existing.officerId !== unit.officerId);

      // A unit that has signed off leaves the board, which is who is working.
      units = unit.status === 'off_duty' ? rest : [...rest, unit];
    }),
  );

  $effect(() =>
    onPush('fredpd:cad:emergency', (message) => {
      const call = message['call'] as Call | undefined;
      const callsign = message['callsign'];

      if (!call) return;

      mergeCall(call);

      emergencies = [
        ...emergencies.filter((banner) => banner.call.id !== call.id),
        {
          call,
          callsign: typeof callsign === 'string' ? callsign : '',
          // Strictly `=== true`, so anything that is not the server's yes —
          // absent, null, a truthy string from a resource pushing its own
          // shape — is a no. See `emergencies` above for why that direction.
          mayAcknowledge: message['mayAcknowledge'] === true,
        },
      ];
    }),
  );

  $effect(() =>
    onPush('fredpd:cad:welfare', (message) => {
      const due = message['units'] as WelfarePrompt[] | undefined;
      if (!Array.isArray(due)) return;

      const incoming = due.filter(
        (prompt) => !welfare.some((shown) => shown.officerId === prompt.officerId),
      );

      welfare = [...welfare, ...incoming];
    }),
  );

  async function acknowledge(callId: number): Promise<void> {
    const response = await nui.call('call.acknowledge', { callId });

    if (response.ok) {
      emergencyFailure = null;
      emergencies = emergencies.filter((banner) => banner.call.id !== callId);
      await reload();
    } else {
      emergencyFailure = response;
    }
  }

  function respond(callId: number): void {
    selectedId = callId;
    tab = 'queue';
  }

  /** A hand-over to this screen (the overview's call rows): open that call's card. */
  function followIntent(): void {
    const intent = peekIntent();
    if (!intent || intent.module !== 'dispatch') return;
    takeIntent();
    if (intent.callId) respond(intent.callId);
  }

  followIntent();
  $effect(() => onIntent(followIntent));

  const emergencyMessages = $derived(fieldList(emergencyFailure, FIELD_LABELS));

  const queueCount = $derived(
    calls.filter((call) => call.status !== 'cleared' && call.status !== 'cancelled').length,
  );
</script>

<section class="flex min-h-0 flex-col gap-3">
  <header>
    <h1 class="text-base font-semibold">{t('cad.title')}</h1>
    <p class="mt-1 max-w-prose text-xs text-[var(--color-ink-muted)]">{t('cad.intro')}</p>
  </header>

  <!-- An officer down. Full width and unmissable (6.4: urgent events are a
       banner, never a toast), and it stays until the call is acknowledged or
       closed. -->
  {#each emergencies as banner (banner.call.id)}
    <div
      class="flex flex-wrap items-center gap-3 border-2 border-[var(--color-alert)] bg-[var(--color-panel)] px-3 py-2"
    >
      <span class="text-xs font-semibold tracking-wide text-[var(--color-alert)]">
        {t('cad.emergency.title')}
      </span>
      <span class="text-sm font-semibold">
        {banner.call.locationText
          ? t('cad.emergency.banner', {
              callsign: banner.callsign,
              location: banner.call.locationText,
            })
          : t('cad.emergency.bannerNoLocation', { callsign: banner.callsign })}
      </span>
      <span class="font-[family-name:var(--font-mono)] text-xs">{banner.call.callNumber}</span>

      <span class="ml-auto flex gap-2">
        <button
          type="button"
          class="border border-[var(--color-border)] px-3 py-1 text-xs hover:bg-[var(--color-surface)]"
          onclick={() => respond(banner.call.id)}
        >
          {t('cad.emergency.respond')}
        </button>
        <!-- Only for the recipients the server said may give it. Respond is
             drawn for everybody: the 800 m range test exists so the nearest
             car runs, and that car is usually a patrol unit who will never
             hold `cad.unit.manage`. -->
        {#if banner.mayAcknowledge}
          <button
            type="button"
            class="border border-[var(--color-alert)] px-3 py-1 text-xs font-semibold text-[var(--color-alert)] hover:bg-[var(--color-surface)]"
            onclick={() => void acknowledge(banner.call.id)}
          >
            {t('cad.emergency.acknowledge')}
          </button>
        {/if}
      </span>
    </div>
  {/each}

  {#if emergencyFailure}
    <div class="border border-[var(--color-alert)] px-3 py-1.5 text-xs">
      <p class="font-semibold">{t(`error.${emergencyFailure.err}`)}</p>
      {#each emergencyMessages as message (message.name)}
        <p class="text-[var(--color-alert)]">{message.label} — {message.reason}</p>
      {/each}
    </div>
  {/if}

  <!-- A unit that has been on scene too long with nothing said (7.16 status
       timers). The server decides who is asked; dispatch is told, the unit is
       not. -->
  {#each welfare as prompt (prompt.officerId)}
    <div
      class="flex flex-wrap items-center gap-3 border border-[var(--color-caution)] px-3 py-2 text-xs"
    >
      <span class="font-semibold text-[var(--color-caution)]">{t('cad.welfare.title')}</span>
      <span>
        {t('cad.welfare.body', {
          callsign: prompt.callsign,
          number: prompt.callNumber ?? '',
          minutes: prompt.minutes,
        })}
      </span>

      <span class="ml-auto flex gap-2">
        {#if prompt.callId != null}
          <button
            type="button"
            class="border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]"
            onclick={() => respond(prompt.callId as number)}
          >
            {t('cad.welfare.prompt')}
          </button>
        {/if}
        <button
          type="button"
          class="border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]"
          onclick={() =>
            (welfare = welfare.filter((shown) => shown.officerId !== prompt.officerId))}
        >
          {t('cad.welfare.dismiss')}
        </button>
      </span>
    </div>
  {/each}

  <nav class="flex gap-1 border-b border-[var(--color-border)]">
    {#each TABS as name (name)}
      <button
        type="button"
        class="border-b-2 px-3 py-1.5 text-xs"
        class:border-transparent={tab !== name}
        class:border-[var(--color-ink)]={tab === name}
        class:font-semibold={tab === name}
        onclick={() => (tab = name)}
      >
        {t(`cad.tab.${name}`)}
      </button>
    {/each}
  </nav>

  {#if error}
    <p class="border border-[var(--color-border)] px-3 py-2 text-sm">{t(`error.${error}`)}</p>
  {/if}

  {#if loading}
    <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
  {:else if tab === 'queue'}
    <!-- The queue beside the card, which is how a console is read: the list
         never leaves the screen while a call is worked. -->
    <div class="flex min-h-0 flex-1 gap-3">
      <div class="w-80 shrink-0">
        <CallQueue
          {calls}
          {beats}
          {now}
          {queueCount}
          {selectedId}
          onselect={(id) => (selectedId = id)}
          onfilter={(next) => {
            queryFilter = next;
            void loadCalls(next);
          }}
          oncreated={(id) => {
            selectedId = id;
            void reload();
          }}
        />
      </div>

      <div class="min-w-0 flex-1">
        <CallCard
          {card}
          {beats}
          {units}
          {now}
          loading={cardLoading}
          error={cardError}
          onchanged={() => void reload()}
        />
      </div>
    </div>
  {:else if tab === 'board'}
    <UnitBoard {units} {beats} {now} onchanged={() => void reload()} />
  {:else if tab === 'map'}
    <!--
      The map is loaded when it is opened and not before (7.17 "lazy-loaded",
      budget 12.1: the initial bundle is 250 KB gzipped and the console opens
      without a map). The import is what splits the chunk.
    -->
    {#await import('./Map.svelte')}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
    {:then loaded}
      {@const MapView = loaded.default}
      <MapView {beats} {now} onselect={(id) => respond(id)} />
    {/await}
  {:else if tab === 'alpr'}
    <!-- Lazy-loaded like the map: plate reads and the hotlist are not needed
         on first paint either, and a console opens without either open. -->
    {#await import('./Alpr.svelte')}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
    {:then loaded}
      {@const AlprView = loaded.default}
      <AlprView />
    {/await}
  {:else}
    <Broadcasts {calls} />
  {/if}
</section>
