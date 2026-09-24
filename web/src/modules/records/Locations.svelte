<script lang="ts">
  import { LOCATION_HAZARD_KINDS, LOCATION_KEYHOLDER_ROLES, LOCATION_KINDS } from '@fredpd/schema';
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { fieldList, type Failure } from '../shared/failure';
  import PersonPicker from '../shared/PersonPicker.svelte';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import { personName } from '../shared/names';
  import { isStub, type Maybe, type Restricted } from './types';

  /**
   * Locations and premises (spec 7.6): the address index, what an officer
   * should know before walking up to the door, and who holds the keys.
   *
   * A premise's position is never typed: "At my position" asks the server to
   * read it off the officer's own ped (invariant 1). The hazards entered here
   * are what the call card and the dispatch notice show when a call lands at
   * the address.
   */

  interface LocationRow {
    id: number;
    label: string;
    kind: string;
    x?: number | null;
    y?: number | null;
    radius: number;
    notes?: string | null;
    liveHazards?: number;
    updatedAt?: number;
    version: number;
  }

  interface Hazard {
    id: number;
    kind: string;
    note?: string | null;
    expiresAt?: number | null;
    cancelledAt?: number | null;
    createdAt: number;
    createdByCallsign?: string | null;
    createdByName?: string | null;
  }

  interface Keyholder {
    role: string;
    restricted?: boolean;
    person?: {
      id: number;
      personNumber?: string | null;
      firstName?: string | null;
      lastName?: string | null;
      phone?: string | null;
    };
  }

  interface HistoryRow {
    id: number;
    callNumber: string;
    type: string;
    status: string;
    disposition?: string | null;
    receivedAt: number;
  }

  interface Detail {
    location: LocationRow;
    hazards: Hazard[];
    keyholders: Keyholder[];
    history: HistoryRow[];
  }

  const FIELD_LABELS: Record<string, string> = {
    label: 'location.field.label',
    kind: 'location.field.kind',
    here: 'location.field.here',
    personId: 'location.field.keyholder',
    note: 'location.field.note',
    version: 'anmalan.column.version',
  };

  let term = $state('');
  let rows = $state<Maybe<LocationRow>[]>([]);
  let detail = $state<Detail | null>(null);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);
  let status = $state('');

  let creating = $state(false);
  let createForm = $state({ label: '', kind: 'residence', notes: '', here: true });
  /** The keyholder a removal is waiting to be confirmed for (6.4). */
  let removing = $state<{ id: number; name: string } | null>(null);
  let hazardForm = $state({ kind: 'dog', note: '', days: '' });
  let keyholderForm = $state({ personId: '', role: 'owner' });

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  function lapsed(hazard: Hazard): boolean {
    return !hazard.cancelledAt && !!hazard.expiresAt && hazard.expiresAt <= Date.now() / 1000;
  }

  function isLive(hazard: Hazard): boolean {
    return !hazard.cancelledAt && !lapsed(hazard);
  }

  async function load(): Promise<void> {
    busy = true;

    const response = await nui.call<{ locations: Maybe<LocationRow>[] }>('location.search', {
      term: term || undefined,
      limit: 50,
    });

    if (response.ok) {
      rows = response.data.locations ?? [];
      failure = null;
    } else {
      failure = response;
    }

    busy = false;
  }

  async function open(id: number): Promise<void> {
    busy = true;

    const response = await nui.call<Detail>('location.get', { id });

    if (response.ok) {
      detail = response.data;
      failure = null;
    } else {
      detail = null;
      failure = response;
    }

    busy = false;
  }

  /** Every write here answers the same way: re-read the premise and the list. */
  async function write(route: string, input: Record<string, unknown>, done?: string): Promise<boolean> {
    busy = true;
    const response = await nui.call<{ id?: number; locationId?: number }>(route, input);

    if (!response.ok) {
      failure = response;
      busy = false;
      return false;
    }

    failure = null;
    if (done) status = done;

    const id = detail?.location.id ?? response.data.id;
    await Promise.all([load(), id ? open(id) : Promise.resolve()]);
    return true;
  }

  async function create(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    busy = true;

    const response = await nui.call<{ id: number }>('location.create', {
      label: createForm.label,
      kind: createForm.kind,
      notes: createForm.notes || undefined,
      here: createForm.here,
    });

    if (response.ok) {
      failure = null;
      status = t('location.created', { label: createForm.label });
      createForm = { label: '', kind: 'residence', notes: '', here: true };
      creating = false;
      await Promise.all([load(), open(response.data.id)]);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function moveHere(): Promise<void> {
    if (!detail) return;
    await write(
      'location.update',
      { id: detail.location.id, version: detail.location.version, here: true },
      t('location.moved'),
    );
  }

  async function addHazard(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail) return;

    const ok = await write('location.hazard.add', {
      locationId: detail.location.id,
      kind: hazardForm.kind,
      note: hazardForm.note || undefined,
      days: Number(hazardForm.days) || undefined,
    });

    if (ok) hazardForm = { kind: 'dog', note: '', days: '' };
  }

  async function cancelHazard(id: number): Promise<void> {
    await write('location.hazard.cancel', { id });
  }

  async function addKeyholder(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail) return;

    // Said after the attempt, beside the field, rather than a button that
    // will not press (6.4).
    if (!keyholderForm.personId) {
      failure = { err: 'invalid', fields: { personId: 'required' } };
      return;
    }

    const ok = await write('location.keyholder.set', {
      locationId: detail.location.id,
      personId: Number(keyholderForm.personId),
      role: keyholderForm.role,
    });

    if (ok) keyholderForm = { personId: '', role: 'owner' };
  }

  async function removeKeyholder(): Promise<void> {
    if (!detail || !removing) return;
    const ok = await write('location.keyholder.remove', { locationId: detail.location.id, personId: removing.id });
    if (ok) removing = null;
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
    <label class="flex flex-col gap-1 text-xs">
      {t('location.search')}
      <input type="search" bind:value={term} maxlength="64" class="w-64 border border-[var(--color-border)] px-2 py-1" />
    </label>
    <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
      {t('records.search.run')}
    </button>
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

  {#if !creating}
    <button
      type="button"
      class="self-start border border-[var(--color-border)] px-3 py-1 text-xs"
      onclick={() => (creating = true)}
    >
      {t('location.action.create')}
    </button>
  {:else}
  <form class="flex flex-wrap items-end gap-2 border border-[var(--color-border)] p-3" onsubmit={create}>
    <label class="flex flex-col gap-1 text-xs">
      <span>{t('location.field.label')} <span aria-hidden="true">*</span></span>
      <input bind:value={createForm.label} required maxlength="191" class="w-64 border border-[var(--color-border)] px-2 py-1" />
    </label>
    <label class="flex flex-col gap-1 text-xs">
      {t('location.field.kind')}
      <select bind:value={createForm.kind} class="border border-[var(--color-border)] px-2 py-1">
        {#each LOCATION_KINDS as kind (kind)}
          <option value={kind}>{t(`location.kind.${kind}`)}</option>
        {/each}
      </select>
    </label>
    <label class="flex flex-col gap-1 text-xs">
      {t('location.field.notes')}
      <input bind:value={createForm.notes} maxlength="500" class="w-64 border border-[var(--color-border)] px-2 py-1" />
    </label>
    <label class="flex items-center gap-1 text-xs">
      <input type="checkbox" bind:checked={createForm.here} />
      {t('location.field.here')}
    </label>
    <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
      {t('location.action.create')}
    </button>
    <button type="button" class="border border-[var(--color-border)] px-3 py-1 text-xs" onclick={() => (creating = false)}>
      {t('form.cancel')}
    </button>
  </form>
  {/if}

  {#if status}
    <p class="text-xs text-[var(--color-ink-muted)]" role="status">{status}</p>
  {/if}

  <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1.3fr)]">
    <div class="border border-[var(--color-border)]">
      {#if rows.length === 0}
        <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">{t('location.empty')}</p>
      {:else}
        <table class="w-full text-xs">
          <thead class="bg-[var(--color-surface)]">
            <tr>
              <th class="px-2 py-1 text-left font-semibold">{t('location.field.label')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('location.field.kind')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('location.column.hazards')}</th>
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
                <tr
                  class="border-t border-[var(--color-border)]"
                  class:bg-[var(--color-surface)]={detail?.location.id === row.id}
                >
                  <td class="px-2 py-1">
                    <button
                      type="button"
                      class="text-left underline-offset-2 hover:underline"
                      class:font-semibold={detail?.location.id === row.id}
                      aria-current={detail?.location.id === row.id ? 'true' : undefined}
                      onclick={() => void open(row.id)}
                    >
                      {row.label}
                    </button>
                  </td>
                  <td class="px-2 py-1">{t(`location.kind.${row.kind}`)}</td>
                  <td class="px-2 py-1" class:text-[var(--color-alert)]={(row.liveHazards ?? 0) > 0}>
                    {(row.liveHazards ?? 0) > 0 ? row.liveHazards : '—'}
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
        <p class="text-xs text-[var(--color-ink-muted)]">{t('location.detail.none')}</p>
      {:else}
        <header class="mb-3">
          <h2 class="text-sm font-semibold">{detail.location.label}</h2>
          <p class="text-xs text-[var(--color-ink-muted)]">
            {t(`location.kind.${detail.location.kind}`)} ·
            {detail.location.x !== null && detail.location.x !== undefined
              ? t('location.positioned', { radius: detail.location.radius })
              : t('location.noPosition')}
          </p>
          {#if detail.location.notes}
            <p class="mt-1 text-xs">{detail.location.notes}</p>
          {/if}
          <button
            type="button"
            class="mt-2 border border-[var(--color-border)] px-2 py-0.5 text-xs"
            disabled={busy}
            onclick={() => void moveHere()}
          >
            {t('location.action.moveHere')}
          </button>
        </header>

        <!-- Hazards: what the call card shows when a call lands here. -->
        <section class="mb-3 border-t border-[var(--color-border)] pt-2">
          <h3 class="mb-1 text-xs font-semibold">{t('location.section.hazards')}</h3>
          {#if detail.hazards.length === 0}
            <p class="text-xs text-[var(--color-ink-muted)]">{t('location.hazard.none')}</p>
          {:else}
            <ul class="flex flex-col gap-1 text-xs">
              {#each detail.hazards as hazard (hazard.id)}
                <li
                  class="flex items-start justify-between gap-2 border-t border-[var(--color-border)] py-1"
                  class:text-[var(--color-ink-muted)]={!isLive(hazard)}
                >
                  <span>
                    <span class:font-semibold={isLive(hazard)} class:text-[var(--color-alert)]={isLive(hazard)}>
                      {t(`location.hazard.${hazard.kind}`)}
                    </span>
                    {#if hazard.note}— {hazard.note}{/if}
                    <span class="block text-[var(--color-ink-muted)]">
                      {hazard.createdByCallsign ?? ''} {hazard.createdByName ?? ''} · {formatMoment(hazard.createdAt)}
                      {#if hazard.cancelledAt}
                        · {t('location.hazard.cancelled')}
                      {:else if lapsed(hazard)}
                        · {t('location.hazard.lapsed')}
                      {:else if hazard.expiresAt}
                        · {t('location.hazard.until', { at: formatMoment(hazard.expiresAt) })}
                      {/if}
                    </span>
                  </span>
                  {#if isLive(hazard)}
                    <button
                      type="button"
                      class="border border-[var(--color-border)] px-2 py-0.5"
                      disabled={busy}
                      aria-label={t('location.action.cancelHazardNamed', { hazard: t(`location.hazard.${hazard.kind}`) })}
                      onclick={() => void cancelHazard(hazard.id)}
                    >
                      {t('location.action.cancelHazard')}
                    </button>
                  {/if}
                </li>
              {/each}
            </ul>
          {/if}

          <form class="mt-2 flex flex-wrap items-end gap-2" onsubmit={addHazard}>
            <label class="flex flex-col gap-1 text-xs">
              {t('location.field.hazardKind')}
              <select bind:value={hazardForm.kind} class="border border-[var(--color-border)] px-2 py-1">
                {#each LOCATION_HAZARD_KINDS as kind (kind)}
                  <option value={kind}>{t(`location.hazard.${kind}`)}</option>
                {/each}
              </select>
            </label>
            <label class="flex flex-col gap-1 text-xs">
              {t('location.field.note')}
              <input bind:value={hazardForm.note} maxlength="255" class="w-48 border border-[var(--color-border)] px-2 py-1" />
            </label>
            <label class="flex flex-col gap-1 text-xs">
              {t('location.field.days')}
              <input type="number" min="1" max="365" bind:value={hazardForm.days} class="w-20 border border-[var(--color-border)] px-2 py-1" />
            </label>
            <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
              {t('location.action.addHazard')}
            </button>
          </form>
        </section>

        <section class="mb-3 border-t border-[var(--color-border)] pt-2">
          <h3 class="mb-1 text-xs font-semibold">{t('location.section.keyholders')}</h3>
          {#if detail.keyholders.length === 0}
            <p class="text-xs text-[var(--color-ink-muted)]">{t('location.keyholder.none')}</p>
          {:else}
            <ul class="flex flex-col gap-1 text-xs">
              {#each detail.keyholders as holder, index (index)}
                <li class="flex items-center justify-between gap-2 border-t border-[var(--color-border)] py-1">
                  {#if holder.person}
                    <span>
                      {t(`location.role.${holder.role}`)}: {personName(holder.person)}
                      {#if holder.person.phone}
                        <span>· {holder.person.phone}</span>
                      {/if}
                    </span>
                    <button
                      type="button"
                      class="border border-[var(--color-border)] px-2 py-0.5"
                      disabled={busy}
                      aria-label={t('location.action.removeKeyholderNamed', { name: personName(holder.person) })}
                      onclick={() => (removing = { id: holder.person!.id, name: personName(holder.person!) })}
                    >
                      {t('location.action.removeKeyholder')}
                    </button>
                  {:else}
                    <span class="text-[var(--color-ink-muted)]">
                      {t(`location.role.${holder.role}`)}: {t('records.restricted.title')}
                    </span>
                  {/if}
                </li>
              {/each}
            </ul>
          {/if}

          {#if removing}
            <div class="mt-2">
              <ConfirmDialog
                label={t('location.action.removeKeyholderTitle')}
                question={t('location.confirm.removeKeyholder', { name: removing.name })}
                {busy}
                {failure}
                fieldLabels={FIELD_LABELS}
                confirm={() => void removeKeyholder()}
                cancel={() => (removing = null)}
              />
            </div>
          {/if}

          <form class="mt-2 flex flex-wrap items-end gap-2" onsubmit={addKeyholder}>
            <div class="flex w-56 flex-col gap-1 text-xs">
              <span id="location-keyholder-label">{t('location.field.keyholder')}</span>
              <PersonPicker bind:value={keyholderForm.personId} labelledby="location-keyholder-label" />
            </div>
            <label class="flex flex-col gap-1 text-xs">
              {t('location.field.role')}
              <select bind:value={keyholderForm.role} class="border border-[var(--color-border)] px-2 py-1">
                {#each LOCATION_KEYHOLDER_ROLES as role (role)}
                  <option value={role}>{t(`location.role.${role}`)}</option>
                {/each}
              </select>
            </label>
            <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
              {t('location.action.addKeyholder')}
            </button>
          </form>
        </section>

        <section class="border-t border-[var(--color-border)] pt-2">
          <h3 class="mb-1 text-xs font-semibold">{t('location.section.history')}</h3>
          {#if detail.history.length === 0}
            <p class="text-xs text-[var(--color-ink-muted)]">{t('location.history.none')}</p>
          {:else}
            <table class="w-full text-xs">
              <tbody>
                {#each detail.history as call (call.id)}
                  <tr class="border-t border-[var(--color-border)]">
                    <td class="px-1 py-1 font-[family-name:var(--font-mono)] whitespace-nowrap">{call.callNumber}</td>
                    <td class="px-1 py-1">{t(`cad.callType.${call.type}`)}</td>
                    <td class="px-1 py-1">
                      {call.disposition ? t(`cad.disposition.${call.disposition}`) : t(`cad.callStatus.${call.status}`)}
                    </td>
                    <td class="px-1 py-1 font-[family-name:var(--font-mono)] whitespace-nowrap">{formatMoment(call.receivedAt)}</td>
                  </tr>
                {/each}
              </tbody>
            </table>
          {/if}
        </section>
      {/if}
    </div>
  </div>
</div>
