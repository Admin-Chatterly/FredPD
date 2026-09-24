<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import { isStub, type Maybe, type Restricted } from './types';
  import { IMPOUND_KEYS } from '@fredpd/schema';

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
    /** The lot it stands in (0037), by number; the id only on `impound.get`. */
    lotId?: number | null;
    lotNumber?: number | null;
    bay?: string | null;
    keysLocation?: string | null;
    conditionNote?: string | null;
    contents?: string | null;
    inventoryAt?: number | null;
    inventoryByCallsign?: string | null;
  }

  interface Lot {
    id: number;
    number: number;
  }

  const HELD_REASONS = ['investigative', 'evidence', 'abandoned', 'dui', 'unregistered', 'other'];

  const FIELD_LABELS: Record<string, string> = {
    plate: 'impound.field.plate',
    heldReasonKey: 'impound.field.heldReason',
    lotId: 'impound.field.lot',
    bay: 'impound.field.bay',
    keys: 'impound.field.keys',
    condition: 'impound.field.condition',
    contents: 'impound.field.contents',
  };

  let rows = $state<Maybe<ImpoundRow>[]>([]);
  /** This agency's lots, as the server numbered them. */
  let lots = $state<Lot[]>([]);
  let inventoryOpen = $state(false);
  let inventoryForm = $state({ lotId: '', bay: '', keys: '', condition: '', contents: '' });
  let detail = $state<ImpoundRow | null>(null);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);
  let heldOnly = $state(true);
  let status = $state('');

  let createForm = $state({ plate: '', model: '', heldReasonKey: HELD_REASONS[0], feePerDay: 0, lotId: '' });
  let feePaid = $state(false);
  let confirmingRelease = $state(false);
  let trigger: HTMLButtonElement | null = null;

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  async function load(): Promise<void> {
    busy = true;

    const response = await nui.call<{ impounds: Maybe<ImpoundRow>[]; lots?: Lot[] }>('impound.list', {
      held: heldOnly ? true : undefined,
      limit: 100,
    });

    if (response.ok) {
      rows = response.data.impounds ?? [];
      lots = response.data.lots ?? [];
      failure = null;
    } else {
      failure = response;
    }

    busy = false;
  }

  async function open(id: number): Promise<void> {
    busy = true;

    const response = await nui.call<{ impound: ImpoundRow; lots?: Lot[] }>('impound.get', { id });

    if (response.ok) {
      detail = response.data.impound;
      lots = response.data.lots ?? lots;
      inventoryOpen = false;
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
      lotId: Number(createForm.lotId) || undefined,
    });

    if (response.ok) {
      failure = null;
      status = t('impound.created', { number: response.data.number });
      createForm = { plate: '', model: '', heldReasonKey: HELD_REASONS[0], feePerDay: 0, lotId: '' };
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

  function startInventory(): void {
    if (!detail) return;
    inventoryForm = {
      lotId: detail.lotId ? String(detail.lotId) : '',
      bay: detail.bay ?? '',
      keys: detail.keysLocation ?? '',
      condition: detail.conditionNote ?? '',
      contents: detail.contents ?? '',
    };
    inventoryOpen = true;
    failure = null;
  }

  async function saveInventory(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail || busy) return;

    busy = true;
    const id = detail.id;
    const response = await nui.call('impound.inventory', {
      id,
      version: detail.version,
      lotId: Number(inventoryForm.lotId) || undefined,
      bay: inventoryForm.bay || undefined,
      keys: inventoryForm.keys || undefined,
      condition: inventoryForm.condition || undefined,
      contents: inventoryForm.contents || undefined,
    });

    if (response.ok) {
      failure = null;
      status = t('impound.inventory.saved');
      await Promise.all([open(id), load()]);
    } else {
      failure = response;
      busy = false;
    }
  }

  function lotText(row: { lotNumber?: number | null; bay?: string | null }): string {
    if (!row.lotNumber) return '—';
    return row.bay
      ? t('impound.lot.withBay', { number: row.lotNumber, bay: row.bay })
      : t('impound.lot.name', { number: row.lotNumber });
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
    {#if lots.length > 0}
      <label class="flex flex-col gap-1 text-xs">
        {t('impound.field.lot')}
        <select bind:value={createForm.lotId} class="border border-[var(--color-border)] px-2 py-1">
          <option value="">{t('impound.lot.none')}</option>
          {#each lots as lot (lot.id)}
            <option value={String(lot.id)}>{t('impound.lot.name', { number: lot.number })}</option>
          {/each}
        </select>
      </label>
    {/if}
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
              <th class="px-2 py-1 text-left font-semibold">{t('impound.field.lot')}</th>
            </tr>
          </thead>
          <tbody>
            {#each rows as row, index (index)}
              {#if isStub(row)}
                <tr class="border-t border-[var(--color-border)]">
                  <td class="px-2 py-1 text-[var(--color-ink-muted)]" colspan="3">
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
                  <td class="px-2 py-1">{lotText(row)}</td>
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
          <div class="flex justify-between border-t border-[var(--color-border)] py-1">
            <dt>{t('impound.field.lot')}</dt>
            <dd>{lotText(detail)}</dd>
          </div>
          <div class="flex justify-between border-t border-[var(--color-border)] py-1">
            <dt>{t('impound.field.keys')}</dt>
            <dd>{detail.keysLocation ? t(`impound.keys.${detail.keysLocation}`) : '—'}</dd>
          </div>
          <div class="border-t border-[var(--color-border)] py-1">
            <dt>{t('impound.field.condition')}</dt>
            <dd class="whitespace-pre-wrap">{detail.conditionNote ?? '—'}</dd>
          </div>
          <div class="border-t border-[var(--color-border)] py-1">
            <dt>{t('impound.field.contents')}</dt>
            <dd class="whitespace-pre-wrap">{detail.contents ?? '—'}</dd>
          </div>
          {#if detail.inventoryAt}
            <p class="border-t border-[var(--color-border)] py-1 text-[var(--color-ink-muted)]">
              {t('impound.inventory.by', {
                callsign: detail.inventoryByCallsign ?? '—',
                at: formatMoment(detail.inventoryAt),
              })}
            </p>
          {/if}
        </dl>

        {#if !detail.releasedAt}
          {#if inventoryOpen}
            <form class="mb-3 flex flex-col gap-2 border border-[var(--color-border)] p-2" onsubmit={saveInventory}>
              <div class="flex flex-wrap gap-2">
                <label class="flex flex-col gap-1 text-xs">
                  {t('impound.field.lot')}
                  <select bind:value={inventoryForm.lotId} class="border border-[var(--color-border)] px-2 py-1">
                    <option value="">{t('impound.lot.none')}</option>
                    {#each lots as lot (lot.id)}
                      <option value={String(lot.id)}>{t('impound.lot.name', { number: lot.number })}</option>
                    {/each}
                  </select>
                </label>
                <label class="flex flex-col gap-1 text-xs">
                  {t('impound.field.bay')}
                  <input bind:value={inventoryForm.bay} maxlength="16" class="w-20 border border-[var(--color-border)] px-2 py-1" />
                </label>
                <label class="flex flex-col gap-1 text-xs">
                  {t('impound.field.keys')}
                  <select bind:value={inventoryForm.keys} class="border border-[var(--color-border)] px-2 py-1">
                    <option value="">{t('impound.keys.unknown')}</option>
                    {#each IMPOUND_KEYS as key (key)}
                      <option value={key}>{t(`impound.keys.${key}`)}</option>
                    {/each}
                  </select>
                </label>
              </div>
              <label class="flex flex-col gap-1 text-xs">
                {t('impound.field.condition')}
                <textarea rows="2" bind:value={inventoryForm.condition} maxlength="500" class="border border-[var(--color-border)] px-2 py-1"></textarea>
              </label>
              <label class="flex flex-col gap-1 text-xs">
                {t('impound.field.contents')}
                <textarea rows="3" bind:value={inventoryForm.contents} maxlength="1000" class="border border-[var(--color-border)] px-2 py-1"></textarea>
              </label>
              <div class="flex gap-2">
                <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs">
                  {t('impound.inventory.save')}
                </button>
                <button type="button" class="border border-[var(--color-border)] px-3 py-1 text-xs" onclick={() => (inventoryOpen = false)}>
                  {t('form.cancel')}
                </button>
              </div>
            </form>
          {:else}
            <button type="button" class="mb-3 border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy} onclick={startInventory}>
              {detail.inventoryAt ? t('impound.inventory.edit') : t('impound.inventory.write')}
            </button>
          {/if}
        {/if}

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
