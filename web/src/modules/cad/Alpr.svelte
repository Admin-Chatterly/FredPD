<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { HOTLIST_REASONS } from '@fredpd/schema';
  import type { ErrorCode } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import { stamp } from './Dispatch.svelte';

  /**
   * ALPR: plate reads and the hotlist that turns one into a banner (spec 7.18).
   *
   * A read is not the secret — a camera saw a car. What must never reach a
   * subject is that the car is watched, so a silent hotlist entry (section 9)
   * is server-side masked out of `alpr.read.list` for every session but the
   * one that created it — this screen draws exactly what the route sends and
   * decides nothing about who may see a covert watch (invariant 4). The hit
   * banner below the filters is client-local and dismissible per viewer; it is
   * derived from the same list, not a second, louder read.
   */

  interface AlprRead {
    id: number;
    plate: string;
    readAt: string;
    readAtUnix: number;
    x: number;
    y: number;
    z: number;
    officerId: number | null;
    discordId: string | null;
    callsign: string | null;
    camera: string;
    hit: boolean;
    hotlistId: number | null;
    hotlistReason: string | null;
  }

  interface HotlistEntry {
    id: number;
    plate: string;
    reason: string;
    detail: string | null;
    caseNumber: string | null;
    silent: boolean;
    expiresAt: string | null;
    cancelledAt: string | null;
    cancelledBy: string | null;
    createdBy: string;
    createdAt: string;
  }

  const SINCE_HOURS_OPTIONS = ['1', '4', '24', '72', '168', '720'];

  const FIELD_LABELS: Record<string, string> = {
    plate: 'alpr.hotlist.plate',
    reason: 'alpr.hotlist.reason',
    note: 'alpr.hotlist.note',
    caseNumber: 'alpr.hotlist.case',
    expiresInMinutes: 'alpr.hotlist.expiresIn',
  };

  // ---------------------------------------------------------------- reads

  let reads = $state<AlprRead[]>([]);
  let readsError = $state<ErrorCode | null>(null);
  let readsLoading = $state(true);

  let plateFilter = $state('');
  let unitFilter = $state('');
  let sinceHours = $state('24');
  let hitsOnly = $state(false);

  let dismissedHits = $state<Set<number>>(new Set());

  const liveHits = $derived(reads.filter((row) => row.hit && !dismissedHits.has(row.id)));

  async function loadReads(): Promise<void> {
    readsLoading = true;

    const response = await nui.call<{ reads: AlprRead[] }>('alpr.read.list', {
      plate: plateFilter || undefined,
      officerId: unitFilter ? Number(unitFilter) : undefined,
      sinceHours: Number(sinceHours),
      hitsOnly: hitsOnly || undefined,
      limit: 100,
    });

    if (response.ok) {
      reads = response.data.reads;
      readsError = null;
    } else {
      readsError = response.err;
    }

    readsLoading = false;
  }

  function applyReadFilter(event: SubmitEvent): void {
    event.preventDefault();
    void loadReads();
  }

  function dismissHit(id: number): void {
    dismissedHits = new Set([...dismissedHits, id]);
  }

  /** A read carries a position, never an address — this is what a camera saw. */
  function locationOf(row: AlprRead): string {
    return `${Math.round(row.x)}, ${Math.round(row.y)}`;
  }

  // -------------------------------------------------------------- hotlist

  let hotlist = $state<HotlistEntry[]>([]);
  let hotlistError = $state<ErrorCode | null>(null);
  let hotlistLoading = $state(true);

  let busy = $state(false);
  let failure = $state<Failure | null>(null);
  let formOpen = $state(false);

  const FIRST_REASON: string = HOTLIST_REASONS[0];

  let draft = $state({
    plate: '',
    reason: FIRST_REASON,
    note: '',
    caseNumber: '',
    expiresInMinutes: '',
    silent: false,
  });

  async function loadHotlist(): Promise<void> {
    hotlistLoading = true;

    const response = await nui.call<{ entries: HotlistEntry[] }>('alpr.hotlist.list', { limit: 100 });

    if (response.ok) {
      hotlist = response.data.entries;
      hotlistError = null;
    } else {
      hotlistError = response.err;
    }

    hotlistLoading = false;
  }

  function resetDraft(): void {
    draft = {
      plate: '',
      reason: FIRST_REASON,
      note: '',
      caseNumber: '',
      expiresInMinutes: '',
      silent: false,
    };
  }

  async function addToHotlist(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    busy = true;

    const response = await nui.call('alpr.hotlist.edit', {
      plate: draft.plate,
      reason: draft.reason,
      note: draft.note || undefined,
      caseNumber: draft.caseNumber || undefined,
      expiresInMinutes: draft.expiresInMinutes ? Number(draft.expiresInMinutes) : undefined,
      silent: draft.silent || undefined,
    });

    if (response.ok) {
      failure = null;
      formOpen = false;
      resetDraft();
      // Both: a plate just listed may already explain a read sitting in the
      // table above, and the read list is the only place that hit is drawn.
      await Promise.all([loadHotlist(), loadReads()]);
    } else {
      failure = response;
    }

    busy = false;
  }

  let removing = $state<HotlistEntry | null>(null);
  let trigger: HTMLButtonElement | null = null;

  function askRemove(entry: HotlistEntry, event: MouseEvent): void {
    removing = entry;
    failure = null;
    trigger = event.currentTarget as HTMLButtonElement;
  }

  function cancelRemove(): void {
    removing = null;
    failure = null;
    trigger?.focus();
  }

  async function removeFromHotlist(): Promise<void> {
    const entry = removing;
    if (!entry) return;

    busy = true;

    const response = await nui.call('alpr.hotlist.edit', {
      plate: entry.plate,
      remove: true,
      reason: entry.reason,
    });

    if (response.ok) {
      failure = null;
      removing = null;
      await loadHotlist();
    } else {
      failure = response;
    }

    busy = false;
  }

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  void loadReads();
  void loadHotlist();
