<script lang="ts">
  import { tick } from 'svelte';
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import { PUBLIC_REPORT_STATUSES, type PublicReportKind, type PublicReportStatus } from '@fredpd/schema';

  /**
   * Reports from the public (spec 7.29): what was handed in at a front desk.
   *
   * The server decides which kinds this session sees -- a complaint about the
   * police only reaches internal affairs -- and re-checks both that and who
   * may close one on every action. This draws what came back.
   */

  interface PublicReport {
    id: number;
    number: string;
    kind: PublicReportKind;
    reporterName: string;
    reporterPersonId?: number | null;
    occurredAt?: number | null;
    place?: string | null;
    description: string;
    property?: string | null;
    status: PublicReportStatus;
    handledNote?: string | null;
    handledAt?: number | null;
    version: number;
    createdAt: number;
  }

  interface Props {
    /** Opens the reporter's person record, when the register has one. */
    onOpenPerson?: (id: number) => void;
  }

  let { onOpenPerson }: Props = $props();

  const FIELD_LABELS: Record<string, string> = {
    note: 'public.inbox.handledNote',
    version: 'public.inbox.title',
  };

  let rows = $state<PublicReport[]>([]);
  let filter = $state<PublicReportStatus | ''>('received');
  let selected = $state<PublicReport | null>(null);
  let failure = $state<Failure | null>(null);
  let status = $state('');
  let busy = $state(false);

  let pending = $state<'handled' | 'rejected' | null>(null);
  let note = $state('');
  let trigger: HTMLButtonElement | null = null;

  async function load(): Promise<void> {
    const response = await nui.call<{ reports: PublicReport[] }>(
      'public.report.list',
      filter ? { status: filter } : {},
    );
    if (response.ok) {
      rows = response.data.reports;
      failure = null;
      if (selected) selected = rows.find((row) => row.id === selected?.id) ?? null;
    } else {
      failure = response;
    }
  }

  $effect(() => {
    void filter;
    void load();
  });

  function ask(outcome: 'handled' | 'rejected', event: MouseEvent): void {
    trigger = event.currentTarget as HTMLButtonElement;
    note = '';
    failure = null;
    pending = outcome;
  }

  async function cancel(): Promise<void> {
    pending = null;
    failure = null;
    await tick();
    trigger?.focus();
  }

  async function confirm(): Promise<void> {
    if (!selected || !pending || busy) return;
    busy = true;

    const response = await nui.call<{ number: string }>('public.report.handle', {
      id: selected.id,
      version: selected.version,
      outcome: pending,
      ...(note.trim() ? { note: note.trim() } : {}),
    });

    busy = false;

    if (!response.ok) {
      failure = response;
      return;
    }

    pending = null;
    status = t('public.inbox.done', { number: response.data.number });
    await load();
  }

  const button =
    'border border-[var(--color-border)] px-3 py-1 focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]';
</script>

