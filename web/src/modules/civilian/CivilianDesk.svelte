<script lang="ts">
  import { tick } from 'svelte';
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatDate, formatMoment } from '../../lib/time';
  import { fieldList, type Failure } from '../shared/failure';
  import { PUBLIC_REPORT_KINDS, type PublicReportKind, type PublicReportStatus } from '@fredpd/schema';

  /**
   * A police front desk (spec 7.29): what any player -- officer or not --
   * sees of their own records, and where they hand in a report.
   *
   * Everything here is the server's answer about the player standing at the
   * desk; nothing is asked for by name or number, so there is nothing here to
   * look anybody else up with (invariant 1). The desk is not the MDT: it opens
   * on its own, with the MDT hidden, like a paper copy.
   */

  interface Citation {
    number: string;
    offence: string;
    amount: number;
    issuedAt: number;
    dueAt: number;
    status: string;
  }

  interface CourtCase {
    number: string;
    beslut: string;
    decidedAt: number;
    disposition?: string | null;
    sentenceMonths?: number | null;
    sentenceLivstid?: boolean;
    dispositionAt?: number | null;
  }

  interface MyReport {
    number: string;
    kind: PublicReportKind;
    status: PublicReportStatus;
    createdAt: number;
  }

  interface Overview {
    name: string;
    citations: Citation[];
    court: CourtCase[];
    reports: MyReport[];
  }

  interface Props {
    placementId: number;
    /** Leave the desk: the client lets go of the focus, which closes it. */
    onClose: () => void;
  }

  let { placementId, onClose }: Props = $props();

  const FIELD_LABELS: Record<string, string> = {
    kind: 'civilian.form.kind',
    occurredAt: 'civilian.form.occurredAt',
    place: 'civilian.form.place',
    property: 'civilian.form.property',
    description: 'civilian.form.description',
    placementId: 'civilian.title',
  };

  let overview = $state<Overview | null>(null);
  let failure = $state<Failure | null>(null);
  let tab = $state<'mine' | 'report'>('mine');
  let busy = $state(false);
  let status = $state('');
  let heading = $state<HTMLHeadingElement | null>(null);

  let form = $state({ kind: 'stolen_property' as PublicReportKind, occurredAt: '', place: '', property: '', description: '' });

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  async function load(): Promise<void> {
    const response = await nui.call<Overview>('civilian.overview', { placementId });
    if (response.ok) {
      overview = response.data;
      failure = null;
    } else {
      failure = response;
    }
  }

  $effect(() => {
    void placementId;
    void load();
  });

  $effect(() => {
    heading?.focus();
  });

  /** A `datetime-local` value as epoch seconds, or undefined. */
  function toEpoch(value: string): number | undefined {
    if (!value) return undefined;
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? undefined : Math.floor(date.getTime() / 1000);
  }

  async function submit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy) return;
    busy = true;
    status = '';

    const occurredAt = toEpoch(form.occurredAt);
    const response = await nui.call<{ number: string }>('civilian.report.create', {
      placementId,
      kind: form.kind,
      description: form.description,
      ...(form.place.trim() ? { place: form.place } : {}),
      ...(form.kind === 'stolen_property' && form.property.trim() ? { property: form.property } : {}),
      ...(occurredAt ? { occurredAt } : {}),
    });

    busy = false;

    if (!response.ok) {
      failure = response;
      return;
    }

    failure = null;
    status = t('civilian.received', { number: response.data.number });
    form = { kind: 'stolen_property', occurredAt: '', place: '', property: '', description: '' };
    tab = 'mine';
    await load();
    await tick();
    heading?.focus();
  }

  function verdict(row: CourtCase): string {
    if (!row.disposition) return row.beslut === 'atalad' ? t('court.disposition.pending') : '';
    return t(`court.disposition.${row.disposition}`);
  }

  function sentence(row: CourtCase): string {
    if (row.sentenceLivstid) return t('civilian.court.life');
    return row.sentenceMonths ? t('civilian.court.months', { months: row.sentenceMonths }) : '';
  }

  const field =
    'border border-[var(--color-border)] px-2 py-1 focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]';
  const button =
    'border border-[var(--color-border)] px-3 py-1 focus-visible:outline-2 focus-visible:outline-[var(--color-focus)] aria-disabled:opacity-60';
</script>