</script>

<div class="flex min-h-0 flex-1 gap-3">
  <section class="flex min-h-0 flex-1 flex-col gap-3 border border-[var(--color-border)] p-3">
    <h2 class="text-sm font-semibold">{t('alpr.title')}</h2>
    <p class="text-xs text-[var(--color-ink-muted)]">{t('alpr.intro')}</p>

    {#if liveHits.length > 0}
      <div class="flex flex-col gap-1 border border-[var(--color-alert)] p-2 text-xs">
        <h3 class="font-semibold">{t('alpr.hit.title')}</h3>
        {#each liveHits as row (row.id)}
          <div class="flex items-center justify-between gap-2">
            <span>
              {t('alpr.hit.banner', {
                plate: row.plate,
                reason: row.hotlistReason ? t(`alpr.reason.${row.hotlistReason}`) : '',
              })}
            </span>
            <button
              type="button"
              class="border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-surface)]"
              onclick={() => dismissHit(row.id)}
            >
              {t('alpr.hit.dismiss')}
            </button>
          </div>
        {/each}
        <p class="text-[var(--color-ink-muted)]">{t('alpr.hit.advice')}</p>
      </div>
    {/if}

    <form class="flex flex-wrap items-end gap-2" onsubmit={applyReadFilter}>
      <label class="flex flex-col gap-1 text-xs">
        {t('alpr.filter.plate')}
        <input
          type="text"
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={plateFilter}
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        {t('alpr.filter.unit')}
        <input
          type="number"
          min="1"
          class="w-20 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={unitFilter}
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        {t('alpr.filter.since')}
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={sinceHours}
        >
          {#each SINCE_HOURS_OPTIONS as hours (hours)}
            <option value={hours}>{t('alpr.filter.sinceHours', { hours })}</option>
          {/each}
        </select>
      </label>

      <label class="flex items-center gap-1 text-xs">
        <input type="checkbox" bind:checked={hitsOnly} />
        {t('alpr.filter.hitsOnly')}
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1 text-xs"
        disabled={readsLoading}
      >
        {t('alpr.filter.apply')}
      </button>
    </form>

    {#if readsError}
      <p class="border border-[var(--color-border)] px-3 py-2 text-xs">{t(`error.${readsError}`)}</p>
    {/if}

    {#if readsLoading}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
    {:else if reads.length === 0}
      <p class="border border-[var(--color-border)] px-3 py-2 text-xs text-[var(--color-ink-muted)]">
        {t('alpr.empty')}
      </p>
    {:else}
      <div class="min-h-0 flex-1 overflow-y-auto">
        <table class="w-full text-left text-xs">
          <thead>
            <tr class="border-b border-[var(--color-border)]">
              <th class="py-1 pr-2 font-medium">{t('alpr.column.time')}</th>
              <th class="py-1 pr-2 font-medium">{t('alpr.column.plate')}</th>
              <th class="py-1 pr-2 font-medium">{t('alpr.column.unit')}</th>
              <th class="py-1 pr-2 font-medium">{t('alpr.column.callsign')}</th>
              <th class="py-1 pr-2 font-medium">{t('alpr.column.location')}</th>
              <th class="py-1 pr-2 font-medium">{t('alpr.column.camera')}</th>
              <th class="py-1 pr-2 font-medium">{t('alpr.column.hit')}</th>
              <th class="py-1 font-medium">{t('alpr.column.reason')}</th>
            </tr>
          </thead>
          <tbody>
            {#each reads as row (row.id)}
              <tr
                class="border-b border-[var(--color-border)]"
                class:text-[var(--color-alert)]={row.hit}
              >
                <td class="py-1 pr-2 font-[family-name:var(--font-mono)]">{stamp(row.readAt)}</td>
                <td class="py-1 pr-2 font-[family-name:var(--font-mono)]">{row.plate}</td>
                <td class="py-1 pr-2">{row.officerId ?? ''}</td>
                <td class="py-1 pr-2">{row.callsign ?? ''}</td>
                <td class="py-1 pr-2 font-[family-name:var(--font-mono)]">{locationOf(row)}</td>
                <td class="py-1 pr-2">{t(`alpr.camera.${row.camera}`)}</td>
                <td class="py-1 pr-2">{row.hit ? t('alpr.hit.title') : ''}</td>
                <td class="py-1">{row.hotlistReason ? t(`alpr.reason.${row.hotlistReason}`) : ''}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}
  </section>

  <section class="flex w-96 shrink-0 flex-col gap-3 border border-[var(--color-border)] p-3">
    <header class="flex items-center justify-between gap-2">
      <h2 class="text-sm font-semibold">{t('alpr.hotlist.title')}</h2>
      <button
        type="button"
        class="border border-[var(--color-border)] px-3 py-1 text-xs hover:bg-[var(--color-surface)]"
        onclick={() => (formOpen = !formOpen)}
      >
        {t('alpr.hotlist.add')}
      </button>
    </header>

    <p class="text-xs text-[var(--color-ink-muted)]">{t('alpr.hotlist.intro')}</p>

    {#if failure && !removing}
      <div class="border border-[var(--color-alert)] px-2 py-1 text-xs">
        <p class="font-semibold">{t(`error.${failure.err}`)}</p>
        {#each messages as message (message.name)}
          <p class="text-[var(--color-alert)]">{message.label} — {message.reason}</p>
        {/each}
      </div>
    {/if}

    {#if formOpen}
      <form class="flex flex-col gap-2 border border-[var(--color-border)] p-2 text-xs" onsubmit={addToHotlist}>
        <label class="flex items-center gap-2">
          <span class="w-24 shrink-0 text-[var(--color-ink-muted)]">{t('alpr.hotlist.plate')}</span>
          <input
            type="text"
            class="min-w-0 flex-1 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
            bind:value={draft.plate}
          />
        </label>

        <label class="flex items-center gap-2">
          <span class="w-24 shrink-0 text-[var(--color-ink-muted)]">{t('alpr.hotlist.reason')}</span>
          <select
            class="min-w-0 flex-1 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={draft.reason}
          >
            {#each HOTLIST_REASONS as reason (reason)}
              <option value={reason}>{t(`alpr.reason.${reason}`)}</option>
            {/each}
          </select>
        </label>

        <label class="flex items-center gap-2">
          <span class="w-24 shrink-0 text-[var(--color-ink-muted)]">{t('alpr.hotlist.note')}</span>
          <input
            type="text"
            class="min-w-0 flex-1 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={draft.note}
          />
        </label>

        <label class="flex items-center gap-2">
          <span class="w-24 shrink-0 text-[var(--color-ink-muted)]">{t('alpr.hotlist.case')}</span>
          <input
            type="text"
            class="min-w-0 flex-1 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={draft.caseNumber}
          />
        </label>

        <label class="flex items-center gap-2">
          <span class="w-24 shrink-0 text-[var(--color-ink-muted)]">{t('alpr.hotlist.expiresIn')}</span>
          <input
            type="number"
            min="5"
            max="43200"
            class="min-w-0 flex-1 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={draft.expiresInMinutes}
          />
        </label>
        <p class="text-[var(--color-ink-muted)]">{t('alpr.hotlist.expiresInHint')}</p>

        <label class="flex items-center gap-2">
          <input type="checkbox" bind:checked={draft.silent} />
          <span>{t('alpr.hotlist.silent')}</span>
        </label>
        <p class="text-[var(--color-ink-muted)]">{t('alpr.hotlist.silentHint')}</p>

        <button
          type="submit"
          class="self-start border border-[var(--color-border)] px-3 py-1 font-semibold hover:bg-[var(--color-surface)]"
          disabled={busy}
        >
          {t('alpr.hotlist.submit')}
        </button>
      </form>
    {/if}

    {#if hotlistError}
      <p class="border border-[var(--color-border)] px-3 py-2 text-xs">{t(`error.${hotlistError}`)}</p>
    {/if}

    {#if hotlistLoading}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
    {:else if hotlist.length === 0}
      <p class="border border-[var(--color-border)] px-3 py-2 text-xs text-[var(--color-ink-muted)]">
        {t('alpr.hotlist.empty')}
      </p>
    {:else}
      <ul class="flex min-h-0 flex-1 flex-col overflow-y-auto">
        {#each hotlist as entry (entry.id)}
          <li class="border border-b-0 border-[var(--color-border)] px-2 py-1.5 text-xs last:border-b">
            <div class="flex flex-wrap items-baseline gap-2">
              <span class="font-[family-name:var(--font-mono)] font-semibold">{entry.plate}</span>
              <span class="text-[var(--color-ink-muted)]">{t(`alpr.reason.${entry.reason}`)}</span>
              {#if entry.silent}
                <span class="text-[var(--color-alert)]">{t('alpr.hotlist.silent')}</span>
              {/if}
              <button
                type="button"
                class="ml-auto border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-surface)]"
                onclick={(event) => askRemove(entry, event)}
              >
                {t('alpr.hotlist.remove')}
              </button>
            </div>

            {#if entry.detail}
              <p class="mt-1">{t('alpr.column.note')} — {entry.detail}</p>
            {/if}

            <div class="mt-1 flex flex-wrap gap-3 text-[var(--color-ink-muted)]">
              {#if entry.caseNumber}
                <span>{t('alpr.column.case')} {entry.caseNumber}</span>
              {/if}
              {#if entry.expiresAt}
                <span>{t('alpr.column.expires')} {stamp(entry.expiresAt)}</span>
              {/if}
              <span>{t('alpr.column.added')} {stamp(entry.createdAt)}</span>
              <span>{t('alpr.column.addedBy')} {entry.createdBy}</span>
            </div>
          </li>
        {/each}
      </ul>
    {/if}

    {#if removing}
      <ConfirmDialog
        label={t('alpr.hotlist.remove')}
        question={t('alpr.hotlist.removeConfirm', { plate: removing.plate })}
        {busy}
        {failure}
        fieldLabels={FIELD_LABELS}
        confirm={() => void removeFromHotlist()}
        cancel={cancelRemove}
      />
    {/if}
  </section>
</div>
