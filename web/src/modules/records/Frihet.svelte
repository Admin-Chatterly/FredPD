<script lang="ts">
  import { onDestroy } from 'svelte';
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { FRIHET_STATUSES } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import { isStub, type Maybe, type Moment, type Restricted } from './types';
  import PersonPicker from '../shared/PersonPicker.svelte';
  import ChargePicker from '../shared/ChargePicker.svelte';
  import { onIntent, peekIntent, setIntent, takeIntent } from '../../lib/intent';
  import { mayOpen } from '../../lib/modules';

  /**
   * Frihetsberövande — the gripande → anhållande → häktningsframställan →
   * häktning chain and its statutory clocks (spec 7.9, RB 24).
   *
   * **The countdowns are why this screen exists.** The chain itself is a state
   * machine like the anmälan one; what makes it worth its own view is that two
   * of its transitions have deadlines in law, and missing one is an unlawful
   * detention rather than a late piece of paperwork:
   *
   *   * **RB 24:12** — the häktningsframställan must reach the court *senast
   *     klockan tolv tredje dagen* after the anhållandebeslut. A local noon
   *     three days out, which lands anywhere from 60 to 84 hours away depending
   *     on the time of day the decision was taken. Not seventy-two hours.
   *   * **RB 24:13** — the häktningsförhandling must be held within four dygn
   *     of the gripande. That one really is 96 hours.
   *
   * Both are computed on the server (`Frihet.deadlines`), and this screen does
   * not recompute either. A second implementation of RB 24:12 in a browser
   * would be the one nobody tested, and it is the number an officer would quote
   * to a prosecutor.
   *
   * What the screen *does* do is tick. See `remainingNow` below: it counts from
   * the server's `remaining`, never from its `at`, so a workstation whose clock
   * is a few minutes out cannot move a statutory deadline.
   *
   * Three further things the server decides and this renders rather than
   * second-guesses:
   *
   *   * **Which decisions are offered is the server's answer**, in
   *     `decisions`: the chain's status, the session's capacity, and whether
   *     it may stand in for an åklagare or domare nobody is playing tonight
   *     (7.9.1). A button the officer could only be refused on is not drawn.
   *     The routes still check, and a refusal that arrives anyway — the
   *     prosecutor signed on between the read and the press — is drawn as
   *     itself: `wrong_capacity` reads as "that decision is not yours to
   *     take", never as a role problem (invariant 4, spec 6.4).
   *   * **A chain the reader may not open arrives as a stub with no `id`**
   *     (4.5), drawn as the module's restricted row.
   *   * **`needsAttention` is the server's judgement**, generously drawn: the
   *     cost of a warning that was not needed is a highlighted row, and the cost
   *     of missing one is somebody held past a deadline.
   */

  interface Deadline {
    /** Epoch seconds. Rendered only through `remaining`, never subtracted from. */
    at: number;
    /** Seconds left *as the server saw it*, at the moment of the response. */
    remaining: number;
    passed: boolean;
  }

  interface FrihetRow {
    id: number;
    number: string;
    status: string;
    personId: number;
    personNumber?: string | null;
    /**
     * Each stage's ground, named the way the SELECT aliases it.
     *
     * There is **no bare `grund`** — `frihet/repo.lua` sends
     * `gripande_grund AS gripandeGrund` and two siblings, and a field called
     * `grund` typed here rendered nothing at all in game while passing every
     * test, because the fixture invented one. Three fields, spelled as the
     * server spells them.
     */
    gripandeGrund?: string | null;
    anhallandeGrund?: string | null;
    frigivenGrund?: string | null;
    gripandePlats?: string | null;
    gripenAt?: Moment;
    gripenBy?: string | null;
    anhallenAt?: Moment;
    anhallenBy?: string | null;
    framstallanAt?: Moment;
    framstallanBy?: string | null;
    haktadAt?: Moment;
    haktadBy?: string | null;
    haktningBeslut?: string | null;
    frigivenAt?: Moment;
    frigivenBy?: string | null;
    underrattadAt?: Moment;
    version: number;
    /** Added by `withClocks` on the way out of every frihet route. */
    deadlines?: { framstallan?: Deadline; forhandling?: Deadline };
    nextDeadline?: string | null;
    heldFor?: number | null;
    needsAttention?: boolean;
  }

  interface Charge {
    id: number;
    brottId: number;
    code: string;
    labelKey: string;
    citation?: string | null;
    grad: string;
    stage: string;
  }

  interface Straffskala {
    boter: boolean;
    min: number;
    max: number | null;
  }

  interface LogEntry {
    id: number;
    kind: string;
    note: string | null;
    /**
     * The author as a person, not as an account.
     *
     * `logged_by` is a Discord snowflake and the repo joins `fpd_officers` to
     * turn it into the callsign and the display name command staff set. An
     * 18-digit identifier in a "By" column told an officer nothing and put an
     * account id on the face of a record a defence lawyer reads. Both are
     * nullable: an entry written by somebody since off the roster still has to
     * appear, because the log is append-only.
     */
    loggedByCallsign: string | null;
    loggedByName: string | null;
    loggedAt: Moment;
  }

  /**
   * How this session may take a decision: in its own capacity, or standing in
   * for a role nobody holding it is signed on to fill (7.9.1). Absent when it
   * may not take it at all.
   */
  type Standing = 'self' | 'standIn';

  interface Detail {
    frihetsberovande: FrihetRow;
    decisions?: Partial<Record<Decision, Standing>>;
    brott: Charge[];
    straffskala?: Straffskala | null;
    log: LogEntry[];
  }

  /** The four decisions in the chain, in the order RB takes them. */
  type Decision = 'anhallande' | 'framstallan' | 'haktning' | 'frigiv';

  /**
   * Which decision each status makes available.
   *
   * Mirrors `Frihet.TRANSITIONS`. Not a second source of truth — the server
   * refuses anything this gets wrong, and `out_of_order` is drawn when it does.
   * It exists so the screen does not offer a button whose only outcome is a
   * refusal. `frigiv` is available from every open stage, which is the point:
   * somebody who must be released must be releasable at once.
   */
  const AVAILABLE: Record<string, Decision[]> = {
    gripen: ['anhallande', 'frigiv'],
    anhallen: ['framstallan', 'frigiv'],
    framstalld: ['haktning', 'frigiv'],
    haktad: ['frigiv'],
    frigiven: [],
  };

  /** The decisions that rest on a stated ground (RB), and the list each offers. */
  const GRUND_FOR: Partial<Record<Decision, string>> = {
    anhallande: 'frihet.grund',
    frigiv: 'frihet.frigivningsgrund',
  };

  const GRUND_KEYS: Record<string, string[]> = {
    'frihet.grund': [
      'pa_bar_garning',
      'efterlyst',
      'flyktfara',
      'kollusionsfara',
      'recidivfara',
      'identitet_oklar',
      'annan',
    ],
    'frihet.frigivningsgrund': ['ej_anhallen', 'beslut_upphavt', 'tiden_ute', 'annan'],
  };

  /** What a department logs in the arrestjournal (spec 7.9). Locale keys. */
  const LOG_KINDS = ['forhor', 'forsvarare', 'maltid', 'samtal', 'lakare', 'annan'];

  /**
   * Recording a gripande — the act that starts a chain (RB 24:7).
   *
   * Until this form existed, `frihet.gripande` was a route with no caller: the
   * screen could take every decision *in* a chain and there was no way to
   * begin one, so in game nobody could ever be booked in. The rest of M2's
   * exit criterion hangs off it.
   *
   * It is the one decision here an ordinary officer takes on their own
   * authority — the anhållande beside it belongs to a prosecutor — and it is
   * also the one the server acts on beyond this module: a gripande takes down
   * every live efterlysning on the person, because the arrest is what the
   * wanted notice existed to produce.
   */
  let arresting = $state(false);
  let arrest = $state({ personId: '', grund: '', plats: '' });

  /**
   * "Record an arrest" from a query row (lib/intent.ts): the arrest form
   * opens holding that person, named.
   */
  let arrestLabel = $state<string | null>(null);

  function followIntent(): void {
    const intent = peekIntent();
    if (!intent || intent.tab !== 'frihet' || !intent.personId) return;

    takeIntent();
    arrest = { personId: String(intent.personId), grund: '', plats: '' };
    arrestLabel = intent.subjectLabel ?? null;
    arresting = true;
  }

  $effect(() => {
    followIntent();
    return onIntent(() => followIntent());
  });

  let rows = $state<Maybe<FrihetRow>[]>([]);
  let detail = $state<Detail | null>(null);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);
  let openOnly = $state(true);
  let statusFilter = $state<string>('');
  let openId = $state<number | null>(null);
  let confirming = $state<Decision | null>(null);
  let grund = $state('');
  let logKind = $state(LOG_KINDS[0]);
  let logNote = $state('');

  /**
   * What the person is held for, edited as a checklist of the catalogue
   * (`frihet.charges.set`). The route has always existed; nothing called it,
   * so a chain could never say what it was for.
   */
  let editingCharges = $state(false);
  let chargeIds = $state<number[]>([]);
  let chargesButton = $state<HTMLButtonElement | null>(null);

  /** Closes the editor and gives focus back to the button that opened it. */
  function stopCharges(): void {
    editingCharges = false;
    queueMicrotask(() => chargesButton?.focus());
  }

  function startCharges(): void {
    chargeIds = (detail?.brott ?? []).map((charge) => charge.brottId);
    editingCharges = true;
  }

  async function saveCharges(): Promise<void> {
    if (!record) return;

    busy = true;
    const id = record.id;

    const response = await nui.call('frihet.charges.set', {
      id,
      brottIds: chargeIds.map(String),
    });

    if (response.ok) {
      failure = null;
      await open(id);
      stopCharges();
    } else {
      failure = response;
      busy = false;
    }
  }

  /**
   * The confirmation dialog, and the button that opened it.
   *
   * Kept so focus can move into the dialog when it opens and back to the
   * trigger when it closes. Without the first, pressing a decision button left
   * `document.activeElement` on `<body>` — nothing announced, no visible focus,
   * and a keyboard user had to tab blindly into a dialog about a detention.
   */
  let confirmBox = $state<HTMLDivElement | null>(null);
  let trigger: HTMLButtonElement | null = null;

  /** The required marker 6.4 asks for. Punctuation, so it is not a locale key. */
  const REQUIRED_MARK = '*';

  /** True once the server has said this decision needs a ground and none is set. */
  const grundMissing = $derived(
    failure?.err === 'invalid' && failure.fields?.grund === 'required' && !grund,
  );

  /**
   * Moves focus into the dialog as it opens.
   *
   * The dialog is the element that catches Escape, so focus being inside it is
   * what makes Escape close the dialog rather than the whole NUI.
   */
  $effect(() => {
    if (confirming && confirmBox) confirmBox.focus();
  });

  function cancelConfirm(): void {
    confirming = null;
    trigger?.focus();
  }

  /**
   * How long ago the open response arrived, in seconds, ticking once a second.
   *
   * This — not `Date.now()` against the server's `at` — is what the countdowns
   * subtract. The server sends `remaining` alongside `at` precisely so a client
   * never has to agree with it about what time it is: a workstation whose clock
   * is ten minutes fast would otherwise show a statutory deadline ten minutes
   * nearer than it is, and an officer would act on that number.
   *
   * One interval for the whole screen rather than one per row: the tick is a
   * property of the clock, not of any deadline.
   */
  let elapsed = $state(0);
  let fetchedAt = 0;

  const ticker = setInterval(() => {
    elapsed = (Date.now() - fetchedAt) / 1000;
  }, 1000);

  onDestroy(() => clearInterval(ticker));

  /** Which field a rejected code belongs to (spec 3.5). */
  const FIELD_LABELS: Record<string, string> = {
    status: 'frihet.column.status',
    grund: 'frihet.column.grund',
    personId: 'frihet.column.person',
    version: 'anmalan.column.version',
  };

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  const record = $derived(detail?.frihetsberovande ?? null);

  const available = $derived(
    record
      ? (AVAILABLE[record.status] ?? []).filter((action) => detail?.decisions?.[action] !== undefined)
      : [],
  );

  /**
   * The refusals that mean "this decision is not yours to take, from here, now"
   * — not a missing grant. Headed as a decision not taken rather than as a
   * Discord role problem, and followed by a re-read so the offered buttons
   * catch up with whatever changed (a prosecutor signing on, most often).
   */
  const DECISION_REFUSALS = new Set([
    'wrong_capacity',
    'out_of_order',
    'already_released',
    'decider_online',
    'own_chain',
    'stand_in_off',
  ]);

  const decisionRefused = $derived(DECISION_REFUSALS.has(failure?.fields?.status ?? ''));

  /**
   * One muted line when the chain waits on a decision this session is not
   * offered, so an officer looking at their own arrest sees why there is no
   * anhållande button. It describes the chain, not an access decision.
   */
  const WAITING_ON: Partial<Record<string, { action: Decision; role: string }>> = {
    gripen: { action: 'anhallande', role: 'aklagare' },
    anhallen: { action: 'framstallan', role: 'aklagare' },
    framstalld: { action: 'haktning', role: 'domare' },
  };

  const waitingOn = $derived.by(() => {
    const next = record ? WAITING_ON[record.status] : undefined;
    return next && detail?.decisions?.[next.action] === undefined ? next.role : null;
  });

  /** Stand-in decisions go to their own routes, which the audit trail names as such. */
  function standingFor(action: Decision | null): Standing | undefined {
    return action ? detail?.decisions?.[action] : undefined;
  }

  /** The verb on a decision's button: a stand-in's says so. */
  function actionLabel(action: Decision): string {
    return standingFor(action) === 'standIn'
      ? t(`frihet.standIn.action.${action}`)
      : t(`frihet.action.${action}`);
  }

  /** The ground box only appears for the two decisions that require one. */
  const grundList = $derived(confirming ? GRUND_FOR[confirming] : undefined);

  async function load(): Promise<void> {
    busy = true;

    // `frihet.open` is its own route and takes no filter: "who is in our cells
    // right now" has one answer. The status filter drops to `frihet.list`,
    // which is the history — including everybody already released.
    const response = openOnly
      ? await nui.call<{ frihetsberovanden: Maybe<FrihetRow>[] }>('frihet.open', { limit: 50 })
      : await nui.call<{ frihetsberovanden: Maybe<FrihetRow>[] }>('frihet.list', {
          status: statusFilter || undefined,
          limit: 50,
        });

    if (response.ok) {
      rows = response.data.frihetsberovanden ?? [];
      failure = null;
      markFetched();
    } else {
      failure = response;
    }

    busy = false;
  }

  async function open(id: number): Promise<void> {
    busy = true;

    // Cleared before the fetch: a ground chosen against one chain must not be
    // carried to the next one and sent with its release.
    confirming = null;
    grund = '';
    logNote = '';
    editingCharges = false;

    const response = await nui.call<Detail>('frihet.get', { id });

    if (response.ok) {
      detail = response.data;
      openId = id;
      failure = null;
      markFetched();
    } else {
      detail = null;
      openId = null;
      failure = response;
    }

    busy = false;
  }

  /** Restarts the countdown baseline. Every response carries a fresh `remaining`. */
  function markFetched(): void {
    fetchedAt = Date.now();
    elapsed = 0;
  }

  async function decide(action: Decision): Promise<void> {
    if (!record) return;

    busy = true;
    confirming = null;

    const id = record.id;

    const route =
      standingFor(action) === 'standIn' ? `frihet.fallback.${action}` : `frihet.${action}`;

    const response = await nui.call(route, {
      id,
      version: record.version,
      grund: grund || undefined,
    });

    if (response.ok) {
      failure = null;
      await open(id);
      await load();
    } else if (DECISION_REFUSALS.has(response.fields?.status ?? '')) {
      // Re-read first, so the button that was just refused is not offered
      // again; `open` clears the failure, so it is set after.
      await open(id);
      failure = response;
    } else {
      failure = response;
      busy = false;
    }
  }

  /** Starts a chain, and opens it. */
  async function gripande(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    busy = true;

    const response = await nui.call<{ id: number }>('frihet.gripande', {
      personId: Number(arrest.personId) || undefined,
      grund: arrest.grund || undefined,
      plats: arrest.plats || undefined,
    });

    if (response.ok) {
      failure = null;
      arresting = false;
      arrest = { personId: '', grund: '', plats: '' };
      await Promise.all([load(), open(response.data.id)]);
    } else {
      failure = response;
      busy = false;
    }
  }

  /** RB 24:9. Written once — a second press is not an error and moves nothing. */
  async function notify(): Promise<void> {
    if (!record) return;

    busy = true;
    const id = record.id;
    const response = await nui.call('frihet.underratta', { id });

    if (response.ok) {
      failure = null;
      await open(id);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function addLog(): Promise<void> {
    if (!record) return;

    busy = true;
    const id = record.id;

    const response = await nui.call('frihet.log.add', {
      id,
      kind: `frihet.logKind.${logKind}`,
      note: logNote || undefined,
    });

    if (response.ok) {
      failure = null;
      logNote = '';
      await open(id);
    } else {
      failure = response;
      busy = false;
    }
  }

  /**
   * Seconds left on a deadline right now.
   *
   * The server's figure, less the time since it answered. Never
   * `at - Date.now()`, for the reason `elapsed` gives.
   */
  function remainingNow(deadline: Deadline): number {
    return deadline.remaining - elapsed;
  }

  /**
   * How long this person has been held, as a row should read it.
   *
   * `elapsed` is added only while the chain is open. The server already froze
   * the figure at the release — `Frihet.heldFor` measures to `frigivenAt` or to
   * now, whichever exists — and adding the tick unconditionally undid that, so
   * a detention that ended weeks ago grew a second every second while somebody
   * watched the history list.
   */
  function heldText(row: FrihetRow): string {
    if (!row.heldFor) return '';

    return duration(row.frigivenAt ? row.heldFor : row.heldFor + elapsed);
  }

  /**
   * A span of seconds as an officer reads it: `2 d 6 h`, `14 min`.
   *
   * Two units at most, and never a unit that is zero — "0 d 6 h 0 min" is three
   * facts where one was wanted. Below an hour it counts minutes, because the
   * last hour of an RB 24:12 deadline is the hour somebody is watching it.
   */
  function duration(seconds: number): string {
    const total = Math.max(0, Math.floor(Math.abs(seconds)));
    const days = Math.floor(total / 86400);
    const hours = Math.floor((total % 86400) / 3600);
    const minutes = Math.floor((total % 3600) / 60);

    const parts: string[] = [];

    if (days > 0) parts.push(t('frihet.duration.days', { count: String(days) }));
    if (hours > 0) parts.push(t('frihet.duration.hours', { count: String(hours) }));
    if (parts.length < 2 && (minutes > 0 || parts.length === 0)) {
      parts.push(t('frihet.duration.minutes', { count: String(minutes) }));
    }

    return parts.slice(0, 2).join(' ');
  }

  /** The countdown text for a deadline: overdue by, or remaining. */
  function countdown(deadline: Deadline): string {
    const left = remainingNow(deadline);

    return left <= 0
      ? t('frihet.deadline.passed', { time: duration(left) })
      : t('frihet.deadline.remaining', { time: duration(left) });
  }

  /** True once the clock has run out, whether or not it had when the server answered. */
  function isOverdue(deadline: Deadline): boolean {
    return deadline.passed || remainingNow(deadline) <= 0;
  }

  /** The deadline a list row is counting down to, if any. */
  function nextOf(row: FrihetRow): Deadline | null {
    const key = row.nextDeadline;
    if (!key) return null;

    return row.deadlines?.[key as 'framstallan' | 'forhandling'] ?? null;
  }

  /**
   * A log entry's author, as 6.3 writes one: `Berg (1-ADAM-12)`.
   *
   * Empty when the roster no longer has them — an entry by somebody since
   * removed still belongs in an append-only log, and a blank cell says "we no
   * longer know who" more honestly than an account id does.
   */
  function officerText(entry: LogEntry): string {
    if (entry.loggedByName && entry.loggedByCallsign) {
      return `${entry.loggedByName} (${entry.loggedByCallsign})`;
    }

    return entry.loggedByName ?? entry.loggedByCallsign ?? '';
  }

  function stubContact(row: Restricted): string {
    return t('records.restricted.contact', { unit: t(`access.unit.${row.contact}`) });
  }

  /** Months as the span a straffskala is written in (BrB 26). */
  function span(skala: Straffskala): string {
    if (skala.max === null) return t('brott.straffskala.livstid');

    const max = months(skala.max);

    return skala.min > 0
      ? t('brott.straffskala.atLeast', { min: months(skala.min), max })
      : t('brott.straffskala.upTo', { max });
  }

  function months(value: number): string {
    if (value >= 12 && value % 12 === 0) {
      const years = value / 12;

      return t(years === 1 ? 'brott.straffskala.year' : 'brott.straffskala.years', {
        count: String(years),
      });
    }

    return t(value === 1 ? 'brott.straffskala.month' : 'brott.straffskala.months', {
      count: String(value),
    });
  }

  /**
   * The chain as four stages, each with when it happened and who decided.
   *
   * Built from the row rather than from a status, because the status says only
   * where the chain is *now* and the question this section answers is what
   * happened along the way — which is what somebody reviewing the detention
   * afterwards is reading.
   */
  const stages = $derived(
    record
      ? [
          {
            key: 'gripen',
            at: record.gripenAt,
            grund: record.gripandeGrund,
            grundList: 'frihet.grund',
            plats: record.gripandePlats,
          },
          {
            key: 'anhallen',
            at: record.anhallenAt,
            grund: record.anhallandeGrund,
            grundList: 'frihet.grund',
          },
          { key: 'framstalld', at: record.framstallanAt, grund: null, grundList: '' },
          { key: 'haktad', at: record.haktadAt, grund: null, grundList: '' },
          {
            key: 'frigiven',
            at: record.frigivenAt,
            grund: record.frigivenGrund,
            grundList: 'frihet.frigivningsgrund',
          },
        ]
      : [],
  );

  void load();
</script>

<div class="flex flex-col gap-3">
  <form
    class="flex flex-wrap items-end gap-2"
    onsubmit={(event) => {
      event.preventDefault();
      void load();
    }}
  >
    <label class="flex items-center gap-1 text-xs">
      <input type="checkbox" bind:checked={openOnly} />
      {t('frihet.filter.openOnly')}
    </label>

    <label class="flex flex-col gap-1 text-xs">
      {t('frihet.column.status')}
      <select
        bind:value={statusFilter}
        disabled={openOnly}
        class="border border-[var(--color-border)] px-2 py-1"
      >
        <option value="">{t('form.any')}</option>
        {#each FRIHET_STATUSES as status (status)}
          <option value={status}>{t(`frihet.status.${status}`)}</option>
        {/each}
      </select>
    </label>

    <button
      type="submit"
      class="border border-[var(--color-border)] px-3 py-1 text-xs"
      disabled={busy}
    >
      {t('form.search')}
    </button>

    <button
      type="button"
      class="border border-[var(--color-border)] px-3 py-1 text-xs"
      aria-expanded={arresting}
      onclick={() => (arresting = !arresting)}
    >
      {t('frihet.action.newGripande')}
    </button>
  </form>

  {#if arresting}
    <!--
      RB 24:7. The ground is a locale key and required, because it is the
      sentence quoted back when the detention is reviewed; the place is free
      text, because "the alley behind Kvarngatan 3" is not a key anybody can
      enumerate.
    -->
    <form
      class="flex flex-wrap items-end gap-2 border border-[var(--color-border)] p-3"
      onsubmit={(event) => void gripande(event)}
    >
      <div class="flex w-64 flex-col gap-1 text-xs">
        <span id="frihet-arrest-person-label">{t('frihet.field.personId')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
        <PersonPicker
          bind:value={arrest.personId}
          initialLabel={arrestLabel}
          labelledby="frihet-arrest-person-label"
          required
        />
      </div>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('frihet.column.grund')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
        <select
          bind:value={arrest.grund}
          required
          aria-required="true"
          class="border border-[var(--color-border)] px-2 py-1"
        >
          <option value="">{t('frihet.grund.choose')}</option>
          {#each GRUND_KEYS['frihet.grund'] as key (key)}
            <option value={key}>{t(`frihet.grund.${key}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-1 flex-col gap-1 text-xs">
        <span>{t('frihet.field.plats')}</span>
        <input
          bind:value={arrest.plats}
          maxlength="191"
          class="border border-[var(--color-border)] px-2 py-1"
        />
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1 text-xs"
        disabled={busy}
      >
        {t('frihet.action.gripande')}
      </button>
    </form>
  {/if}

  {#if failure}
    <div class="border border-[var(--color-alert)] px-3 py-2 text-sm" role="alert">
      <p>{decisionRefused ? t('frihet.refused') : t(`error.${failure.err}`)}</p>
      {#if messages.length > 0}
        <ul class="mt-1 text-xs text-[var(--color-ink-muted)]">
          {#each messages as message (message.name)}
            <li>{message.label} — {message.reason}</li>
          {/each}
        </ul>
      {/if}
    </div>
  {/if}

  <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)]">
    <!-- Who is being held -->
    <div class="border border-[var(--color-border)]">
      {#if rows.length === 0}
        <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">
          {openOnly ? t('frihet.empty') : t('frihet.emptyList')}
        </p>
      {:else}
        <!--
          Scrolls inside its own panel rather than pushing past it.
          Five columns of Swedish do not fit 438 px: "Häktningsframställan
          inlämnad" alone is 29 characters with an unbreakable first word, and
          the countdown column — the one the screen exists for — was rendering
          89 px outside the border and over the detail panel behind it. Spec 6
          allows a table its own horizontal scroll; it does not allow the
          statutory deadline to be the part that falls off.
        -->
        <div class="overflow-x-auto">
          <table class="w-full text-xs">
            <thead class="bg-[var(--color-surface)]">
              <tr>
                <th class="px-2 py-1 text-left font-semibold">{t('frihet.column.number')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('frihet.column.person')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('frihet.column.status')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('frihet.column.heldFor')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('frihet.column.deadline')}</th>
              </tr>
            </thead>
            <tbody>
              <!--
                Keyed by index, not by id: a stub carries no id (4.5), so two
                restricted rows would collide on `undefined` and Svelte would
                refuse to render the list at all. Every list in this module keys
                the same way.
              -->
              {#each rows as row, index (index)}
                {#if isStub(row)}
                  <tr class="border-t border-[var(--color-border)]">
                    <td class="px-2 py-1 text-[var(--color-ink-muted)]" colspan="5">
                      {t('records.restricted.title')} — {stubContact(row)}
                    </td>
                  </tr>
                {:else}
                  {@const deadline = nextOf(row)}
                  <tr class="border-t border-[var(--color-border)]">
                    <td class="px-2 py-1 font-[family-name:var(--font-mono)] whitespace-nowrap">
                      <button
                        type="button"
                        class="underline-offset-2 hover:underline"
                        class:font-semibold={openId === row.id}
                        onclick={() => void open(row.id)}
                      >
                        {row.number}
                      </button>
                    </td>
                    <td class="px-2 py-1 font-[family-name:var(--font-mono)] whitespace-nowrap">
                      {row.personNumber ?? ''}
                    </td>
                    <td class="px-2 py-1">{t(`frihet.status.${row.status}`)}</td>
                    <td class="px-2 py-1 whitespace-nowrap">{heldText(row)}</td>
                    <td class="px-2 py-1 whitespace-nowrap">
                      {#if deadline}
                        <!--
                          Three states, not two. Overdue and comfortable were
                          distinguished; *about to breach* was not, so a row
                          four hours from an RB 24:12 breach looked exactly like
                          one with three days left — on the board a supervisor
                          watches precisely to catch the first.
                          `needsAttention` is the server's own judgement and was
                          already on every row; it was simply not drawn.

                          Each state carries a word as well as a colour, because
                          colour alone is not a signal every officer receives
                          and this is the column where missing it is an unlawful
                          detention (6.2).
                        -->
                        <span
                          class:text-[var(--color-alert)]={isOverdue(deadline)}
                          class:text-[var(--color-caution)]={!isOverdue(deadline) &&
                            row.needsAttention}
                        >
                          {#if !isOverdue(deadline) && row.needsAttention}
                            {t('frihet.deadline.soon')} —
                          {/if}
                          {countdown(deadline)}
                        </span>
                      {/if}
                    </td>
                  </tr>
                {/if}
              {/each}
            </tbody>
          </table>
        </div>
      {/if}
    </div>

    <!-- The chain -->
    <div class="border border-[var(--color-border)] p-3">
      {#if !record || !detail}
        <p class="text-xs text-[var(--color-ink-muted)]">{t('frihet.detail.none')}</p>
      {:else}
        <header class="mb-3">
          <h2 class="font-[family-name:var(--font-mono)] text-sm font-semibold">
            {record.number}
          </h2>
          <p class="text-xs text-[var(--color-ink-muted)]">
            {t(`frihet.status.${record.status}`)}
            {#if record.gripandeGrund}
              · {t(`frihet.grund.${record.gripandeGrund}`)}
            {/if}
            {#if record.heldFor}
              · {t('frihet.column.heldFor')}: {heldText(record)}
            {/if}
          </p>
        </header>

        {#if record.needsAttention}
          <!--
            `caution` while a deadline is still running, `alert` only once one
            has passed. 6.2 assigns caution to "pending, expiring, needs
            attention" and alert to warrants and officer safety — and a banner
            that reads the same six hours before a breach as it does a day
            after one is a banner that stops distinguishing them.

            It also names which deadline, because "a statutory deadline needs
            attention" does not tell an officer whether to ring the prosecutor
            or the court.
          -->
          {@const passed = nextOf(record) ? isOverdue(nextOf(record)!) : false}
          <p
            class="mb-3 px-2 py-1 text-xs"
            class:border={true}
            class:border-[var(--color-alert)]={passed}
            class:border-[var(--color-caution)]={!passed}
            role="alert"
          >
            {#if record.nextDeadline}
              {t(passed ? 'frihet.attentionPassed' : 'frihet.attentionSoon', {
                deadline: t(`frihet.deadline.${record.nextDeadline}`),
              })}
            {:else}
              {t('frihet.attention')}
            {/if}
          </p>
        {/if}

        <!-- The statutory clocks -->
        <section class="mb-3">
          <h3 class="mb-1 text-xs font-semibold">{t('frihet.section.deadlines')}</h3>
          {#if !record.deadlines?.framstallan && !record.deadlines?.forhandling}
            <p class="text-xs text-[var(--color-ink-muted)]">{t('frihet.deadline.none')}</p>
          {:else}
            <dl class="text-xs">
              {#each ['framstallan', 'forhandling'] as const as key (key)}
                {@const deadline = record.deadlines?.[key]}
                {#if deadline}
                  <div class="flex justify-between border-t border-[var(--color-border)] py-1">
                    <dt>{t(`frihet.deadline.${key}`)}</dt>
                    <dd
                      class="font-[family-name:var(--font-mono)]"
                      class:text-[var(--color-alert)]={isOverdue(deadline)}
                      class:font-semibold={isOverdue(deadline)}
                    >
                      {countdown(deadline)}
                    </dd>
                  </div>
                {/if}
              {/each}
            </dl>
          {/if}
        </section>

        <!-- What happened, and who decided it -->
        <section class="mb-3">
          <h3 class="mb-1 text-xs font-semibold">{t('frihet.section.chain')}</h3>
          <ul class="text-xs">
            {#each stages as stage (stage.key)}
              <li class="border-t border-[var(--color-border)] py-1">
                <div class="flex justify-between gap-2">
                  <!--
                    The row names the *decision*, not the person's state: this
                    is a list of what was decided, and "Gripen / Anhållen /
                    Häktad" are what somebody is, which reads oddly under a
                    heading of "Beslut". `frihet.stage.*` carries the act.
                  -->
                  <span class:text-[var(--color-ink-muted)]={!stage.at}>
                    {t(`frihet.stage.${stage.key}`)}
                  </span>
                  <span class="font-[family-name:var(--font-mono)] whitespace-nowrap">
                    {#if stage.at}
                      {formatMoment(stage.at)}
                    {:else}
                      <span class="text-[var(--color-ink-muted)]">{t('frihet.chain.pending')}</span>
                    {/if}
                  </span>
                </div>
                <!--
                  The ground each decision rested on, which is the part quoted
                  afterwards. The release ground in particular was required by
                  the server, stored, and then rendered nowhere — so the reason
                  somebody was let go vanished the moment it was recorded.
                -->
                {#if stage.grund}
                  <p class="text-[var(--color-ink-muted)]">
                    {t('frihet.column.grund')}: {t(`${stage.grundList}.${stage.grund}`)}
                  </p>
                {/if}
                <!--
                  Where it happened. Stored by `frihet.gripande` since the
                  module landed and drawn nowhere — so the place an officer
                  typed went into the record and out of sight, which is the
                  same way the arrest ground was lost.
                -->
                {#if stage.plats}
                  <p class="text-[var(--color-ink-muted)]">
                    {t('frihet.field.plats')}: {stage.plats}
                  </p>
                {/if}
              </li>
            {/each}
          </ul>

          <!--
            RB 24:9 — the suspect must be told what they are suspected of. It
            sits under the chain rather than beside the buttons because it is a
            fact about the detention, not a decision in it.
          -->
          <p class="mt-2 text-xs">
            {#if record.underrattadAt}
              {t('frihet.chain.notified')} — <span
                class="font-[family-name:var(--font-mono)]">{formatMoment(record.underrattadAt)}</span
              >
            {:else}
              <span class="text-[var(--color-caution)]">{t('frihet.chain.notNotified')}</span>
              <button
                type="button"
                class="ml-2 border border-[var(--color-border)] px-2 py-0.5"
                disabled={busy}
                onclick={() => void notify()}
              >
                {t('frihet.action.underratta')}
              </button>
            {/if}
          </p>

          {#if record.status !== 'frigiven' && mayOpen('booking')}
            <!-- The next step in the building: booking, with this chain
                 already chosen. Offered only to a session the server lets
                 open Booking. -->
            <button
              type="button"
              class="mt-2 border border-[var(--color-border)] px-2 py-0.5 text-xs hover:bg-[var(--color-surface)]"
              onclick={() => setIntent({ module: 'booking', frihetId: record.id })}
            >
              {t('frihet.action.book')}
            </button>
          {/if}
        </section>

        <!-- What they are held for -->
        <section class="mb-3">
          <div class="mb-1 flex items-center gap-2">
            <h3 class="text-xs font-semibold">{t('frihet.section.brott')}</h3>
            {#if record && record.status !== 'frigiven' && !editingCharges}
              <button
                type="button"
                class="border border-[var(--color-border)] px-2 py-0.5 text-xs hover:bg-[var(--color-surface)]"
                bind:this={chargesButton}
                onclick={startCharges}
              >
                {t('frihet.action.editCharges')}
              </button>
            {/if}
          </div>
          {#if editingCharges}
            <ChargePicker bind:selected={chargeIds} legend={t('frihet.section.brott')} disabled={busy} />
            <div class="mt-1 flex gap-2 text-xs">
              <button
                type="button"
                class="border border-[var(--color-border)] px-3 py-1 font-semibold hover:bg-[var(--color-surface)]"
                disabled={busy}
                onclick={() => void saveCharges()}
              >
                {t('form.save')}
              </button>
              <button
                type="button"
                class="border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]"
                onclick={stopCharges}
              >
                {t('form.cancel')}
              </button>
            </div>
          {:else if detail.brott.length === 0}
            <p class="text-xs text-[var(--color-ink-muted)]">{t('frihet.brott.empty')}</p>
          {:else}
            <ul class="text-xs">
              {#each detail.brott as charge (charge.id)}
                <li class="border-t border-[var(--color-border)] py-1">
                  <span class="font-[family-name:var(--font-mono)]">
                    {charge.citation ?? charge.code}
                  </span>
                  — {t(charge.labelKey)}
                  <span class="text-[var(--color-ink-muted)]">
                    ({t(`brott.grad.${charge.grad}`)})
                  </span>
                </li>
              {/each}
            </ul>

            {#if detail.straffskala}
              <p class="mt-2 text-xs">
                <span class="font-semibold">{t('brott.column.straffskala')}:</span>
                {span(detail.straffskala)}
                {#if detail.straffskala.boter}
                  · {t('brott.straffskala.boter')}
                {/if}
              </p>
            {/if}
          {/if}
        </section>

        <!-- The decisions -->
        {#if waitingOn}
          <p class="mb-2 text-xs text-[var(--color-ink-muted)]">{t(`frihet.waiting.${waitingOn}`)}</p>
        {/if}
        {#if available.length > 0}
          <section class="mb-3 border-t border-[var(--color-border)] pt-3">
            {#if confirming}
              <!--
                6.4: a dialog with a verb label for a legal action. Each of
                these either keeps somebody locked up or lets them go, and each
                is quoted afterwards.

                `onkeydown` is not decoration. `main.ts` listens for Escape on
                `window` and asks the client to close the whole NUI, so Escape
                inside this dialog used to discard the open record and the
                chosen ground mid-release — the opposite of 6.4, which wants
                Escape to close the dialog. Stopping propagation keeps it local.

                Focused on open so a keyboard user is actually inside it, and
                focus returns to the button that opened it on cancel.
              -->
              <div
                bind:this={confirmBox}
                role="dialog"
                aria-modal="true"
                aria-label={actionLabel(confirming)}
                aria-describedby={standingFor(confirming) === 'standIn'
                  ? 'frihet-confirm-text frihet-standin-text'
                  : 'frihet-confirm-text'}
                tabindex="-1"
                class="border border-[var(--color-border)] px-2 py-2 text-xs"
                onkeydown={(event) => {
                  if (event.key !== 'Escape') return;

                  event.stopPropagation();
                  event.preventDefault();
                  cancelConfirm();
                }}
              >
                <p id="frihet-confirm-text">{t(`frihet.confirm.${confirming}`)}</p>
                {#if standingFor(confirming) === 'standIn'}
                  <!--
                    7.9.1: said before the button, not after. The officer is
                    about to take a decision that is not theirs by rank, and the
                    record will say so.
                  -->
                  <p id="frihet-standin-text" class="mt-1 font-semibold">
                    {t(`frihet.standIn.confirm.${confirming}`)}
                  </p>
                {/if}

                {#if grundList}
                  <!--
                    The ground comes BEFORE the buttons, so the tab order
                    reaches it before the action that consumes it (6.4). It is a
                    locale key and never free text (invariant 6): it is read
                    back in both languages and quoted in a court file.

                    The placeholder is "choose a ground", not `form.any`. The
                    server requires this field (`grund: required`), and an empty
                    option labelled "Any" read as a filter default and invited a
                    refusal the officer had done nothing to deserve.
                  -->
                  <label class="mt-2 flex flex-col gap-1">
                    {t('frihet.column.grund')} <span aria-hidden="true">{REQUIRED_MARK}</span>
                    <select
                      bind:value={grund}
                      required
                      aria-required="true"
                      class="border border-[var(--color-border)] px-2 py-1"
                      class:border-[var(--color-alert)]={grundMissing}
                    >
                      <option value="">{t('frihet.grund.choose')}</option>
                      {#each GRUND_KEYS[grundList] as key (key)}
                        <option value={key}>{t(`${grundList}.${key}`)}</option>
                      {/each}
                    </select>
                    {#if grundMissing}
                      <!--
                        Beside the field, not only in the panel at the top of
                        the page: 6.4 wants inline validation, and the officer
                        is looking here.
                      -->
                      <span class="text-[var(--color-alert)]">{t('fieldError.required')}</span>
                    {/if}
                  </label>
                {/if}

                <div class="mt-2 flex gap-2">
                  <button
                    type="button"
                    class="border border-[var(--color-border)] px-3 py-1"
                    disabled={busy}
                    onclick={() => void decide(confirming as Decision)}
                  >
                    {actionLabel(confirming)}
                  </button>
                  <button
                    type="button"
                    class="border border-[var(--color-border)] px-3 py-1"
                    onclick={() => cancelConfirm()}
                  >
                    {t('form.cancel')}
                  </button>
                </div>
              </div>
            {:else}
              <div class="flex flex-wrap gap-2">
                {#each available as action (action)}
                  <button
                    type="button"
                    class="border border-[var(--color-border)] px-3 py-1 text-xs"
                    disabled={busy}
                    onclick={(event) => {
                      trigger = event.currentTarget;
                      confirming = action;
                      grund = '';
                    }}
                  >
                    {actionLabel(action)}
                  </button>
                {/each}
              </div>
            {/if}
          </section>
        {/if}

        <!-- Arrestjournalen -->
        <section class="border-t border-[var(--color-border)] pt-3">
          <h3 class="mb-1 text-xs font-semibold">{t('frihet.section.log')}</h3>

          {#if detail.log.length === 0}
            <p class="text-xs text-[var(--color-ink-muted)]">{t('frihet.log.empty')}</p>
          {:else}
            <table class="w-full text-xs">
              <thead class="bg-[var(--color-surface)]">
                <tr>
                  <th class="px-2 py-1 text-left font-semibold">{t('frihet.log.at')}</th>
                  <th class="px-2 py-1 text-left font-semibold">{t('frihet.log.kind')}</th>
                  <th class="px-2 py-1 text-left font-semibold">{t('frihet.log.note')}</th>
                  <th class="px-2 py-1 text-left font-semibold">{t('frihet.log.by')}</th>
                </tr>
              </thead>
              <tbody>
                {#each detail.log as entry (entry.id)}
                  <tr class="border-t border-[var(--color-border)]">
                    <td class="px-2 py-1 font-[family-name:var(--font-mono)]">
                      {formatMoment(entry.loggedAt)}
                    </td>
                    <td class="px-2 py-1">{t(entry.kind)}</td>
                    <td class="px-2 py-1">{entry.note ?? ''}</td>
                    <td class="px-2 py-1">{officerText(entry)}</td>
                  </tr>
                {/each}
              </tbody>
            </table>
          {/if}

          <form
            class="mt-2 flex flex-wrap items-end gap-2"
            onsubmit={(event) => {
              event.preventDefault();
              void addLog();
            }}
          >
            <label class="flex flex-col gap-1 text-xs">
              {t('frihet.log.kind')}
              <select bind:value={logKind} class="border border-[var(--color-border)] px-2 py-1">
                {#each LOG_KINDS as kind (kind)}
                  <option value={kind}>{t(`frihet.logKind.${kind}`)}</option>
                {/each}
              </select>
            </label>

            <label class="flex flex-1 flex-col gap-1 text-xs">
              {t('frihet.log.note')}
              <input
                bind:value={logNote}
                class="border border-[var(--color-border)] px-2 py-1"
              />
            </label>

            <button
              type="submit"
              class="border border-[var(--color-border)] px-3 py-1 text-xs"
              disabled={busy}
            >
              {t('frihet.action.log')}
            </button>
          </form>
        </section>
      {/if}
    </div>
  </div>
</div>