<div class="fixed inset-0 flex items-center justify-center p-4">
  <section
    class="flex max-h-full w-full max-w-3xl flex-col border border-[var(--color-border)] bg-[var(--color-panel)] text-[var(--color-ink)]"
    aria-labelledby="civilian-title"
  >
    <header class="flex items-start justify-between gap-4 border-b border-[var(--color-border)] px-5 py-3">
      <div>
        <h1
          id="civilian-title"
          bind:this={heading}
          tabindex="-1"
          class="text-[17px] font-semibold outline-offset-2 focus-visible:outline focus-visible:outline-[var(--color-focus)]"
        >
          {t('civilian.title')}
        </h1>
        {#if overview?.name}
          <p class="text-xs text-[var(--color-ink-muted)]">{t('civilian.visitor', { name: overview.name })}</p>
        {/if}
      </div>
      <button type="button" class={`${button} text-xs`} onclick={onClose}>{t('civilian.close')}</button>
    </header>

    <nav class="flex gap-2 border-b border-[var(--color-border)] px-5 py-2 text-xs" aria-label={t('civilian.title')}>
      {#each ['mine', 'report'] as const as name (name)}
        <button
          type="button"
          class={`${button} ${tab === name ? 'font-semibold' : ''}`}
          aria-current={tab === name ? 'page' : undefined}
          onclick={() => (tab = name)}
        >
          {t(`civilian.tab.${name}`)}
        </button>
      {/each}
    </nav>

    <div class="overflow-y-auto px-5 py-4 text-[13px]">
      {#if failure}
        <!-- The field's own reason when there is one: a visitor is told what
             to do about it, not the officer-facing sentence for the code. -->
        <div class="mb-3 border border-[var(--color-alert)] px-2 py-1" role="alert">
          {#if messages.length === 0}
            <p>{t(`error.${failure.err}`)}</p>
          {/if}
          {#each messages as message (message.name)}
            <p>{message.name === 'placementId' ? message.reason : `${message.label} — ${message.reason}`}</p>
          {/each}
        </div>
      {/if}
      {#if status}
        <p class="mb-3 text-[var(--color-ink-muted)]" role="status">{status}</p>
      {/if}

      {#if tab === 'mine'}
        {#if overview}
          <h2 class="mb-1 text-xs font-semibold">{t('civilian.citations.title')}</h2>
          {#if overview.citations.length === 0}
            <p class="mb-4 text-xs text-[var(--color-ink-muted)]">{t('civilian.citations.none')}</p>
          {:else}
            <div class="mb-4 overflow-x-auto">
              <table class="w-full text-left text-xs">
                <thead>
                  <tr class="text-[var(--color-ink-muted)]">
                    <th class="px-2 py-1 font-normal">{t('civilian.citations.number')}</th>
                    <th class="px-2 py-1 font-normal">{t('civilian.citations.offence')}</th>
                    <th class="px-2 py-1 font-normal">{t('civilian.citations.amount')}</th>
                    <th class="px-2 py-1 font-normal">{t('civilian.citations.issued')}</th>
                    <th class="px-2 py-1 font-normal">{t('civilian.citations.due')}</th>
                    <th class="px-2 py-1 font-normal">{t('civilian.citations.status')}</th>
                  </tr>
                </thead>
                <tbody>
                  {#each overview.citations as row (row.number)}
                    <tr class="border-t border-[var(--color-border)]">
                      <td class="px-2 py-1 font-[family-name:var(--font-mono)]">{row.number}</td>
                      <td class="px-2 py-1">{row.offence}</td>
                      <td class="px-2 py-1">{t('document.amount', { amount: row.amount })}</td>
                      <td class="px-2 py-1">{formatDate(row.issuedAt)}</td>
                      <td class="px-2 py-1">{formatDate(row.dueAt)}</td>
                      <td
                        class="px-2 py-1"
                        class:text-[var(--color-alert)]={row.status === 'overdue'}
                        class:font-semibold={row.status === 'overdue'}
                      >
                        {row.status === 'unpaid' || row.status === 'overdue'
                          ? t(`ordningsbot.payment.${row.status}`)
                          : t(`ordningsbot.status.${row.status}`)}
                      </td>
                    </tr>
                  {/each}
                </tbody>
              </table>
            </div>
          {/if}

          <h2 class="mb-1 text-xs font-semibold">{t('civilian.court.title')}</h2>
          {#if overview.court.length === 0}
            <p class="mb-4 text-xs text-[var(--color-ink-muted)]">{t('civilian.court.none')}</p>
          {:else}
            <div class="mb-4 overflow-x-auto">
              <table class="w-full text-left text-xs">
                <thead>
                  <tr class="text-[var(--color-ink-muted)]">
                    <th class="px-2 py-1 font-normal">{t('civilian.court.number')}</th>
                    <th class="px-2 py-1 font-normal">{t('civilian.court.decision')}</th>
                    <th class="px-2 py-1 font-normal">{t('civilian.court.decided')}</th>
                    <th class="px-2 py-1 font-normal">{t('civilian.court.verdict')}</th>
                    <th class="px-2 py-1 font-normal">{t('civilian.court.sentence')}</th>
                  </tr>
                </thead>
                <tbody>
                  {#each overview.court as row (row.number)}
                    <tr class="border-t border-[var(--color-border)]">
                      <td class="px-2 py-1 font-[family-name:var(--font-mono)]">{row.number}</td>
                      <td class="px-2 py-1">{t(`court.beslut.${row.beslut}`)}</td>
                      <td class="px-2 py-1">{formatDate(row.decidedAt)}</td>
                      <td class="px-2 py-1">{verdict(row)}</td>
                      <td class="px-2 py-1">{sentence(row)}</td>
                    </tr>
                  {/each}
                </tbody>
              </table>
            </div>
          {/if}

          <h2 class="mb-1 text-xs font-semibold">{t('civilian.reports.title')}</h2>
          {#if overview.reports.length === 0}
            <p class="text-xs text-[var(--color-ink-muted)]">{t('civilian.reports.none')}</p>
          {:else}
            <div class="overflow-x-auto">
              <table class="w-full text-left text-xs">
                <thead>
                  <tr class="text-[var(--color-ink-muted)]">
                    <th class="px-2 py-1 font-normal">{t('civilian.reports.number')}</th>
                    <th class="px-2 py-1 font-normal">{t('civilian.reports.kind')}</th>
                    <th class="px-2 py-1 font-normal">{t('civilian.reports.status')}</th>
                    <th class="px-2 py-1 font-normal">{t('civilian.reports.handedIn')}</th>
                  </tr>
                </thead>
                <tbody>
                  {#each overview.reports as row (row.number)}
                    <tr class="border-t border-[var(--color-border)]">
                      <td class="px-2 py-1 font-[family-name:var(--font-mono)]">{row.number}</td>
                      <td class="px-2 py-1">{t(`public.kind.${row.kind}`)}</td>
                      <td class="px-2 py-1">{t(`public.status.${row.status}`)}</td>
                      <td class="px-2 py-1">{formatMoment(row.createdAt)}</td>
                    </tr>
                  {/each}
                </tbody>
              </table>
            </div>
          {/if}
        {/if}
      {:else}
        <!-- `novalidate`: the server's translated refusal is the message. -->
        <form class="flex flex-col gap-3 text-xs" novalidate onsubmit={submit}>
          <label class="flex flex-col gap-1">
            {t('civilian.form.kind')}
            <select bind:value={form.kind} class={field}>
              {#each PUBLIC_REPORT_KINDS as kind (kind)}
                <option value={kind}>{t(`public.kind.${kind}`)}</option>
              {/each}
            </select>
          </label>
          {#if form.kind === 'complaint'}
            <p class="text-[var(--color-ink-muted)]">{t('civilian.form.complaintNote')}</p>
          {/if}
          <div class="flex flex-wrap gap-3">
            <label class="flex flex-col gap-1">
              {t('civilian.form.occurredAt')}
              <input type="datetime-local" bind:value={form.occurredAt} class={field} />
            </label>
            <label class="flex flex-1 flex-col gap-1">
              {t('civilian.form.place')}
              <input bind:value={form.place} maxlength="191" class={field} />
            </label>
          </div>
          {#if form.kind === 'stolen_property'}
            <label class="flex flex-col gap-1">
              {t('civilian.form.property')}
              <textarea bind:value={form.property} maxlength="500" rows="2" class={field}></textarea>
            </label>
          {/if}
          <label class="flex flex-col gap-1">
            {t('civilian.form.description')}
            <textarea bind:value={form.description} maxlength="2000" rows="6" class={field}></textarea>
          </label>
          <div>
            <button type="submit" class={button} aria-disabled={busy}>{t('civilian.form.submit')}</button>
          </div>
        </form>
      {/if}
    </div>
  </section>
</div>
