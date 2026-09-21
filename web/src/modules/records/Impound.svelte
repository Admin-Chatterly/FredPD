<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import { isStub, type Maybe, type Restricted } from './types';

  /**
   * Vehicle impound (spec 7.15). `feeOwed` is computed server-side, fresh on
   * every read -- never added up here (the same rule every sentence, fee and
   * range in this suite follows).
   */

  interface ImpoundRow {
    id: number;
    number: string;
    plate: string;
    model?: string | null;
    heldReasonKey: string;
    holdAuthorizedAt?: number | null;
    feePerDay: number;
    feeOwed?: number;
    impoundedAt: number;
    releasedAt?: number | null;
    feePaid: boolean;
    version: number;
  }

  const HELD_REASONS = ['investigative', 'evidence', 'abandoned', 'dui', 'unregistered', 'other'];

  const FIELD_LABELS: Record<string, string> = {
    plate: 'impound.field.plate',
    heldReasonKey: 'impound.field.heldReason',
  };

  let rows = $state<Maybe<ImpoundRow>[]>([]);
  let detail = $state<ImpoundRow | null>(null);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);
  let heldOnly = $state(true);
  let status = $state('');

  let createForm = $state({ plate: '', model: '', heldReasonKey: HELD_REASONS[0], feePerDay: 0 });
  let feePaid = $state(false);
  let confirmingRelease = $state(false);
  let trigger: HTMLButtonElement | null = null;

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  async function load(): Promise<void> {
    busy = true;

    const response = await nui.call<{ impounds: Maybe<ImpoundRow>[] }>('impound.list', {
      held: heldOnly ? true : undefined,
      limit: 100,
    });

    if (response.ok) {
      rows = response.data.impounds ?? [];
      failure = null;
    } else {
      failure = response;
    }

    busy = false;
  }

  async function open(id: number): Promise<void> {
    busy = true;

    const response = await nui.call<{ impound: ImpoundRow }>('impound.get', { id });

    if (response.ok) {
      detail = response.data.impound;
      failure = null;
    } else {
      detail = null;
      failure = response;
    }

    busy = false;
  }

  async function create(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    busy = true;
    const response = await nui.call<{ id: number; number: string }>('impound.create', {
      plate: createForm.plate,
      model: createForm.model || undefined,
      heldReasonKey: createForm.heldReasonKey,
      feePerDay: createForm.feePerDay || undefined,
    });

    if (response.ok) {
      failure = null;
      status = t('impound.created', { number: response.data.number });
      createForm = { plate: '', model: '', heldReasonKey: HELD_REASONS[0], feePerDay: 0 };
      await Promise.all([load(), open(response.data.id)]);
    } else {
      failure = response;
    }

    busy = false;
  }

  async function authorize(): Promise<void> {
    if (!detail) return;

    busy = true;
    const response = await nui.call('impound.authorize', { id: detail.id });

    if (response.ok) {
      failure = null;
      await Promise.all([open(detail.id), load()]);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function release(): Promise<void> {
    if (!detail) return;

    busy = true;
    const id = detail.id;

    const response = await nui.call('impound.release', { id, version: detail.version, feePaid });

    if (response.ok) {
      failure = null;
      confirmingRelease = false;
      trigger?.focus();
      await Promise.all([open(id), load()]);
    } else {
      failure = response;
      busy = false;
    }
  }

  function cancelConfirm(): void {
    confirmingRelease = false;
    failure = null;
    trigger?.focus();
  }

  function needsAuthorization(reason: string): boolean {
    return reason === 'investigative' || reason === 'evidence';
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
      <input type="checkbox" bind:checked={heldOnly} onchange={() => void load()} />
      {t('impound.filter.heldOnly')}
    </label>
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

  <form class="flex flex-wrap items-end gap-2 border border-[var(--color-border)] p-3" onsubmit={create}>
    <label class="flex flex-col gap-1 text-xs">
      <span>{t('impound.field.plate')} <span aria-hidden="true">*</span></span>
      <input bind:value={createForm.plate} required maxlength="16" class="border border-[var(--color-border)] px-2 py-1" />
    </label>
    <label class="flex flex-col gap-1 text-xs">
      {t('impound.field.model')}
      <input bind:value={createForm.model} maxlength="191" class="border border-[var(--color-border)] px-2 py-1" />
    </label>
    <label class="flex flex-col gap-1 text-xs">
      {t('impound.field.heldReason')}
      <select bind:value={createForm.heldReasonKey} class="border border-[var(--color-border)] px-2 py-1">
        {#each HELD_REASONS as key (key)}
          <option value={key}>{t(`impound.held_reason.${key}`)}</option>
        {/each}
      </select>
    </label>
    <label class="flex flex-col gap-1 text-xs">
      {t('impound.field.feePerDay')}
      <input type="number" bind:value={createForm.feePerDay} min="0" class="w-24 border border-[var(--color-border)] px-2 py-1" />
    </label>
    <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
      {t('impound.action.create')}
    </button>
  </form>

  {#if status}
    <p class="text-xs text-[var(--color-ink-muted)]" role="status">{status}</p>
  {/if}

  <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
    <div class="border border-[var(--color-border)]">
      {#if rows.length === 0}
        <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">{t('impound.empty')}</p>
      {:else}
        <table class="w-full text-xs">
          <thead class="bg-[var(--color-surface)]">
            <tr>
              <th class="px-2 py-1 text-left font-semibold">{t('impound.field.plate')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('impound.status.held')}</th>
            </tr>
          </thead>
          <tbody>
            {#each rows as row, index (index)}
              {#if isStub(row)}
                <tr class="border-t border-[var(--color-border)]">
                  <td class="px-2 py-1 text-[var(--color-ink-muted)]" colspan="2">
                    {t('records.restricted.title')} — {stubContact(row)}
                  </td>
                </tr>
              {:else}
                <tr class="border-t border-[var(--color-border)]">
                  <td class="px-2 py-1 font-[family-name:var(--font-mono)] whitespace-nowrap">
                    <button
                      type="button"
                      class="underline-offset-2 hover:underline"
                      class:font-semibold={detail?.id === row.id}
                      onclick={() => void open(row.id)}
                    >
                      {row.plate}
                    </button>
                  </td>
                  <td class="px-2 py-1">
                    {row.releasedAt ? t('impound.status.released') : t('impound.status.held')}
                  </td>
                </tr>
              {/if}
            {/each}
          </tbody>
        </table>
      {/if}
    </div>

    <div class="border border-[var(--color-border)] p-3">
      {#if !detail}
        <p class="text-xs text-[var(--color-ink-muted)]">{t('impound.detail.none')}</p>
      {:else}
        <header class="mb-3">
          <h2 class="font-[family-name:var(--font-mono)] text-sm font-semibold">{detail.number}</h2>
          <p class="text-xs text-[var(--color-ink-muted)]">
            {detail.plate} {detail.model ? `— ${detail.model}` : ''} · {t(`impound.held_reason.${detail.heldReasonKey}`)}
          </p>
        </header>

        <dl class="mb-3 text-xs">
          <div class="flex justify-between border-t border-[var(--color-border)] py-1">
            <dt>{t('impound.field.impoundedAt')}</dt>
            <dd class="font-[family-name:var(--font-mono)]">{formatMoment(detail.impoundedAt)}</dd>
          </div>
          <div class="flex justify-between border-t border-[var(--color-border)] py-1">
            <dt>{t('impound.field.feeOwed')}</dt>
            <dd>{detail.feeOwed ?? 0}</dd>
          </div>
        </dl>

        {#if !detail.releasedAt}
          {#if needsAuthorization(detail.heldReasonKey) && !detail.holdAuthorizedAt}
            <button type="button" class="mb-3 border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy} onclick={() => void authorize()}>
              {t('impound.action.authorize')}
            </button>
          {/if}

          {#if confirmingRelease}
            <ConfirmDialog
              label={t('impound.action.release')}
              question={t('impound.confirm.release')}
              {busy}
              {failure}
              fieldLabels={FIELD_LABELS}
              confirm={() => void release()}
              cancel={cancelConfirm}
            >
              <label class="flex items-center gap-1 text-xs">
                <input type="checkbox" bind:checked={feePaid} />
                {t('impound.field.feePaidConfirm')}
              </label>
            </ConfirmDialog>
          {:else}
            <button
              type="button"
              class="border border-[var(--color-border)] px-3 py-1 text-xs"
              disabled={busy}
              onclick={(event) => {
                trigger = event.currentTarget;
                feePaid = false;
                confirmingRelease = true;
                failure = null;
              }}
            >
              {t('impound.action.release')}
            </button>
          {/if}
        {:else}
          <p class="text-xs text-[var(--color-ink-muted)]">{t('impound.status.released')}</p>
        {/if}
      {/if}
    </div>
  </div>
</div>
