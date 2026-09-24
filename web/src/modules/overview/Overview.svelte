<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { setIntent } from '../../lib/intent';
  import type { Session } from '../../lib/types';
  import type { ErrorCode } from '@fredpd/schema';
  import type { Broadcast, Call, Unit } from '../cad/Dispatch.svelte';

  /**
   * Where F6 lands when the MDT first opens (spec 6.3): what this officer
   * needs to know right now, before choosing a module.
   *
   * Five short panels, each answered by a route the officer's own module
   * already calls, and only for a module the server put on the rail -- so an
   * officer who has no dispatch screen is not asked about calls at all, and
   * no refusal is written to the audit log on their behalf. A route that
   * still refuses leaves its panel out; any other failure is said inside the
   * panel with a way to try again, never read as "nothing here". Nothing on
   * this screen writes: every row hands over to the module that owns it.
   *
   * Uncluttered by rule: at most four one-line rows a panel.
   */

  interface Props {
    session: Session;
    /** Switches the shell to a module, and puts focus on its heading. */
    onOpenModule: (module: string) => void;
  }

  let { session, onOpenModule }: Props = $props();

  interface Report {
    id: number;
    number: string;
    title: string;
    status: string;
    returnedNote?: string | null;
  }

  interface Recent {
    id: number;
    queryType: string;
    term: string;
    resultCount: number;
    hitCount: number;
    createdAt: string;
  }

  /**
   * A panel: not answered yet, answered, failed (said, with a retry, keeping
   * what was last shown), or refused -- and so not drawn.
   */
  type Panel<T> =
    | { state: 'loading' }
    | { state: 'ok'; data: T }
    | { state: 'failed'; err: ErrorCode; data?: T }
    | { state: 'hidden' };

  const ROWS = 4;
  /** A refusal of the session, as opposed to a request that failed. */
  const REFUSED = new Set<string>(['forbidden', 'restricted', 'no_session']);

  let unit = $state<Panel<Unit | null>>({ state: 'loading' });
  let calls = $state<Panel<Call[]>>({ state: 'loading' });
  let broadcasts = $state<Panel<Broadcast[]>>({ state: 'loading' });
  let reports = $state<Panel<Report[]>>({ state: 'loading' });
  let recent = $state<Panel<Recent[]>>({ state: 'loading' });
  let updatedAt = $state<Date | null>(null);

  const has = (module: string): boolean => session.modules.includes(module);

  async function ask<T, R>(
    route: string,
    input: Record<string, unknown>,
    pick: (data: R) => T,
    previous: Panel<T>,
  ): Promise<Panel<T>> {
    const response = await nui.call<R>(route, input);
    if (response.ok) return { state: 'ok', data: pick(response.data) };
    if (REFUSED.has(response.err)) return { state: 'hidden' };
    // Keep what was last shown, and say it could not be brought up to date.
    return previous.state === 'ok' || previous.state === 'failed'
      ? previous.data === undefined
        ? { state: 'failed', err: response.err }
        : { state: 'failed', err: response.err, data: previous.data }
      : { state: 'failed', err: response.err };
  }

  /** A report this officer may open -- a 4.5 stub has no id and no place here. */
  function isReport(row: Report | { restricted: true }): row is Report {
    return (row as Report).id !== undefined;
  }

    function dataOf<T>(panel: Panel<T>): T | undefined {
    return panel.state === 'ok' || panel.state === 'failed' ? panel.data : undefined;
  }

  async function load(): Promise<void> {
    const jobs: Promise<void>[] = [];

    if (has('dispatch')) {
      jobs.push(
        ask<Unit | null, { units: Unit[] }>(
          'unit.list',
          {},
          (data) => data.units.find((row) => row.callsign === session.callsign) ?? null,
          unit,
        ).then((next) => {
          unit = next;
        }),
        ask<Call[], { calls: Call[] }>('call.list', {}, (data) => data.calls, calls).then((next) => {
          calls = next;
        }),
        ask<Broadcast[], { broadcasts: Broadcast[] }>(
          'broadcast.list',
          {},
          (data) => data.broadcasts,
          broadcasts,
        ).then((next) => {
          broadcasts = next;
        }),
      );
    } else {
      unit = { state: 'hidden' };
      calls = { state: 'hidden' };
      broadcasts = { state: 'hidden' };
    }

    if (has('records')) {
      jobs.push(
        // What needs this officer's hand: sent back first, then drafts. Two
        // filtered asks rather than one page filtered here, which would miss
        // an old report sent back behind fifty newer ones.
        Promise.all([
          ask<Report[], { anmalningar: (Report | { restricted: true })[] }>(
            'anmalan.list',
            { mine: true, status: 'atersand', limit: ROWS },
            (data) => data.anmalningar.filter(isReport),
            reports,
          ),
          ask<Report[], { anmalningar: (Report | { restricted: true })[] }>(
            'anmalan.list',
            { mine: true, status: 'utkast', limit: ROWS },
            (data) => data.anmalningar.filter(isReport),
            reports,
          ),
        ]).then(([returned, drafts]) => {
          reports =
            returned.state === 'ok' && drafts.state === 'ok'
              ? { state: 'ok', data: [...returned.data, ...drafts.data].slice(0, ROWS) }
              : returned.state !== 'ok'
                ? returned
                : drafts;
        }),
        ask<Recent[], { entries: Recent[] }>(
          'query.log',
          { mine: true, limit: ROWS },
          (data) => data.entries,
          recent,
        ).then((next) => {
          recent = next;
        }),
      );
    } else {
      reports = { state: 'hidden' };
      recent = { state: 'hidden' };
    }

    await Promise.all(jobs);
    // "Updated" only when every panel shown was brought up to date.
    if (![unit, calls, broadcasts, reports, recent].some((panel) => panel.state === 'failed')) {
      updatedAt = new Date();
    }
  }

  void load();

  // F6 again: the same screen, brought up to date.
  $effect(() => nui.on('fredpd:open', () => void load()));

  const waitingCount = $derived(
    (dataOf(calls) ?? []).filter((call) => call.status === 'pending' || (call.unitCount ?? 0) === 0).length,
  );

  function openCall(callId: number | null): void {
    setIntent({ module: 'dispatch', ...(callId ? { callId } : {}) });
    onOpenModule('dispatch');
  }

  function openReport(id?: number): void {
    setIntent({ module: 'records', tab: 'anmalan', ...(id ? { anmalanId: id } : {}) });
    onOpenModule('records');
  }

  function openQuery(entry: Recent): void {
    setIntent({ module: 'records', tab: 'query', term: entry.term, type: entry.queryType });
    onOpenModule('records');
  }

  /** `21:14` when it was today, the full moment otherwise: the date is noise on a live screen. */
  function when(value: string): string {
    const formatted = formatMoment(value);
    const today = formatMoment(new Date().toISOString()).slice(0, 10);
    return formatted.startsWith(today) ? formatted.slice(11) : formatted;
  }

  const panelClass = 'border border-[var(--color-border)] p-3';
  const headerClass = 'mb-2 flex items-baseline justify-between gap-2';
  const titleClass = 'text-sm font-semibold';
  const linkClass =
    'shrink-0 whitespace-nowrap text-xs underline underline-offset-2 focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]';
  /** One line a row: a button across the whole row, columns fixed per panel. */
  const rowClass =
    'grid w-full items-baseline gap-x-2 border-t border-[var(--color-border)] py-1 text-left hover:bg-[var(--color-surface)] focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]';
  const muted = 'text-[var(--color-ink-muted)]';
  const mono = 'font-[family-name:var(--font-mono)]';
