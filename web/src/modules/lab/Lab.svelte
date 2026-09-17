<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { LAB_ANALYSES, LAB_ANALYSIS_STATUSES } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import type { LabAnalysis } from './types';

  /**
   * The forensic lab (spec 8.7).
   *
   * The queue is the screen: what is waiting, who has it, when it is due. An
   * analyst takes a piece of work, and when the server's clock says the
   * turnaround has elapsed, records how they worked and releases the result.
   *
   * Three things are deliberately not here. There is no countdown — the wait is
   * real server time and a due timestamp is the honest way to show it (6.6
   * rejects fake loading effects). There is no conclusion in the form: the call
   * carries observations, and the server computes the result from hidden truth
   * this interface has never seen (8.1). And nothing is hidden by permission:
   * a result that is withheld is withheld by the server not sending it, which
   * is why an empty result column is the access control working (8.11).
   */

  const FIELD_LABELS: Record<string, string> = {
    observations: 'lab.observations',
    status: 'lab.column.status',
    dueAt: 'lab.column.due',
    analysis: 'lab.column.analysis',
  };

  let queue = $state<LabAnalysis[]>([]);
  let status = $state('');
  let analysisFilter = $state('');
  let mine = $state(false);

  let selectedId = $state<number | null>(null);
  let observations = $state('');

  let failure = $state<Failure | null>(null);
  let loading = $state(true);
  let busy = $state(false);

  async function load(): Promise<void> {
    const response = await nui.call<{ queue: LabAnalysis[] }>('lab.queue', {
      status: status || undefined,
      analysis: analysisFilter || undefined,
      // "Mine" is a flag, never an analyst id: the server answers it with the
      // session's own signature (8.7).
      mine: mine || undefined,
    });

    if (response.ok) {
      queue = response.data.queue;
      failure = null;
    } else {
      failure = response;
    }

    loading = false;
  }

  $effect(() => {
    void status;
    void analysisFilter;
    void mine;
    void load();
  });

  async function submit(route: string, input: Record<string, unknown>): Promise<boolean> {
    if (busy) return false;
    busy = true;

    const response = await nui.call(route, input);

    if (response.ok) {
      failure = null;
      await load();
    } else {
      failure = response;
    }

    busy = false;
    return response.ok;
  }

  async function start(id: number): Promise<void> {
    await submit('lab.analysis.start', { id });
  }

  async function complete(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (selectedId === null) return;

    const done = await submit('lab.analysis.complete', {
      id: selectedId,
      observations: observations.trim() || undefined,
    });

    if (done) observations = '';
  }

  function when(value: string | null | undefined): string {
    return value ? value.replace('T', ' ').slice(0, 16) : '';
  }

  const selected = $derived(queue.find((row) => row.id === selectedId) ?? null);
  const messages = $derived(fieldList(failure, FIELD_LABELS));
</script>

