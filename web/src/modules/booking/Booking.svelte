<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import { isStub, type Maybe, type Restricted } from '../records/types';

  /**
   * Booking: inskrivning i arrest — cell assignment, property inventory and
   * release, picking up where `frihet`'s gripande chain leaves off (spec 7.9).
   */

  interface Property {
    id: number;
    itemLabel: string;
    quantity: number;
    loggedAt: number;
    returnedAt?: number | null;
  }

  interface BookingRow {
    id: number;
    number: string;
    frihetId: number;
    cell?: string | null;
    bookedAt: number;
    releasedAt?: number | null;
    releaseReasonKey?: string | null;
    version: number;
    property?: Property[];
  }

  const RELEASE_REASONS = ['bail', 'released_no_charge', 'transferred', 'time_served', 'other'];

  const FIELD_LABELS: Record<string, string> = {
    frihetId: 'booking.field.frihetId',
    cell: 'booking.field.cell',
    itemLabel: 'booking.property.itemLabel',
    releaseReasonKey: 'booking.releaseReason.label',
  };

  let rows = $state<Maybe<BookingRow>[]>([]);
  let detail = $state<BookingRow | null>(null);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);
  let openOnly = $state(true);
  let status = $state('');

  let bookForm = $state({ frihetId: '', cell: '' });
  let propertyForm = $state({ itemLabel: '', quantity: 1 });
  let releaseReasonKey = $state(RELEASE_REASONS[0]);

  let confirmingRelease = $state(false);
  let trigger: HTMLButtonElement | null = null;

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  function cancelConfirm(): void {
    confirmingRelease = false;
    failure = null;
    trigger?.focus();
  }

  async function load(): Promise<void> {
    busy = true;

    const response = await nui.call<{ bookings: Maybe<BookingRow>[] }>('booking.list', {
      open: openOnly ? true : undefined,
      limit: 100,
    });

    if (response.ok) {
      rows = response.data.bookings ?? [];
      failure = null;
    } else {
      failure = response;
    }

    busy = false;
  }

  async function open(id: number): Promise<void> {
    busy = true;

    const response = await nui.call<{ booking: BookingRow }>('booking.get', { id });

    if (response.ok) {
      detail = response.data.booking;
      failure = null;
    } else {
      detail = null;
      failure = response;
    }

    busy = false;
  }

  async function book(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    const frihetId = Number.parseInt(bookForm.frihetId, 10);
    if (!Number.isFinite(frihetId)) return;

    busy = true;
    const response = await nui.call<{ id: number; number: string }>('booking.book', {
      frihetId,
      cell: bookForm.cell || undefined,
    });

    if (response.ok) {
      failure = null;
      status = t('booking.booked', { number: response.data.number });
      bookForm = { frihetId: '', cell: '' };
      await Promise.all([load(), open(response.data.id)]);
    } else {
      failure = response;
    }

    busy = false;
  }

  async function addProperty(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail) return;

    busy = true;
    const response = await nui.call('booking.property.add', {
      bookingId: detail.id,
      itemLabel: propertyForm.itemLabel,
      quantity: propertyForm.quantity || 1,
    });

    if (response.ok) {
      failure = null;
      propertyForm = { itemLabel: '', quantity: 1 };
      await open(detail.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  async function releaseProperty(id: number): Promise<void> {
    if (!detail) return;

    busy = true;
    const response = await nui.call('booking.property.release', { id, bookingId: detail.id });

    if (response.ok) {
      failure = null;
      await open(detail.id);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function release(): Promise<void> {
    if (!detail) return;

    busy = true;
    const id = detail.id;
    const number = detail.number;

    const response = await nui.call('booking.release', {
      id,
      version: detail.version,
      releaseReasonKey,
    });

    if (response.ok) {
      failure = null;
      confirmingRelease = false;
      status = t('booking.releasedStatus', { number });
      trigger?.focus();
      await Promise.all([open(id), load()]);
    } else {
      failure = response;
      busy = false;
    }
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
      <input type="checkbox" bind:checked={openOnly} onchange={() => void load()} />
      {t('booking.filter.openOnly')}
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

  <form class="flex flex-wrap items-end gap-2 border border-[var(--color-border)] p-3" onsubmit={book}>
    <label class="flex flex-col gap-1 text-xs">
      <span>{t('booking.field.frihetId')} <span aria-hidden="true">*</span></span>
      <input bind:value={bookForm.frihetId} required inputmode="numeric" class="w-28 border border-[var(--color-border)] px-2 py-1" />
    </label>
    <label class="flex flex-col gap-1 text-xs">
      {t('booking.field.cell')}
      <input bind:value={bookForm.cell} maxlength="32" class="border border-[var(--color-border)] px-2 py-1" />
    </label>
    <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
      {t('booking.action.book')}
    </button>
  </form>

  {#if status}
    <p class="text-xs text-[var(--color-ink-muted)]" role="status">{status}</p>
  {/if}

  <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]">
    <div class="border border-[var(--color-border)]">
      {#if rows.length === 0}
        <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">{t('booking.emptyList')}</p>
      {:else}
        <table class="w-full text-xs">
          <thead class="bg-[var(--color-surface)]">
            <tr>
              <th class="px-2 py-1 text-left font-semibold">{t('booking.column.number')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('booking.column.cell')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('booking.column.status')}</th>
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
                      {row.number}
                    </button>
                  </td>
                  <td class="px-2 py-1">{row.cell ?? '—'}</td>
                  <td class="px-2 py-1">
                    {row.releasedAt ? t('booking.status.released') : t('booking.status.open')}
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
        <p class="text-xs text-[var(--color-ink-muted)]">{t('booking.empty')}</p>
      {:else}
        <header class="mb-3 flex items-center justify-between">
          <div>
            <h2 class="font-[family-name:var(--font-mono)] text-sm font-semibold">{detail.number}</h2>
            <p class="text-xs text-[var(--color-ink-muted)]">
              {formatMoment(detail.bookedAt)} — {detail.cell ?? t('booking.column.cell')}
            </p>
          </div>
          {#if !detail.releasedAt}
            <button
              type="button"
              class="border border-[var(--color-border)] px-3 py-1 text-xs"
              disabled={busy}
              onclick={(event) => {
                trigger = event.currentTarget;
                releaseReasonKey = RELEASE_REASONS[0];
                confirmingRelease = true;
                failure = null;
              }}
            >
              {t('booking.action.release')}
            </button>
          {/if}
        </header>

        {#if detail.releasedAt && detail.releaseReasonKey}
          <p class="mb-3 border border-[var(--color-border)] px-2 py-1 text-xs">
            {t('booking.status.released')} — {t(`booking.releaseReason.${detail.releaseReasonKey}`)}
          </p>
        {/if}

        {#if confirmingRelease}
          <div class="mb-3">
            <ConfirmDialog
              label={t('booking.action.release')}
              question={t('booking.confirm.release')}
              {busy}
              {failure}
              fieldLabels={FIELD_LABELS}
              confirm={() => void release()}
              cancel={cancelConfirm}
            >
              <label class="flex flex-col gap-1 text-xs">
                {t('booking.releaseReason.label')}
                <select bind:value={releaseReasonKey} class="border border-[var(--color-border)] px-2 py-1">
                  {#each RELEASE_REASONS as key (key)}
                    <option value={key}>{t(`booking.releaseReason.${key}`)}</option>
                  {/each}
                </select>
              </label>
            </ConfirmDialog>
          </div>
        {/if}

        <section>
          <h3 class="mb-1 text-xs font-semibold">{t('booking.property.section')}</h3>
          {#if detail.property && detail.property.length > 0}
            <ul class="mb-2 text-xs">
              {#each detail.property as item (item.id)}
                <li class="flex items-center justify-between border-t border-[var(--color-border)] py-1">
                  <span>{item.itemLabel} ({item.quantity})</span>
                  {#if !item.returnedAt}
                    <button
                      type="button"
                      class="border border-[var(--color-border)] px-2 py-0.5"
                      onclick={() => void releaseProperty(item.id)}
                    >
                      {t('booking.action.releaseProperty')}
                    </button>
                  {:else}
                    <span class="text-[var(--color-ink-muted)]">{t('booking.property.released')}</span>
                  {/if}
                </li>
              {/each}
            </ul>
          {:else}
            <p class="mb-2 text-xs text-[var(--color-ink-muted)]">{t('booking.property.empty')}</p>
          {/if}

          <form class="flex flex-wrap items-end gap-2" onsubmit={addProperty}>
            <label class="flex flex-1 flex-col gap-1 text-xs">
              {t('booking.property.itemLabel')}
              <input bind:value={propertyForm.itemLabel} required maxlength="191" class="border border-[var(--color-border)] px-2 py-1" />
            </label>
            <label class="flex flex-col gap-1 text-xs">
              {t('booking.property.quantity')}
              <input type="number" bind:value={propertyForm.quantity} min="1" class="w-20 border border-[var(--color-border)] px-2 py-1" />
            </label>
            <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
              {t('booking.action.addProperty')}
            </button>
          </form>
        </section>
      {/if}
    </div>
  </div>
</div>
