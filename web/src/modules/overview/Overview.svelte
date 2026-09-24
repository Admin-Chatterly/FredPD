<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { setIntent } from '../../lib/intent';
  import type { Session } from '../../lib/types';
  import type { Broadcast, Call, Unit } from '../cad/Dispatch.svelte';

  /**
   * Where F6 lands (spec 6.3): what this officer needs to know right now, on
   * one screen, before choosing a module.
   *
   * Five short panels, each answered by a route the officer's own module
   * already calls -- `unit.list`, `call.list`, `broadcast.list`,
   * `anmalan.list`, `query.log` -- so every one is checked on the server
   * exactly as it is there (invariant 4). A panel whose route refuses this
   * session is not drawn at all: the overview never says a register exists
   * that the officer may not open. Nothing here writes; every row hands over
   * to the module that does.
   *
   * Uncluttered by rule: at most four rows a panel, one line a row, the rest
   * one click away.
   */

  interface Props {
    session: Session;
    /** Switches the shell to a module (the rail's own action). */
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

  /** A panel's state: not asked yet, answered, or refused (and so not drawn). */
  type Panel<T> = { state: 'loading' } | { state: 'ok'; data: T } | { state: 'hidden' };

  const ROWS = 4;

  let unit = $state<Panel<Unit | null>>({ state: 'loading' });
  let myCalls = $state<Panel<Call[]>>({ state: 'loading' });
  let openCalls = $state<Panel<Call[]>>({ state: 'loading' });
  let broadcasts = $state<Panel<Broadcast[]>>({ state: 'loading' });
  let reports = $state<Panel<Report[]>>({ state: 'loading' });
  let recent = $state<Panel<Recent[]>>({ state: 'loading' });
  let updatedAt = $state<Date | null>(null);
  let loading = $state(false);

  async function panel<T, R>(route: string, input: Record<string, unknown>, pick: (data: R) => T): Promise<Panel<T>> {
    const response = await nui.call<R>(route, input);
    return response.ok ? { state: 'ok', data: pick(response.data) } : { state: 'hidden' };
  }

  async function load(): Promise<void> {
    if (loading) return;
    loading = true;

    const [unitPanel, mine, open, air, own, queries] = await Promise.all([
      panel<Unit | null, { units: Unit[] }>('unit.list', {}, (data) =>
        data.units.find((row) => row.callsign === session.callsign) ?? null,
      ),
      panel<Call[], { calls: Call[] }>('call.list', { mine: true }, (data) => data.calls),
      panel<Call[], { calls: Call[] }>('call.list', {}, (data) => data.calls),
      panel<Broadcast[], { broadcasts: Broadcast[] }>('broadcast.list', {}, (data) => data.broadcasts),
      panel<Report[], { anmalningar: Report[] }>('anmalan.list', { mine: true, limit: 50 }, (data) =>
        // What needs this officer's hand: sent back, or never sent.
        data.anmalningar.filter((row) => row.status === 'atersand' || row.status === 'utkast'),
      ),
      panel<Recent[], { entries: Recent[] }>('query.log', { mine: true, limit: ROWS }, (data) => data.entries),
    ]);

    unit = unitPanel;
    myCalls = mine;
    openCalls = open;
    broadcasts = air;
    reports = own;
    recent = queries;
    updatedAt = new Date();
    loading = false;
  }

  void load();

  // F6 again: the same screen, brought up to date.
  $effect(() => nui.on('fredpd:open', () => void load()));

  const currentCall = $derived(myCalls.state === 'ok' ? (myCalls.data[0] ?? null) : null);
  const waiting = $derived(
    openCalls.state === 'ok'
      ? openCalls.data.filter((call) => call.status === 'pending' || (call.unitCount ?? 0) === 0)
      : [],
  );
  const returned = $derived(reports.state === 'ok' ? reports.data.filter((row) => row.status === 'atersand') : []);
  const drafts = $derived(reports.state === 'ok' ? reports.data.filter((row) => row.status === 'utkast') : []);

  function openQuery(entry: Recent): void {
    setIntent({ module: 'records', tab: 'query', term: entry.term });
    onOpenModule('records');
  }

  function openReports(): void {
    setIntent({ module: 'records', tab: 'anmalan' });
    onOpenModule('records');
  }

  /** `21:14` when it was today, the full moment otherwise: the date is noise on a live screen. */
  function when(value: string): string {
    const formatted = formatMoment(value);
    const today = formatMoment(new Date().toISOString()).slice(0, 10);
    return formatted.startsWith(today) ? formatted.slice(11) : formatted;
  }

  function where(call: Call): string {
    return call.locationText ?? t('overview.noLocation');
  }

  const panelClass = 'border border-[var(--color-border)] p-3';
  const headingClass = 'mb-2 flex items-baseline justify-between gap-2 text-sm font-semibold';
  const linkClass =
    'text-xs font-normal underline underline-offset-2 hover:text-[var(--color-ink)] focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]';
  const rowClass = 'flex items-baseline justify-between gap-3 border-t border-[var(--color-border)] py-1 first:border-t-0';
  const subClass = 'block truncate text-[var(--color-ink-muted)]';
</script>

<div class="flex flex-col gap-3 text-xs">
  <div class="flex items-baseline justify-between gap-2 text-[var(--color-ink-muted)]">
    <p>{updatedAt ? t('overview.updated', { time: when(updatedAt.toISOString()) }) : t('app.loading')}</p>
    <button type="button" class={linkClass} disabled={loading} onclick={() => void load()}>
      {t('overview.refresh')}
    </button>
  </div>

  <div class="grid gap-3 md:grid-cols-2">
    <!-- My shift: who, which unit, on duty or not, and the call I am on. -->
    <section class={panelClass} aria-labelledby="overview-shift">
      <h2 id="overview-shift" class={headingClass}>{t('overview.shift.title')}</h2>
      <dl class="grid grid-cols-[8rem_1fr] gap-x-3 gap-y-1">
        <dt class="text-[var(--color-ink-muted)]">{t('overview.shift.officer')}</dt>
        <dd>{session.name}</dd>
        <dt class="text-[var(--color-ink-muted)]">{t('overview.shift.unit')}</dt>
        <dd class="font-[family-name:var(--font-mono)]">{session.callsign ?? t('overview.shift.noCallsign')}</dd>
        <dt class="text-[var(--color-ink-muted)]">{t('overview.shift.duty')}</dt>
        <dd>
          {session.onDuty ? t('shell.status.onDuty') : t('shell.status.offDuty')}
          {#if !session.onDuty}
            <span class="block text-[var(--color-ink-muted)]">{t('overview.shift.offDutyHint')}</span>
          {/if}
        </dd>
        {#if unit.state === 'ok' && unit.data}
          <dt class="text-[var(--color-ink-muted)]">{t('overview.shift.status')}</dt>
          <dd>
            {t(`cad.unitStatus.${unit.data.status}`)}
            <span class="text-[var(--color-ink-muted)]">· {t('overview.since', { time: when(unit.data.statusSince) })}</span>
          </dd>
        {/if}
        {#if myCalls.state === 'ok'}
          <dt class="text-[var(--color-ink-muted)]">{t('overview.shift.call')}</dt>
          <dd>
            {#if currentCall}
              <button type="button" class={linkClass} onclick={() => onOpenModule('dispatch')}>
                <span class="font-[family-name:var(--font-mono)]">{currentCall.callNumber}</span>
                · {t(`cad.priorityShort.p${currentCall.priority}`)} · {t(`cad.callType.${currentCall.type}`)}
              </button>
              <span class="block text-[var(--color-ink-muted)]">{where(currentCall)}</span>
            {:else}
              <span class="text-[var(--color-ink-muted)]">{t('overview.shift.noCall')}</span>
            {/if}
          </dd>
        {/if}
      </dl>
    </section>

    {#if broadcasts.state === 'ok'}
      <section class={panelClass} aria-labelledby="overview-broadcasts">
        <h2 id="overview-broadcasts" class={headingClass}>
          <span>{t('overview.broadcasts.title')} <span class="font-normal text-[var(--color-ink-muted)]">({broadcasts.data.length})</span></span>
          {#if broadcasts.data.length > ROWS}
            <button type="button" class={linkClass} onclick={() => onOpenModule('dispatch')}>{t('overview.all')}</button>
          {/if}
        </h2>
        {#if broadcasts.data.length === 0}
          <p class="text-[var(--color-ink-muted)]">{t('overview.broadcasts.none')}</p>
        {:else}
          <ul>
            {#each broadcasts.data.slice(0, ROWS) as entry (entry.id)}
              <li class={rowClass}>
                <span class="min-w-0">
                  <span class="block truncate">{entry.title}</span>
                  <span class={subClass}>
                    {t(`cad.broadcastKind.${entry.kind}`)}{#if entry.plate} · <span class="font-[family-name:var(--font-mono)]">{entry.plate}</span>{/if}
                  </span>
                </span>
                <span class="shrink-0 text-[var(--color-ink-muted)]">{t(`cad.priorityShort.p${entry.priority}`)}</span>
              </li>
            {/each}
          </ul>
        {/if}
      </section>
    {/if}

    {#if openCalls.state === 'ok'}
      <section class={panelClass} aria-labelledby="overview-calls">
        <h2 id="overview-calls" class={headingClass}>
          <span>
            {t('overview.calls.title')}
            <span class="font-normal text-[var(--color-ink-muted)]">
              {t('overview.calls.counts', { open: openCalls.data.length, waiting: waiting.length })}
            </span>
          </span>
          <button type="button" class="{linkClass} shrink-0 whitespace-nowrap" onclick={() => onOpenModule('dispatch')}>
            {t('overview.openDispatch')}
          </button>
        </h2>
        {#if openCalls.data.length === 0}
          <p class="text-[var(--color-ink-muted)]">{t('overview.calls.none')}</p>
        {:else}
          <ul>
            {#each openCalls.data.slice(0, ROWS) as call (call.id)}
              <li class={rowClass}>
                <span class="min-w-0">
                  <span class="block truncate">{t(`cad.callType.${call.type}`)}</span>
                  <span class={subClass}>
                    <span class="font-[family-name:var(--font-mono)]">{call.callNumber}</span> · {where(call)}
                  </span>
                </span>
                <span class="shrink-0 text-right">
                  <span class="block font-semibold">{t(`cad.priorityShort.p${call.priority}`)}</span>
                  <span class="block text-[var(--color-ink-muted)]">{t(`cad.callStatus.${call.status}`)}</span>
                </span>
              </li>
            {/each}
          </ul>
        {/if}
      </section>
    {/if}

    {#if reports.state === 'ok'}
      <section class={panelClass} aria-labelledby="overview-reports">
        <h2 id="overview-reports" class={headingClass}>
          <span>{t('overview.reports.title')}</span>
          <button type="button" class="{linkClass} shrink-0 whitespace-nowrap" onclick={openReports}>
            {t('overview.reports.open')}
          </button>
        </h2>
        {#if returned.length === 0 && drafts.length === 0}
          <p class="text-[var(--color-ink-muted)]">{t('overview.reports.none')}</p>
        {:else}
          <p class="mb-1">{t('overview.reports.counts', { returned: returned.length, drafts: drafts.length })}</p>
          <ul>
            {#each [...returned, ...drafts].slice(0, ROWS) as row (row.id)}
              <li class={rowClass}>
                <span class="min-w-0">
                  <span class="block truncate">{row.title}</span>
                  <span class={subClass}>
                    <span class="font-[family-name:var(--font-mono)]">{row.number}</span>{#if row.returnedNote} · {row.returnedNote}{/if}
                  </span>
                </span>
                <span class="shrink-0" class:font-semibold={row.status === 'atersand'}>{t(`anmalan.status.${row.status}`)}</span>
              </li>
            {/each}
          </ul>
        {/if}
      </section>
    {/if}

    {#if recent.state === 'ok'}
      <section class={panelClass} aria-labelledby="overview-recent">
        <h2 id="overview-recent" class={headingClass}>{t('overview.recent.title')}</h2>
        {#if recent.data.length === 0}
          <p class="text-[var(--color-ink-muted)]">{t('overview.recent.none')}</p>
        {:else}
          <ul>
            {#each recent.data.slice(0, ROWS) as entry (entry.id)}
              <li class={rowClass}>
                <button
                  type="button"
                  class="{linkClass} min-w-0 truncate text-left"
                  aria-label={t('overview.recent.again', { term: entry.term })}
                  onclick={() => openQuery(entry)}
                >
                  {entry.term}
                </button>
                <span class="shrink-0 text-[var(--color-ink-muted)]">
                  {t('overview.recent.results', { count: entry.resultCount })}{entry.hitCount > 0
                    ? ` · ${t('overview.recent.hits', { count: entry.hitCount })}`
                    : ''} · {when(entry.createdAt)}
                </span>
              </li>
            {/each}
          </ul>
        {/if}
      </section>
    {/if}
  </div>
</div>