<section class="flex min-h-0 flex-col gap-4">
  <header>
    <h1 class="text-base font-semibold">{t('lab.title')}</h1>
    <p class="mt-1 max-w-prose text-xs text-[var(--color-ink-muted)]">{t('lab.intro')}</p>
  </header>

  <div class="flex flex-wrap items-end gap-3">
    <label class="flex flex-col gap-1 text-xs">
      <span>{t('lab.filter.status')}</span>
      <select
        class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
        bind:value={status}
      >
        <option value="">{t('lab.filter.any')}</option>
        {#each LAB_ANALYSIS_STATUSES as value (value)}
          <option {value}>{t(`lab.status.${value}`)}</option>
        {/each}
      </select>
    </label>

    <label class="flex flex-col gap-1 text-xs">
      <span>{t('lab.filter.analysis')}</span>
      <select
        class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
        bind:value={analysisFilter}
      >
        <option value="">{t('lab.filter.any')}</option>
        {#each LAB_ANALYSES as value (value)}
          <option {value}>{t(`lab.analysis.${value}`)}</option>
        {/each}
      </select>
    </label>

    <label class="flex items-center gap-1.5 text-xs">
      <input type="checkbox" bind:checked={mine} />
      <span>{t('lab.filter.mine')}</span>
    </label>
  </div>

  {#if failure}
    <div class="border border-[var(--color-border)] px-3 py-2 text-sm">
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

  {#if loading}
    <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
  {:else}
    <div class="overflow-x-auto border border-[var(--color-border)]">
      <table class="w-full border-collapse text-xs">
        <thead>
          <tr class="border-b border-[var(--color-border)] text-left">
            <th class="px-3 py-2 font-semibold">{t('lab.column.evidence')}</th>
            <th class="px-3 py-2 font-semibold">{t('lab.column.analysis')}</th>
            <th class="px-3 py-2 font-semibold">{t('lab.column.priority')}</th>
            <th class="px-3 py-2 font-semibold">{t('lab.column.status')}</th>
            <th class="px-3 py-2 font-semibold">{t('lab.column.assigned')}</th>
            <th class="px-3 py-2 font-semibold">{t('lab.column.due')}</th>
            <th class="px-3 py-2 font-semibold">{t('lab.column.result')}</th>
            <th class="px-3 py-2"></th>
          </tr>
        </thead>
        <tbody>
          {#each queue as row (row.id)}
            <tr class="border-b border-[var(--color-border)] last:border-b-0">
              <td class="px-3 py-2">
                <button
                  type="button"
                  class="font-[family-name:var(--font-mono)] underline-offset-2 hover:underline"
                  class:font-semibold={selectedId === row.id}
                  onclick={() => (selectedId = row.id)}
                >
                  {row.evidenceNumber ?? row.evidenceId}
                </button>
              </td>
              <td class="px-3 py-2">{t(`lab.analysis.${row.analysis}`)}</td>
              <td class="px-3 py-2">{t(`lab.priority.${row.priority}`)}</td>
              <td class="px-3 py-2">{t(`lab.status.${row.status}`)}</td>
              <td class="px-3 py-2 font-[family-name:var(--font-mono)]">{row.assignedTo ?? ''}</td>
              <td class="px-3 py-2">{when(row.dueAt)}</td>
              <td class="px-3 py-2">
                {row.resultCode ? t(`lab.result.${row.resultCode}`) : ''}
              </td>
              <td class="px-3 py-2 text-right">
                {#if row.status === 'queued'}
                  <button
                    type="button"
                    class="border border-[var(--color-border)] px-2 py-1 hover:bg-[var(--color-surface)]"
                    disabled={busy}
                    onclick={() => start(row.id)}
                  >
                    {t('lab.start')}
                  </button>
                {/if}
              </td>
            </tr>
          {:else}
            <tr>
              <td class="px-3 py-3 text-[var(--color-ink-muted)]" colspan="8">
                {t('lab.empty')}
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}

  {#if selected}
    <article class="flex flex-col gap-3 border border-[var(--color-border)] p-3">
      <header class="flex flex-wrap items-baseline justify-between gap-3">
        <h2 class="text-sm font-semibold">{t(`lab.analysis.${selected.analysis}`)}</h2>
        <span class="text-xs font-[family-name:var(--font-mono)]">
          {selected.evidenceNumber ?? selected.evidenceId}
        </span>
      </header>

      <dl class="grid grid-cols-2 gap-x-6 gap-y-1 text-xs md:grid-cols-4">
        <dt class="text-[var(--color-ink-muted)]">{t('lab.column.status')}</dt>
        <dd>{t(`lab.status.${selected.status}`)}</dd>

        <dt class="text-[var(--color-ink-muted)]">{t('lab.column.priority')}</dt>
        <dd>{t(`lab.priority.${selected.priority}`)}</dd>

        <dt class="text-[var(--color-ink-muted)]">{t('lab.column.case')}</dt>
        <dd class="font-[family-name:var(--font-mono)]">{selected.caseNumber ?? ''}</dd>

        <dt class="text-[var(--color-ink-muted)]">{t('lab.column.assigned')}</dt>
        <dd class="font-[family-name:var(--font-mono)]">{selected.assignedTo ?? ''}</dd>

        <dt class="text-[var(--color-ink-muted)]">{t('lab.column.started')}</dt>
        <dd>{when(selected.startedAt)}</dd>

        <dt class="text-[var(--color-ink-muted)]">{t('lab.column.due')}</dt>
        <dd>{when(selected.dueAt)}</dd>

        <dt class="text-[var(--color-ink-muted)]">{t('lab.column.completed')}</dt>
        <dd>{when(selected.completedAt)}</dd>

        <dt class="text-[var(--color-ink-muted)]">{t('lab.column.result')}</dt>
        <dd>{selected.resultCode ? t(`lab.result.${selected.resultCode}`) : ''}</dd>
      </dl>

      {#if selected.observations}
        <div class="text-xs">
          <h3 class="font-semibold">{t('lab.observations')}</h3>
          <p class="mt-0.5 whitespace-pre-wrap">{selected.observations}</p>
        </div>
      {/if}

      {#if selected.status === 'queued'}
        <div class="flex items-center gap-3">
          <p class="text-xs text-[var(--color-ink-muted)]">{t('lab.notStarted')}</p>
          <button
            type="button"
            class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
            disabled={busy}
            onclick={() => {
              if (selected) void start(selected.id);
            }}
          >
            {t('lab.start')}
          </button>
        </div>
      {:else if selected.status === 'in_progress'}
        <!-- The result is not a field. What is recorded here is how the analyst
             worked; the conclusion is computed on the server when the
             turnaround has genuinely elapsed (8.7). -->
        <form class="flex flex-col gap-2" onsubmit={complete}>
          <label class="flex flex-col gap-1 text-xs">
            <span>{t('lab.observations')}</span>
            <textarea
              class="min-h-20 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={observations}
              placeholder={t('lab.observationsPlaceholder')}
            ></textarea>
          </label>

          <div class="flex items-center gap-3">
            <button
              type="submit"
              class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
              disabled={busy}
            >
              {t('lab.complete')}
            </button>
            <p class="text-xs text-[var(--color-ink-muted)]">{t('lab.completeNote')}</p>
          </div>
        </form>
      {/if}
    </article>
  {/if}
</section>