</script>

{#snippet failed(err: ErrorCode)}
  <p class="mb-1 flex items-baseline justify-between gap-2 text-[var(--color-alert)]" role="status">
    <span>{t(`error.${err}`)}</span>
    <button type="button" class={linkClass} onclick={() => void load()}>{t('overview.retry')}</button>
  </p>
{/snippet}

<div class="flex flex-col gap-3 text-xs">
  <div class="flex items-baseline justify-between gap-2 {muted}">
    <p>{updatedAt ? t('overview.updated', { time: when(updatedAt.toISOString()) }) : t('app.loading')}</p>
    <button type="button" class={linkClass} onclick={() => void load()}>{t('overview.refresh')}</button>
  </div>

  <div class="grid items-start gap-3 md:grid-cols-2">
    <!-- My shift: two lines -- who and on duty, then what the unit is doing. -->
    <section class={panelClass} aria-labelledby="overview-shift">
      <div class={headerClass}>
        <h2 id="overview-shift" class={titleClass}>{t('overview.shift.title')}</h2>
      </div>
      <p>
        {session.name} · <span class={mono}>{session.callsign ?? t('overview.shift.noCallsign')}</span> ·
        <span class:text-[var(--color-caution)]={!session.onDuty}>
          {session.onDuty ? t('shell.status.onDuty') : t('shell.status.offDuty')}
        </span>
      </p>
      {#if !session.onDuty}
        <p class={muted}>{t('overview.shift.offDutyHint')}</p>
      {/if}
      {#if unit.state === 'failed'}
        {@render failed(unit.err)}
      {:else if unit.state === 'ok' && unit.data}
        {@const own = unit.data}
        <p class="mt-1">
          {t(`cad.unitStatus.${own.status}`)}
          <span class={muted}>{t('overview.since', { time: when(own.statusSince) })}</span>
          ·
          {#if own.onCallId && own.onCallNumber}
            <button type="button" class={linkClass} onclick={() => openCall(own.onCallId)}>
              {t('overview.shift.onCall', { number: own.onCallNumber })}
            </button>
          {:else}
            <span class={muted}>{t('overview.shift.noCall')}</span>
          {/if}
        </p>
      {/if}
    </section>

    {#if broadcasts.state === 'ok' || broadcasts.state === 'failed'}
      {@const list = dataOf(broadcasts) ?? []}
      <section class={panelClass} aria-labelledby="overview-broadcasts">
        <div class={headerClass}>
          <h2 id="overview-broadcasts" class={titleClass}>{t('overview.broadcasts.title')}</h2>
          <button
            type="button"
            class={linkClass}
            aria-label={t('overview.openDispatchLabel')}
            onclick={() => openCall(null)}
          >
            {t('overview.all')}
          </button>
        </div>
        {#if broadcasts.state === 'failed'}{@render failed(broadcasts.err)}{/if}
        {#if list.length === 0 && broadcasts.state === 'ok'}
          <p class={muted}>{t('overview.broadcasts.none')}</p>
        {:else}
          <ul>
            {#each list.slice(0, ROWS) as entry (entry.id)}
              <li
                class="grid grid-cols-[auto_minmax(0,1fr)_auto] items-baseline gap-x-2 border-t border-[var(--color-border)] py-1 first:border-t-0"
              >
                <span class="font-semibold" class:text-[var(--color-alert)]={entry.priority === 1}>
                  {t(`cad.priorityShort.p${entry.priority}`)}
                </span>
                <span class="truncate">
                  {entry.title}{#if entry.plate}
                    · <span class={mono}>{entry.plate}</span>{/if}
                </span>
                <span class={muted}>{t(`cad.broadcastKind.${entry.kind}`)}</span>
              </li>
            {/each}
          </ul>
        {/if}
      </section>
    {/if}

    {#if calls.state === 'ok' || calls.state === 'failed'}
      {@const list = dataOf(calls) ?? []}
      <section class={panelClass} aria-labelledby="overview-calls" aria-describedby="overview-calls-count">
        <div class={headerClass}>
          <h2 id="overview-calls" class={titleClass}>{t('overview.calls.title')}</h2>
          <span id="overview-calls-count" class="min-w-0 flex-1 truncate {muted}">
            {t('overview.calls.counts', { open: list.length, waiting: waitingCount })}
          </span>
          <button
            type="button"
            class={linkClass}
            aria-label={t('overview.openDispatchLabel')}
            onclick={() => openCall(null)}
          >
            {t('overview.all')}
          </button>
        </div>
        {#if calls.state === 'failed'}{@render failed(calls.err)}{/if}
        {#if list.length === 0 && calls.state === 'ok'}
          <p class={muted}>{t('overview.calls.none')}</p>
        {:else}
          <ul>
            {#each list.slice(0, ROWS) as call (call.id)}
              <li class="first:[&>button]:border-t-0">
                <button
                  type="button"
                  class="{rowClass} grid-cols-[auto_minmax(0,1fr)_auto]"
                  aria-label={t('overview.calls.open', { number: call.callNumber })}
                  onclick={() => openCall(call.id)}
                >
                  <span class="font-semibold" class:text-[var(--color-alert)]={call.priority === 1}>
                    {t(`cad.priorityShort.p${call.priority}`)}
                  </span>
                  <span class="truncate">
                    {t(`cad.callType.${call.type}`)} ·
                    <span class={muted}>{call.locationText ?? t('overview.noLocation')}</span>
                  </span>
                  <span class={muted}>{t(`cad.callStatus.${call.status}`)}</span>
                </button>
              </li>
            {/each}
          </ul>
        {/if}
      </section>
    {/if}

    {#if reports.state === 'ok' || reports.state === 'failed'}
      {@const list = dataOf(reports) ?? []}
      <section class={panelClass} aria-labelledby="overview-reports">
        <div class={headerClass}>
          <h2 id="overview-reports" class={titleClass}>{t('overview.reports.title')}</h2>
          <button type="button" class={linkClass} aria-label={t('overview.reports.open')} onclick={() => openReport()}>
            {t('overview.all')}
          </button>
        </div>
        {#if reports.state === 'failed'}{@render failed(reports.err)}{/if}
        {#if list.length === 0 && reports.state === 'ok'}
          <p class={muted}>{t('overview.reports.none')}</p>
        {:else}
          <ul>
            {#each list as row (row.id)}
              <li class="first:[&>button]:border-t-0">
                <button
                  type="button"
                  class="{rowClass} grid-cols-[auto_minmax(0,1fr)_auto]"
                  aria-label={t('overview.reports.openOne', { number: row.number })}
                  onclick={() => openReport(row.id)}
                >
                  <span class={mono}>{row.number}</span>
                  <span class="truncate">
                    {row.title}{#if row.returnedNote}
                      · <span class={muted}>{row.returnedNote}</span>{/if}
                  </span>
                  <span
                    class:font-semibold={row.status === 'atersand'}
                    class:text-[var(--color-caution)]={row.status === 'atersand'}
                    class:text-[var(--color-ink-muted)]={row.status !== 'atersand'}
                  >
                    {t(`anmalan.status.${row.status}`)}
                  </span>
                </button>
              </li>
            {/each}
          </ul>
        {/if}
      </section>
    {/if}

    {#if recent.state === 'ok' || recent.state === 'failed'}
      {@const list = dataOf(recent) ?? []}
      <section class={panelClass} aria-labelledby="overview-recent">
        <div class={headerClass}>
          <h2 id="overview-recent" class={titleClass}>{t('overview.recent.title')}</h2>
        </div>
        {#if recent.state === 'failed'}{@render failed(recent.err)}{/if}
        {#if list.length === 0 && recent.state === 'ok'}
          <p class={muted}>{t('overview.recent.none')}</p>
        {:else}
          <ul>
            {#each list.slice(0, ROWS) as entry (entry.id)}
              <li class="first:[&>button]:border-t-0">
                <button
                  type="button"
                  class="{rowClass} grid-cols-[minmax(6rem,1fr)_auto_auto_auto]"
                  aria-label={t('overview.recent.again', { term: entry.term })}
                  onclick={() => openQuery(entry)}
                >
                  <span class="truncate {mono}">{entry.term}</span>
                  <span class="max-w-[7rem] truncate {muted}">{t(`query.type.${entry.queryType}`)}</span>
                  <span
                    class="whitespace-nowrap"
                    class:text-[var(--color-alert)]={entry.hitCount > 0}
                    class:font-semibold={entry.hitCount > 0}
                  >
                    {t('query.log.counts', { results: entry.resultCount, hits: entry.hitCount })}
                  </span>
                  <span class="whitespace-nowrap {muted}">{when(entry.createdAt)}</span>
                </button>
              </li>
            {/each}
          </ul>
        {/if}
      </section>
    {/if}
  </div>
</div>
