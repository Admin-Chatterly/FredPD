<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { FU_STATUSES, FU_LEDARE_KINDS } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import LoadMore from '../shared/LoadMore.svelte';
  import { isStub, type Maybe, type Moment, type Restricted } from './types';
  import type { EvidenceItem } from '../evidence/types';

  /**
   * Förundersökning — the investigation itself (spec 7.8).
   *
   * The anmälan beside it is a *report*: what happened, who was there, and it
   * locks when a supervisor approves it. This is the case opened off the back
   * of one, and it has its own life — a leader, the reports gathered under it,
   * and three ways to end.
   *
   * Two things the screen draws rather than decides:
   *
   *   * **Who leads it is a capacity.** A police förundersökningsledare runs
   *     the ordinary case; once somebody is anhållen or there are reasonable
   *     grounds, an åklagare takes it (ADR-014). `ledareKind` says which, and
   *     the server decides whether this session may set it — `not_ledare` is
   *     its refusal, and it reads as "this is not your investigation to lead"
   *     rather than as a permission problem.
   *   * **The three endings are different facts.** *Slutdelgivning* is the
   *     suspect being shown the material (RB 23:18a) and the investigation
   *     continues; *redovisning* hands it to the prosecutor; *nedläggning*
   *     ends it, and asks why — because "the offence cannot be proven" and "no
   *     offence was committed" are not the same answer to give somebody who
   *     was a suspect.
   */

  interface FuRow {
    id: number;
    number: string;
    title: string;
    status: string;
    fuLedare?: string | null;
    ledareKind?: string | null;
    intelCaseId?: number | null;
    openedBy?: string | null;
    openedAt: Moment;
    closedBy?: string | null;
    closedAt: Moment;
    closedReason?: string | null;
    closedNote?: string | null;
    classification: string;
    version: number;
    updatedAt: Moment;
  }

  /** An anmälan as `fu.get` lists it under the investigation. */
  interface AnmalanRow {
    id: number;
    number: string;
    title: string;
    status: string;
  }

  /** The three ways an investigation ends, in the order RB takes them. */
  type Decision = 'slutdelge' | 'redovisa' | 'lagg_ned';

  /**
   * Which endings each status offers.
   *
   * Mirrors the server's own transitions, and exists only so the screen does
   * not draw a button whose single outcome is a refusal. An investigation that
   * has been discontinued or reported is finished.
   */
  const AVAILABLE: Record<string, Decision[]> = {
    inledd: ['slutdelge', 'redovisa', 'lagg_ned'],
    slutdelgiven: ['redovisa', 'lagg_ned'],
    redovisad: [],
    nedlagd: [],
  };

  /** Why an investigation was discontinued. Locale keys, never prose. */
  const REASONS = [
    'brott_kan_ej_styrkas',
    'spaningsuppslag_saknas',
    'ej_brott',
    'atalsunderlatelse',
    'annan',
  ];

  let rows = $state<Maybe<FuRow>[]>([]);
  let nextCursor = $state<string | null>(null);
  let detail = $state<{ fu: FuRow; anmalningar: Maybe<AnmalanRow>[] } | null>(null);
  let evidence = $state<EvidenceItem[]>([]);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);
  let statusFilter = $state('');
  let mine = $state(false);
  let openId = $state<number | null>(null);
  let status = $state('');

  let opening = $state(false);
  let form = $state({ title: '', ledareKind: 'polis' });

  let deciding = $state<Decision | null>(null);
  let reason = $state('');
  let note = $state('');
  let trigger: HTMLButtonElement | null = null;

  const REQUIRED_MARK = '*';

  const FIELD_LABELS: Record<string, string> = {
    title: 'fu.column.title',
    fuLedare: 'fu.column.ledare',
    ledareKind: 'fu.column.ledare',
    reason: 'fu.field.reason',
    note: 'fu.field.note',
    status: 'fu.column.status',
    version: 'anmalan.column.version',
    classification: 'records.person.field.classification',
  };

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  const record = $derived(detail?.fu ?? null);
  const available = $derived(record ? (AVAILABLE[record.status] ?? []) : []);

  /** Only a discontinuation asks why. The other two are not refusals. */
  const needsReason = $derived(deciding === 'lagg_ned');

  function cancelConfirm(): void {
    deciding = null;
    failure = null;
    trigger?.focus();
  }

  async function load(reset = true): Promise<void> {
    busy = true;

    const response = await nui.call<{ forundersokningar: Maybe<FuRow>[]; nextCursor?: string | null }>(
      'fu.list',
      {
        status: statusFilter || undefined,
        mine: mine || undefined,
        limit: 50,
        cursor: reset ? undefined : (nextCursor ?? undefined),
      },
    );

    if (response.ok) {
      const page = response.data.forundersokningar ?? [];
      rows = reset ? page : [...rows, ...page];
      nextCursor = response.data.nextCursor ?? null;
      failure = null;
    } else {
      failure = response;
    }

    busy = false;
  }

  function loadMore(): void {
    void load(false);
  }

  async function open(id: number): Promise<void> {
    busy = true;
    deciding = null;

    const response = await nui.call<{ fu: FuRow; anmalningar: Maybe<AnmalanRow>[] }>('fu.get', {
      id,
    });

    if (response.ok) {
      detail = response.data;
      openId = id;
      failure = null;

      // Best-effort: a reader who may open the case but not the evidence
      // register simply sees no evidence section, the same way a refused
      // read is drawn as nothing rather than as an error (4.5) -- this case
      // detail is not wrong for lacking it.
      const evidenceResponse = await nui.call<{ items: EvidenceItem[] }>('evidence.list', {
        caseNumber: response.data.fu.number,
      });
      evidence = evidenceResponse.ok ? evidenceResponse.data.items : [];
    } else {
      detail = null;
      openId = null;
      evidence = [];
      failure = response;
    }

    busy = false;
  }

  async function create(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    busy = true;

    const response = await nui.call<{ id: number }>('fu.create', {
      title: form.title || undefined,
      ledareKind: form.ledareKind,
    });

    if (response.ok) {
      failure = null;
      opening = false;
      form.title = '';
      await Promise.all([load(), open(response.data.id)]);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function decide(): Promise<void> {
    const action = deciding;
    if (!action || !record) return;

    busy = true;
    const id = record.id;

    const response = await nui.call(`fu.${action}`, {
      id,
      version: record.version,
      reason: reason || undefined,
      note: note || undefined,
    });

    if (response.ok) {
      failure = null;
      // Closed once the server has agreed, so a stale version keeps the
      // reason the officer chose rather than discarding it.
      deciding = null;
      status = t(`fu.done.${action}`, { number: record.number });
      reason = '';
      note = '';
      trigger?.focus();
      await Promise.all([open(id), load()]);
    } else {
      failure = response;
      busy = false;
    }
  }

  /** Who is leading it, as a line. The capacity matters more than the id. */
  function ledareText(row: FuRow): string {
    if (!row.ledareKind) return '';

    return t(`fu.ledareKind.${row.ledareKind}`);
  }

  function stubContact(row: Restricted): string {
    return t('records.restricted.contact', { unit: t(`access.unit.${row.contact}`) });
  }

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
      <input type="checkbox" bind:checked={mine} />
      {t('fu.filter.mine')}
    </label>

    <label class="flex flex-col gap-1 text-xs">
      {t('fu.column.status')}
      <select bind:value={statusFilter} class="border border-[var(--color-border)] px-2 py-1">
        <option value="">{t('form.any')}</option>
        {#each FU_STATUSES as value (value)}
          <option {value}>{t(`fu.status.${value}`)}</option>
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
      aria-expanded={opening}
      onclick={() => (opening = !opening)}
    >
      {t('fu.action.create')}
    </button>
  </form>

  {#if opening}
    <form
      class="flex flex-wrap items-end gap-2 border border-[var(--color-border)] p-3"
      onsubmit={(event) => void create(event)}
    >
      <label class="flex flex-1 flex-col gap-1 text-xs">
        <span>{t('fu.column.title')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
        <input
          bind:value={form.title}
          required
          aria-required="true"
          maxlength="191"
          class="border border-[var(--color-border)] px-2 py-1"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        {t('fu.column.ledare')}
        <select bind:value={form.ledareKind} class="border border-[var(--color-border)] px-2 py-1">
          {#each FU_LEDARE_KINDS as kind (kind)}
            <option value={kind}>{t(`fu.ledareKind.${kind}`)}</option>
          {/each}
        </select>
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1 text-xs"
        disabled={busy}
      >
        {t('fu.action.create')}
      </button>
    </form>
  {/if}

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

  {#if status}
    <p class="text-xs text-[var(--color-ink-muted)]" role="status">{status}</p>
  {/if}

  {#if deciding}
    <ConfirmDialog
      label={t(`fu.action.${deciding}`)}
      question={t(`fu.confirm.${deciding}`)}
      {busy}
      {failure}
      fieldLabels={FIELD_LABELS}
      confirm={() => void decide()}
      cancel={cancelConfirm}
    >
      {#if needsReason}
        <!--
          Only the discontinuation asks. "The offence cannot be proven" and "no
          offence was committed" are different answers to give somebody who was
          a suspect, and the register is read long afterwards.
        -->
        <label class="mt-2 flex flex-col gap-1">
          <span>{t('fu.field.reason')}</span>
          <select bind:value={reason} class="w-72 border border-[var(--color-border)] px-2 py-1">
            <option value="">{t('fu.field.reasonChoose')}</option>
            {#each REASONS as key (key)}
              <option value={key}>{t(`fu.reason.${key}`)}</option>
            {/each}
          </select>
        </label>
      {/if}

      <label class="mt-2 flex flex-col gap-1">
        <span>{t('fu.field.note')}</span>
        <input
          bind:value={note}
          maxlength="2000"
          class="border border-[var(--color-border)] px-2 py-1"
        />
      </label>
    </ConfirmDialog>
  {/if}

  <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
    <div class="border border-[var(--color-border)]">
      {#if rows.length === 0}
        <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">{t('fu.empty')}</p>
      {:else}
        <div class="overflow-x-auto">
          <table class="w-full text-xs">
            <thead class="bg-[var(--color-surface)]">
              <tr>
                <th class="px-2 py-1 text-left font-semibold">{t('fu.column.number')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('fu.column.title')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('fu.column.ledare')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('fu.column.status')}</th>
              </tr>
            </thead>
            <tbody>
              <!-- Keyed by index: a stub carries no id (4.5). -->
              {#each rows as row, index (index)}
                {#if isStub(row)}
                  <tr class="border-t border-[var(--color-border)]">
                    <td class="px-2 py-1 text-[var(--color-ink-muted)]" colspan="4">
                      {t('records.restricted.title')} — {stubContact(row)}
                    </td>
                  </tr>
                {:else}
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
                    <td class="px-2 py-1">{row.title}</td>
                    <td class="px-2 py-1 whitespace-nowrap">{ledareText(row)}</td>
                    <td class="px-2 py-1 whitespace-nowrap">{t(`fu.status.${row.status}`)}</td>
                  </tr>
                {/if}
              {/each}
            </tbody>
          </table>
        </div>
        <LoadMore {nextCursor} {busy} {loadMore} />
      {/if}
    </div>

    <div class="border border-[var(--color-border)] p-3">
      {#if !record || !detail}
        <p class="text-xs text-[var(--color-ink-muted)]">{t('fu.detail.none')}</p>
      {:else}
        <header class="mb-3">
          <h2 class="font-[family-name:var(--font-mono)] text-sm font-semibold">
            {record.number}
          </h2>
          <p class="text-xs">{record.title}</p>
          <p class="text-xs text-[var(--color-ink-muted)]">
            {t(`fu.status.${record.status}`)}
            {#if record.ledareKind}
              · {ledareText(record)}
            {/if}
          </p>
        </header>

        <dl class="mb-3 text-xs">
          <div class="flex justify-between border-t border-[var(--color-border)] py-1">
            <dt>{t('fu.column.opened')}</dt>
            <dd class="font-[family-name:var(--font-mono)]">{formatMoment(record.openedAt)}</dd>
          </div>
          {#if record.closedAt}
            <div class="flex justify-between border-t border-[var(--color-border)] py-1">
              <dt>{t('fu.column.closed')}</dt>
              <dd class="font-[family-name:var(--font-mono)]">{formatMoment(record.closedAt)}</dd>
            </div>
          {/if}
          {#if record.closedReason}
            <div class="flex justify-between border-t border-[var(--color-border)] py-1">
              <dt>{t('fu.field.reason')}</dt>
              <dd>{t(`fu.reason.${record.closedReason}`)}</dd>
            </div>
          {/if}
        </dl>

        {#if record.closedNote}
          <p class="mb-3 text-xs text-[var(--color-ink-muted)]">{record.closedNote}</p>
        {/if}

        <!-- What has been gathered under it -->
        <section class="mb-3">
          <h3 class="mb-1 text-xs font-semibold">{t('fu.section.anmalningar')}</h3>
          {#if detail.anmalningar.length === 0}
            <p class="text-xs text-[var(--color-ink-muted)]">{t('fu.anmalan.empty')}</p>
          {:else}
            <ul class="text-xs">
              {#each detail.anmalningar as report, index (index)}
                <li class="border-t border-[var(--color-border)] py-1">
                  {#if isStub(report)}
                    <span class="text-[var(--color-ink-muted)]">
                      {t('records.restricted.title')} — {stubContact(report)}
                    </span>
                  {:else}
                    <span class="font-[family-name:var(--font-mono)]">{report.number}</span>
                    — {report.title}
                    <span class="text-[var(--color-ink-muted)]">
                      ({t(`anmalan.status.${report.status}`)})
                    </span>
                  {/if}
                </li>
              {/each}
            </ul>
          {/if}
        </section>

        <!-- Evidence collected for this case, and what the lab found (8.6,
             8.11). Withheld results read as an empty cell, never a lock icon:
             the access control is the server not sending it, drawn exactly
             the way an unfinished analysis is (nothing to show yet). -->
        <section class="mb-3">
          <h3 class="mb-1 text-xs font-semibold">{t('fu.section.evidence')}</h3>
          {#if evidence.length === 0}
            <p class="text-xs text-[var(--color-ink-muted)]">{t('fu.evidence.empty')}</p>
          {:else}
            <ul class="text-xs">
              {#each evidence as item (item.id)}
                <li class="border-t border-[var(--color-border)] py-1">
                  <div class="flex items-baseline justify-between gap-2">
                    <span class="font-[family-name:var(--font-mono)]">{item.evidenceNumber}</span>
                    <span class="text-[var(--color-ink-muted)]">
                      {t(`evidence.type.${item.type}`)} · {t(`evidence.status.${item.status}`)}
                    </span>
                  </div>
                  {#if item.analyses && item.analyses.length > 0}
                    <ul class="mt-0.5 ml-3 text-[var(--color-ink-muted)]">
                      {#each item.analyses as analysis (analysis.id)}
                        <li>
                          {t(`lab.analysis.${analysis.analysis}`)}:
                          {#if analysis.resultCode}
                            {t(`lab.result.${analysis.resultCode}`)}
                          {:else}
                            {t(`lab.status.${analysis.status}`)}
                          {/if}
                        </li>
                      {/each}
                    </ul>
                  {/if}
                </li>
              {/each}
            </ul>
          {/if}
        </section>

        {#if available.length > 0}
          <section class="flex flex-wrap gap-2 border-t border-[var(--color-border)] pt-3">
            {#each available as action (action)}
              <button
                type="button"
                class="border border-[var(--color-border)] px-3 py-1 text-xs"
                disabled={busy}
                onclick={(event) => {
                  trigger = event.currentTarget;
                  deciding = action;
                  reason = '';
                  note = '';
                  failure = null;
                  status = '';
                }}
              >
                {t(`fu.action.${action}`)}
              </button>
            {/each}
          </section>
        {/if}
      {/if}
    </div>
  </div>
</div>
