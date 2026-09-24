<script lang="ts">
  import { FI_REASONS, STOP_KINDS, STOP_REASONS, STOP_RESULTS, STOP_SEARCHES } from '@fredpd/schema';
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { fieldList, type Failure } from '../shared/failure';
  import EntityPicker from '../shared/EntityPicker.svelte';
  import PersonPicker from '../shared/PersonPicker.svelte';
  import { personDetail, personLabel, searchPersonOptions } from '../shared/pickers';
  import VehiclePicker from '../shared/VehiclePicker.svelte';
  import { personName } from '../shared/names';
  import { isStub, type Maybe, type Restricted } from './types';

  /**
   * Field interview cards and stop data (spec 7.14).
   *
   * A card is the note about somebody met on patrol who was not arrested or
   * cited, written to be found by the next officer who meets them. A stop is
   * the data row every traffic or pedestrian stop leaves. Both are also
   * recorded straight from the world through ox_target; this screen is for
   * writing one up afterwards and reading them back.
   *
   * People and vehicles are picked, never typed as ids, and the server reads
   * each one through its own access check before linking it.
   */

  interface PersonRef {
    id: number;
    personNumber?: string | null;
    firstName?: string | null;
    lastName?: string | null;
  }

  interface Card {
    id: number;
    reason: string;
    narrative?: string | null;
    locationText?: string | null;
    createdAt: number;
    createdByCallsign?: string | null;
    createdByName?: string | null;
    callNumber?: string | null;
    person?: PersonRef | null;
    vehicle?: { id: number; plate: string; model?: string | null } | null;
    associates?: PersonRef[];
  }

  interface Stop {
    id: number;
    kind: string;
    reason: string;
    search: string;
    result: string;
    plate?: string | null;
    createdAt: number;
    createdByCallsign?: string | null;
  }

  const FIELD_LABELS: Record<string, string> = {
    personId: 'fi.field.person',
    vehicleId: 'fi.field.vehicle',
    associateIds: 'fi.field.associates',
    reason: 'fi.field.reason',
    narrative: 'fi.field.narrative',
  };

  let cards = $state<Maybe<Card>[]>([]);
  let stops = $state<Maybe<Stop>[]>([]);
  let detail = $state<Card | null>(null);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);
  let status = $state('');
  let mine = $state(true);

  let cardForm = $state({
    personId: '',
    vehicleId: '',
    reason: 'suspicious_behaviour',
    narrative: '',
    locationText: '',
    here: true,
  });
  /** Associates picked so far, with the name the picker showed. */
  let associates = $state<{ id: string; label: string }[]>([]);

  let stopForm = $state({
    kind: 'traffic',
    reason: 'traffic_violation',
    search: 'none',
    result: 'no_action',
    personId: '',
    vehicleId: '',
  });

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  async function load(): Promise<void> {
    busy = true;

    const [cardResponse, stopResponse] = await Promise.all([
      nui.call<{ cards: Maybe<Card>[] }>('fi.list', { mine: mine || undefined, limit: 50 }),
      nui.call<{ stops: Maybe<Stop>[] }>('stop.list', { mine: mine || undefined, limit: 50 }),
    ]);

    if (cardResponse.ok) cards = cardResponse.data.cards ?? [];
    if (stopResponse.ok) stops = stopResponse.data.stops ?? [];

    failure = !cardResponse.ok ? cardResponse : !stopResponse.ok ? stopResponse : null;
    busy = false;
  }

  async function open(id: number): Promise<void> {
    busy = true;

    const response = await nui.call<{ card: Card }>('fi.get', { id });
    if (response.ok) {
      detail = response.data.card;
      failure = null;
    } else {
      detail = null;
      failure = response;
    }

    busy = false;
  }

  /** The associate picker adds to a list rather than holding one value. */
  function addAssociate(id: string, label: string): void {
    if (associates.length >= 10 || associates.some((entry) => entry.id === id)) return;
    associates = [...associates, { id, label }];
  }

  async function writeCard(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    busy = true;

    const response = await nui.call<{ id: number }>('fi.create', {
      personId: Number(cardForm.personId) || undefined,
      vehicleId: Number(cardForm.vehicleId) || undefined,
      associateIds: associates.length > 0 ? associates.map((entry) => entry.id) : undefined,
      reason: cardForm.reason,
      narrative: cardForm.narrative || undefined,
      locationText: cardForm.locationText || undefined,
      here: cardForm.here,
    });

    if (response.ok) {
      failure = null;
      status = t('fi.written');
      cardForm = { personId: '', vehicleId: '', reason: 'suspicious_behaviour', narrative: '', locationText: '', here: true };
      associates = [];
      await Promise.all([load(), open(response.data.id)]);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function recordStop(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    busy = true;

    const response = await nui.call('stop.create', {
      kind: stopForm.kind,
      reason: stopForm.reason,
      search: stopForm.search,
      result: stopForm.result,
      personId: Number(stopForm.personId) || undefined,
      vehicleId: Number(stopForm.vehicleId) || undefined,
    });

    if (response.ok) {
      failure = null;
      status = t('stop.recorded');
      stopForm = { ...stopForm, personId: '', vehicleId: '' };
      await load();
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
  <label class="flex items-center gap-1 text-xs">
    <input type="checkbox" bind:checked={mine} onchange={() => void load()} />
    {t('fi.filter.mine')}
  </label>

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

  <!-- Field interview cards -->
  <section class="border border-[var(--color-border)] p-3" aria-labelledby="fi-heading">
    <h2 id="fi-heading" class="mb-2 text-sm font-semibold">{t('fi.title')}</h2>

    <form class="mb-3 flex flex-wrap items-end gap-2" onsubmit={writeCard}>
      <div class="flex w-56 flex-col gap-1 text-xs">
        <span id="fi-person-label">{t('fi.field.person')}</span>
        <PersonPicker bind:value={cardForm.personId} labelledby="fi-person-label" />
      </div>
      <div class="flex w-48 flex-col gap-1 text-xs">
        <span id="fi-vehicle-label">{t('fi.field.vehicle')}</span>
        <VehiclePicker bind:value={cardForm.vehicleId} labelledby="fi-vehicle-label" />
      </div>
      <label class="flex flex-col gap-1 text-xs">
        {t('fi.field.reason')}
        <select bind:value={cardForm.reason} class="border border-[var(--color-border)] px-2 py-1">
          {#each FI_REASONS as reason (reason)}
            <option value={reason}>{t(`fi.reason.${reason}`)}</option>
          {/each}
        </select>
      </label>
      <label class="flex flex-col gap-1 text-xs">
        {t('fi.field.locationText')}
        <input bind:value={cardForm.locationText} maxlength="191" class="w-48 border border-[var(--color-border)] px-2 py-1" />
      </label>
      <label class="flex w-full flex-col gap-1 text-xs">
        {t('fi.field.narrative')}
        <textarea rows="2" bind:value={cardForm.narrative} maxlength="1000" class="border border-[var(--color-border)] px-2 py-1"></textarea>
      </label>
      <div class="flex w-56 flex-col gap-1 text-xs">
        <span id="fi-associate-label">{t('fi.field.associates')}</span>
        <EntityPicker
          placeholder={t('picker.person.placeholder')}
          search={searchPersonOptions}
          label={personLabel}
          detail={personDetail}
          getKey={(person) => person.id}
          selectedLabel={null}
          labelledby="fi-associate-label"
          disabled={associates.length >= 10}
          onSelect={(person) => addAssociate(String(person.id), personLabel(person))}
        />
        {#if associates.length > 0}
          <ul class="flex flex-wrap gap-1">
            {#each associates as associate (associate.id)}
              <li class="border border-[var(--color-border)] px-1">
                {associate.label}
                <button
                  type="button"
                  class="ml-1 underline"
                  aria-label={t('fi.action.removeAssociate', { name: associate.label })}
                  onclick={() => (associates = associates.filter((entry) => entry.id !== associate.id))}
                >
                  {t('fi.action.remove')}
                </button>
              </li>
            {/each}
          </ul>
        {/if}
      </div>
      <label class="flex items-center gap-1 text-xs">
        <input type="checkbox" bind:checked={cardForm.here} />
        {t('fi.field.here')}
      </label>
      <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
        {t('fi.action.write')}
      </button>
    </form>

    <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
      <div class="border border-[var(--color-border)]">
        {#if cards.length === 0}
          <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">{t('fi.empty')}</p>
        {:else}
          <table class="w-full text-xs">
            <thead class="bg-[var(--color-surface)]">
              <tr>
                <th class="px-2 py-1 text-left font-semibold">{t('fi.column.when')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('fi.field.person')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('fi.field.reason')}</th>
              </tr>
            </thead>
            <tbody>
              {#each cards as card, index (index)}
                {#if isStub(card)}
                  <tr class="border-t border-[var(--color-border)]">
                    <td class="px-2 py-1 text-[var(--color-ink-muted)]" colspan="3">
                      {t('records.restricted.title')} — {stubContact(card)}
                    </td>
                  </tr>
                {:else}
                  <tr class="border-t border-[var(--color-border)]" class:bg-[var(--color-surface)]={detail?.id === card.id}>
                    <td class="px-2 py-1 font-[family-name:var(--font-mono)] whitespace-nowrap">
                      <button
                        type="button"
                        class="underline-offset-2 hover:underline"
                        aria-current={detail?.id === card.id ? 'true' : undefined}
                        onclick={() => void open(card.id)}
                      >
                        {formatMoment(card.createdAt)}
                      </button>
                    </td>
                    <td class="px-2 py-1">{card.person ? personName(card.person) : '—'}</td>
                    <td class="px-2 py-1">{t(`fi.reason.${card.reason}`)}</td>
                  </tr>
                {/if}
              {/each}
            </tbody>
          </table>
        {/if}
      </div>

      <div class="border border-[var(--color-border)] p-3 text-xs">
        {#if !detail}
          <p class="text-[var(--color-ink-muted)]">{t('fi.detail.none')}</p>
        {:else}
          <h3 class="mb-1 text-sm font-semibold">{t(`fi.reason.${detail.reason}`)}</h3>
          <p class="text-[var(--color-ink-muted)]">
            {detail.createdByCallsign ?? ''} {detail.createdByName ?? ''} · {formatMoment(detail.createdAt)}
            {#if detail.callNumber}· {t('fi.onCall', { number: detail.callNumber })}{/if}
          </p>
          <dl class="mt-2 grid grid-cols-[8rem_1fr] gap-x-2 gap-y-1">
            <dt class="text-[var(--color-ink-muted)]">{t('fi.field.person')}</dt>
            <dd>{detail.person ? personName(detail.person) : '—'}</dd>
            <dt class="text-[var(--color-ink-muted)]">{t('fi.field.vehicle')}</dt>
            <dd class="font-[family-name:var(--font-mono)]">{detail.vehicle ? detail.vehicle.plate : '—'}</dd>
            <dt class="text-[var(--color-ink-muted)]">{t('fi.field.locationText')}</dt>
            <dd>{detail.locationText ?? '—'}</dd>
            <dt class="text-[var(--color-ink-muted)]">{t('fi.field.associates')}</dt>
            <dd>
              {#if detail.associates && detail.associates.length > 0}
                {detail.associates.map((person) => personName(person)).join('; ')}
              {:else}
                —
              {/if}
            </dd>
          </dl>
          {#if detail.narrative}
            <p class="mt-2 whitespace-pre-wrap">{detail.narrative}</p>
          {/if}
        {/if}
      </div>
    </div>
  </section>

  <!-- Stops -->
  <section class="border border-[var(--color-border)] p-3" aria-labelledby="stop-heading">
    <h2 id="stop-heading" class="mb-2 text-sm font-semibold">{t('stop.title')}</h2>

    <form class="mb-3 flex flex-wrap items-end gap-2" onsubmit={recordStop}>
      <label class="flex flex-col gap-1 text-xs">
        {t('stop.field.kind')}
        <select bind:value={stopForm.kind} class="border border-[var(--color-border)] px-2 py-1">
          {#each STOP_KINDS as kind (kind)}
            <option value={kind}>{t(`stop.kind.${kind}`)}</option>
          {/each}
        </select>
      </label>
      <label class="flex flex-col gap-1 text-xs">
        {t('stop.field.reason')}
        <select bind:value={stopForm.reason} class="border border-[var(--color-border)] px-2 py-1">
          {#each STOP_REASONS as reason (reason)}
            <option value={reason}>{t(`stop.reason.${reason}`)}</option>
          {/each}
        </select>
      </label>
      <label class="flex flex-col gap-1 text-xs">
        {t('stop.field.search')}
        <select bind:value={stopForm.search} class="border border-[var(--color-border)] px-2 py-1">
          {#each STOP_SEARCHES as search (search)}
            <option value={search}>{t(`stop.search.${search}`)}</option>
          {/each}
        </select>
      </label>
      <label class="flex flex-col gap-1 text-xs">
        {t('stop.field.result')}
        <select bind:value={stopForm.result} class="border border-[var(--color-border)] px-2 py-1">
          {#each STOP_RESULTS as result (result)}
            <option value={result}>{t(`stop.result.${result}`)}</option>
          {/each}
        </select>
      </label>
      <div class="flex w-56 flex-col gap-1 text-xs">
        <span id="stop-person-label">{t('fi.field.person')}</span>
        <PersonPicker bind:value={stopForm.personId} labelledby="stop-person-label" />
      </div>
      <div class="flex w-48 flex-col gap-1 text-xs">
        <span id="stop-vehicle-label">{t('fi.field.vehicle')}</span>
        <VehiclePicker bind:value={stopForm.vehicleId} labelledby="stop-vehicle-label" />
      </div>
      <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
        {t('stop.action.record')}
      </button>
    </form>

    {#if stops.length === 0}
      <p class="text-xs text-[var(--color-ink-muted)]">{t('stop.empty')}</p>
    {:else}
      <table class="w-full text-xs">
        <thead class="bg-[var(--color-surface)]">
          <tr>
            <th class="px-2 py-1 text-left font-semibold">{t('fi.column.when')}</th>
            <th class="px-2 py-1 text-left font-semibold">{t('stop.field.kind')}</th>
            <th class="px-2 py-1 text-left font-semibold">{t('stop.field.reason')}</th>
            <th class="px-2 py-1 text-left font-semibold">{t('stop.field.search')}</th>
            <th class="px-2 py-1 text-left font-semibold">{t('stop.field.result')}</th>
            <th class="px-2 py-1 text-left font-semibold">{t('fi.field.vehicle')}</th>
          </tr>
        </thead>
        <tbody>
          {#each stops as stop, index (index)}
            {#if isStub(stop)}
              <tr class="border-t border-[var(--color-border)]">
                <td class="px-2 py-1 text-[var(--color-ink-muted)]" colspan="6">
                  {t('records.restricted.title')} — {stubContact(stop)}
                </td>
              </tr>
            {:else}
              <tr class="border-t border-[var(--color-border)]">
                <td class="px-2 py-1 font-[family-name:var(--font-mono)] whitespace-nowrap">{formatMoment(stop.createdAt)}</td>
                <td class="px-2 py-1">{t(`stop.kind.${stop.kind}`)}</td>
                <td class="px-2 py-1">{t(`stop.reason.${stop.reason}`)}</td>
                <td class="px-2 py-1">{t(`stop.search.${stop.search}`)}</td>
                <td class="px-2 py-1">{t(`stop.result.${stop.result}`)}</td>
                <td class="px-2 py-1 font-[family-name:var(--font-mono)]">{stop.plate ?? '—'}</td>
              </tr>
            {/if}
          {/each}
        </tbody>
      </table>
    {/if}
  </section>
</div>