<div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]">
  <section aria-labelledby="public-inbox-title">
    <div class="mb-2 flex items-end justify-between gap-2">
      <h2 id="public-inbox-title" class="text-sm font-semibold">{t('public.inbox.title')}</h2>
      <label class="flex items-center gap-1 text-xs">
        {t('public.inbox.filter')}
        <select bind:value={filter} class="border border-[var(--color-border)] px-2 py-1">
          {#each PUBLIC_REPORT_STATUSES as value (value)}
            <option {value}>{t(`public.status.${value}`)}</option>
          {/each}
          <option value="">{t('public.inbox.all')}</option>
        </select>
      </label>
    </div>

    {#if rows.length === 0}
      <p class="text-xs text-[var(--color-ink-muted)]">{t('public.inbox.none')}</p>
    {:else}
      <ul class="text-xs">
        {#each rows as row (row.id)}
          <li class="border-t border-[var(--color-border)]">
            <button
              type="button"
              class="flex w-full items-center justify-between gap-2 px-2 py-1 text-left focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
              class:font-semibold={selected?.id === row.id}
              aria-current={selected?.id === row.id ? 'true' : undefined}
              onclick={() => {
                selected = row;
                status = '';
              }}
            >
              <span class="font-[family-name:var(--font-mono)]">{row.number}</span>
              <span>{t(`public.kind.${row.kind}`)}</span>
              <span class="text-[var(--color-ink-muted)]">{formatMoment(row.createdAt)}</span>
            </button>
          </li>
        {/each}
      </ul>
    {/if}
  </section>

  <section class="border border-[var(--color-border)] p-3 text-xs" aria-live="polite">
    {#if status}
      <p class="mb-2 text-[var(--color-ink-muted)]" role="status">{status}</p>
    {/if}
    {#if failure && !pending}
      <div class="mb-2 border border-[var(--color-alert)] px-2 py-1" role="alert">
        <p>{t(`error.${failure.err}`)}</p>
      </div>
    {/if}

    {#if selected}
      <h3 class="mb-2 text-sm font-semibold">
        <span class="font-[family-name:var(--font-mono)]">{selected.number}</span>
        — {t(`public.kind.${selected.kind}`)} · {t(`public.status.${selected.status}`)}
      </h3>
      <dl class="mb-3 grid grid-cols-[9rem_1fr] gap-x-3 gap-y-1">
        <dt class="text-[var(--color-ink-muted)]">{t('public.inbox.reporter')}</dt>
        <dd>
          {#if selected.reporterPersonId && onOpenPerson}
            <button
              type="button"
              class="underline focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
              onclick={() => selected?.reporterPersonId && onOpenPerson?.(selected.reporterPersonId)}
            >
              {selected.reporterName}
            </button>
          {:else}
            {selected.reporterName}
            <span class="text-[var(--color-ink-muted)]">({t('public.inbox.unregistered')})</span>
          {/if}
        </dd>
        {#if selected.occurredAt}
          <dt class="text-[var(--color-ink-muted)]">{t('public.inbox.occurredAt')}</dt>
          <dd>{formatMoment(selected.occurredAt)}</dd>
        {/if}
        {#if selected.place}
          <dt class="text-[var(--color-ink-muted)]">{t('public.inbox.place')}</dt>
          <dd>{selected.place}</dd>
        {/if}
        {#if selected.property}
          <dt class="text-[var(--color-ink-muted)]">{t('public.inbox.property')}</dt>
          <dd class="whitespace-pre-wrap">{selected.property}</dd>
        {/if}
        <dt class="text-[var(--color-ink-muted)]">{t('public.inbox.description')}</dt>
        <dd class="whitespace-pre-wrap">{selected.description}</dd>
        {#if selected.handledNote}
          <dt class="text-[var(--color-ink-muted)]">{t('public.inbox.handledNote')}</dt>
          <dd class="whitespace-pre-wrap">{selected.handledNote}</dd>
        {/if}
      </dl>

      {#if selected.status === 'received'}
        {#if pending}
          <ConfirmDialog
            label={t(pending === 'handled' ? 'public.inbox.handle' : 'public.inbox.reject')}
            question={t(pending === 'handled' ? 'public.inbox.confirmHandle' : 'public.inbox.confirmReject', {
              number: selected.number,
            })}
            {busy}
            {failure}
            fieldLabels={FIELD_LABELS}
            confirm={() => void confirm()}
            cancel={() => void cancel()}
          >
            <label class="mt-2 flex flex-col gap-1">
              {t('public.inbox.handledNote')}
              <textarea bind:value={note} maxlength="500" rows="2" class="border border-[var(--color-border)] px-2 py-1"
              ></textarea>
            </label>
          </ConfirmDialog>
        {:else}
          <div class="flex gap-2">
            <button type="button" class={button} onclick={(event) => ask('handled', event)}>
              {t('public.inbox.handle')}
            </button>
            <button type="button" class={button} onclick={(event) => ask('rejected', event)}>
              {t('public.inbox.reject')}
            </button>
          </div>
        {/if}
      {/if}
    {/if}
  </section>
</div>
