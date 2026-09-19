<script lang="ts">
  import { onDestroy } from 'svelte';
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { FRIHET_STATUSES } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import { isStub, type Maybe, type Moment, type Restricted } from './types';

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
   *   * **Which decisions are offered comes from the chain's status**, and the
   *     capacity to take them comes from the session's permissions on the
   *     server. An officer who may not anhålla still sees the button and is
   *     refused by the server; the refusal is drawn, and `wrong_capacity` reads
   *     as "that decision is not yours to take" rather than as a role problem
   *     (invariant 4, spec 6.4).
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
    grund?: string | null;
    plats?: string | null;
    gripenAt?: Moment;
    gripenBy?: string | null;
    anhallenAt?: Moment;
    anhallenBy?: string | null;
    framstallanAt?: Moment;
    haktadAt?: Moment;
    haktadBy?: string | null;
    frigivenAt?: Moment;
    frigivenBy?: string | null;
    frigivenGrund?: string | null;
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
    loggedBy: string | null;
    loggedAt: Moment;
  }

  interface Detail {
    frihetsberovande: FrihetRow;
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

  const available = $derived(record ? (AVAILABLE[record.status] ?? []) : []);

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

    const response = await nui.call(`frihet.${action}`, {
      id,
      version: record.version,
      grund: grund || undefined,
    });

    if (response.ok) {
      failure = null;
      await open(id);
      await load();
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

  /** A server timestamp; minutes are as fine as a custody log ever needs. */
  function formatMoment(value: Moment): string {
    if (value === null || value === undefined) return '';
    if (typeof value === 'number') {
      return new Date(value).toISOString().slice(0, 16).replace('T', ' ');
    }

    return value.replace('T', ' ').slice(0, 16);
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
          { key: 'gripen', at: record.gripenAt, by: record.gripenBy },
          { key: 'anhallen', at: record.anhallenAt, by: record.anhallenBy },
          { key: 'framstalld', at: record.framstallanAt, by: null },
          { key: 'haktad', at: record.haktadAt, by: record.haktadBy },
          { key: 'frigiven', at: record.frigivenAt, by: record.frigivenBy },
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
  </form>

  {#if failure}
    <div class="border border-[var(--color-alert)] px-3 py-2 text-sm" role="alert">
      <p>{t(`error.${failure.err}`)}</p>
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
                  <td class="px-2 py-1 font-[family-name:var(--font-mono)]">
                    <button
                      type="button"
                      class="underline-offset-2 hover:underline"
                      class:font-semibold={openId === row.id}
                      onclick={() => void open(row.id)}
                    >
                      {row.number}
                    </button>
                  </td>
                  <td class="px-2 py-1 font-[family-name:var(--font-mono)]">
                    {row.personNumber ?? ''}
                  </td>
                  <td class="px-2 py-1">{t(`frihet.status.${row.status}`)}</td>
                  <td class="px-2 py-1">
                    {row.heldFor ? duration(row.heldFor + elapsed) : ''}
                  </td>
                  <td class="px-2 py-1">
                    {#if deadline}
                      <!--
                        The overdue row is marked by colour AND by a word.
                        Colour alone is not a signal every officer receives, and
                        this is the one row on the screen where missing it is an
                        unlawful detention (6.2).
                      -->
                      <span class:text-[var(--color-alert)]={isOverdue(deadline)}>
                        {#if isOverdue(deadline)}
                          {t('frihet.deadline.overdueRow')} —
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
            {#if record.grund}
              · {t(`frihet.grund.${record.grund}`)}
            {/if}
            {#if record.heldFor}
              · {t('frihet.column.heldFor')}: {duration(record.heldFor + elapsed)}
            {/if}
          </p>
        </header>

        {#if record.needsAttention}
          <p class="mb-3 border border-[var(--color-alert)] px-2 py-1 text-xs" role="alert">
            {t('frihet.attention')}
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
              <li class="flex justify-between border-t border-[var(--color-border)] py-1">
                <span class:text-[var(--color-ink-muted)]={!stage.at}>
                  {t(`frihet.status.${stage.key}`)}
                </span>
                <span class="font-[family-name:var(--font-mono)]">
                  {#if stage.at}
                    {formatMoment(stage.at)}{#if stage.by}
                      · {t('frihet.chain.by')} {stage.by}{/if}
                  {:else}
                    <span class="text-[var(--color-ink-muted)]">{t('frihet.chain.pending')}</span>
                  {/if}
                </span>
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
        </section>

        <!-- What they are held for -->
        <section class="mb-3">
          <h3 class="mb-1 text-xs font-semibold">{t('frihet.section.brott')}</h3>
          {#if detail.brott.length === 0}
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
        {#if available.length > 0}
          <section class="mb-3 border-t border-[var(--color-border)] pt-3">
            {#if confirming}
              <!--
                6.4: a dialog with a verb label for a legal action. Each of
                these either keeps somebody locked up or lets them go, and each
                is quoted afterwards.
              -->
              <div class="border border-[var(--color-border)] px-2 py-2 text-xs">
                <p>{t(`frihet.confirm.${confirming}`)}</p>

                {#if grundList}
                  <!--
                    The ground comes BEFORE the buttons, so the tab order
                    reaches it before the action that consumes it (6.4). It is a
                    locale key and never free text (invariant 6): it is read
                    back in both languages and quoted in a court file.
                  -->
                  <label class="mt-2 flex flex-col gap-1">
                    {t('frihet.column.grund')}
                    <select bind:value={grund} class="border border-[var(--color-border)] px-2 py-1">
                      <option value="">{t('form.any')}</option>
                      {#each GRUND_KEYS[grundList] as key (key)}
                        <option value={key}>{t(`${grundList}.${key}`)}</option>
                      {/each}
                    </select>
                  </label>
                {/if}

                <div class="mt-2 flex gap-2">
                  <button
                    type="button"
                    class="border border-[var(--color-border)] px-3 py-1"
                    disabled={busy}
                    onclick={() => void decide(confirming as Decision)}
                  >
                    {t(`frihet.action.${confirming}`)}
                  </button>
                  <button
                    type="button"
                    class="border border-[var(--color-border)] px-3 py-1"
                    onclick={() => (confirming = null)}
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
                    onclick={() => {
                      confirming = action;
                      grund = '';
                    }}
                  >
                    {t(`frihet.action.${action}`)}
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
                    <td class="px-2 py-1">{entry.loggedBy ?? ''}</td>
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
