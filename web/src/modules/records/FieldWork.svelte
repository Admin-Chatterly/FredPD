<script lang="ts">
  import { tick } from 'svelte';
  import { FI_REASONS, STOP_KINDS, STOP_REASONS, STOP_RESULTS, STOP_SEARCHES } from '@fredpd/schema';
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { fieldList, type Failure } from '../shared/failure';
  import EntityPicker from '../shared/EntityPicker.svelte';
  import PersonPicker from '../shared/PersonPicker.svelte';
  import VehiclePicker from '../shared/VehiclePicker.svelte';
  import { personDetail, personLabel, searchPersonOptions } from '../shared/pickers';
  import { personName } from '../shared/names';
  import { isStub, type Maybe, type Restricted } from './types';

  /**
   * Field interview cards and stop data (spec 7.14).
   *
   * A card is the note about somebody met on patrol who was not arrested or
   * cited, written to be found by the next officer who meets them -- so the
   * list is searched by person and vehicle first, and written second. A stop
   * is the data row every traffic or pedestrian stop leaves. Both are also
   * recorded straight from the world through ox_target; this screen is for
   * finding them again and for writing one up afterwards.
   *
   * People and vehicles are picked, never typed as ids, and the server reads
   * each one through its own access check before linking it.
   */

  interface Props {
    onOpenPerson?: (id: number) => void;
    onOpenVehicle?: (id: number) => void;
  }

  let { onOpenPerson, onOpenVehicle }: Props = $props();

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

  const LIMIT = 50;
  const MAX_ASSOCIATES = 10;
  const FOCUS = 'focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]';
  const LINK = `underline underline-offset-2 ${FOCUS}`;

  const FIELD_LABELS: Record<string, string> = {
    personId: 'fi.field.person',
    vehicleId: 'fi.field.vehicle',
    associateIds: 'fi.field.associates',
    reason: 'fi.field.reason',
    narrative: 'fi.field.narrative',
    locationText: 'fi.field.locationText',
  };

  const STOP_FIELD_LABELS: Record<string, string> = {
    personId: 'fi.field.person',
    vehicleId: 'fi.field.vehicle',
  };

  let view = $state<'cards' | 'stops'>('cards');

  // --- Cards -----------------------------------------------------------------

  let cards = $state<Maybe<Card>[]>([]);
  let cardsLoaded = $state(false);
  let detail = $state<Card | null>(null);
  let cardFailure = $state<Failure | null>(null);
  let cardStatus = $state('');
  let cardBusy = $state(false);
  let cardFilter = $state({ personId: '', vehicleId: '', mine: false });
  let writing = $state(false);

  const blankCard = () => ({
    personId: '',
    vehicleId: '',
    reason: 'suspicious_behaviour',
    narrative: '',
    locationText: '',
    // Only when asked for (7.14): written up at a desk, the desk's position
    // is not where the officer met anybody.
    here: false,
  });

  let cardForm = $state(blankCard());
  /** Associates picked so far, with the name the picker showed. */
  let associates = $state<{ id: string; label: string }[]>([]);
  let associateArea = $state<HTMLElement | null>(null);

  const cardMessages = $derived(fieldList(cardFailure, FIELD_LABELS));

  async function loadCards(): Promise<void> {
    const response = await nui.call<{ cards: Maybe<Card>[] }>('fi.list', {
      personId: Number(cardFilter.personId) || undefined,
      vehicleId: Number(cardFilter.vehicleId) || undefined,
      mine: cardFilter.mine || undefined,
      limit: LIMIT,
    });

    if (response.ok) {
      cards = response.data.cards ?? [];
      // A card the filter no longer lists is not left open beside it.
      const openId = detail?.id;
      if (openId !== undefined && !cards.some((card) => !isStub(card) && card.id === openId)) detail = null;
    } else {
      cards = [];
      cardFailure = response;
    }

    cardsLoaded = true;
  }

  async function openCard(id: number): Promise<void> {
    const response = await nui.call<{ card: Card }>('fi.get', { id });
    if (response.ok) {
      detail = response.data.card;
      cardFailure = null;
    } else {
      detail = null;
      cardFailure = response;
    }
  }

  function addAssociate(id: string, label: string): void {
    if (associates.length >= MAX_ASSOCIATES || associates.some((entry) => entry.id === id)) return;
    associates = [...associates, { id, label }];
  }

  async function removeAssociate(id: string): Promise<void> {
    associates = associates.filter((entry) => entry.id !== id);
    // The button pressed is gone; focus goes back to the picker it came from.
    await tick();
    associateArea?.querySelector<HTMLInputElement>('input')?.focus();
  }

  async function writeCard(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (cardBusy) return;
    cardBusy = true;
    cardStatus = '';

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
      cardFailure = null;
      cardStatus = t('fi.written');
      cardForm = blankCard();
      associates = [];
      writing = false;
      await loadCards();
      await openCard(response.data.id);
    } else {
      cardFailure = response;
    }

    cardBusy = false;
  }

  // --- Stops -----------------------------------------------------------------

  let stops = $state<Maybe<Stop>[]>([]);
  let stopsLoaded = $state(false);
  let stopFailure = $state<Failure | null>(null);
  let stopStatus = $state('');
  let stopBusy = $state(false);
  let stopMine = $state(false);
  let recording = $state(false);

  let stopForm = $state({
    kind: 'traffic',
    reason: 'traffic_violation',
    search: 'none',
    result: 'no_action',
    personId: '',
    vehicleId: '',
  });

  const stopMessages = $derived(fieldList(stopFailure, STOP_FIELD_LABELS));

  async function loadStops(): Promise<void> {
    const response = await nui.call<{ stops: Maybe<Stop>[] }>('stop.list', {
      mine: stopMine || undefined,
      limit: LIMIT,
    });

    if (response.ok) {
      stops = response.data.stops ?? [];
    } else {
      stops = [];
      stopFailure = response;
    }

    stopsLoaded = true;
  }

  async function recordStop(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (stopBusy) return;
    stopBusy = true;
    stopStatus = '';

    const response = await nui.call('stop.create', {
      kind: stopForm.kind,
      reason: stopForm.reason,
      search: stopForm.search,
      result: stopForm.result,
      personId: Number(stopForm.personId) || undefined,
      vehicleId: Number(stopForm.vehicleId) || undefined,
    });

    if (response.ok) {
      stopFailure = null;
      stopStatus = t('stop.recorded');
      stopForm = { ...stopForm, personId: '', vehicleId: '' };
      recording = false;
      await loadStops();
    } else {
      stopFailure = response;
    }

    stopBusy = false;
  }

  // --- Shared ----------------------------------------------------------------

  function stubContact(row: Restricted): string {
    return t('records.restricted.contact', { unit: t(`access.unit.${row.contact}`) });
  }

  /**
   * Ctrl+Enter sends the form from anywhere in it, the narrative included.
   * Escape closes the form, not the MDT: `main.ts` closes the whole NUI on an
   * Escape that reaches `window`, which would throw away a half-written card.
   */
  function formKeys(event: KeyboardEvent, close: () => void): void {
    if (event.key === 'Escape') {
      event.stopPropagation();
      event.preventDefault();
      close();
    } else if (event.key === 'Enter' && event.ctrlKey) {
      event.preventDefault();
      (event.currentTarget as HTMLFormElement).requestSubmit();
    }
  }

  void loadCards();
  void loadStops();
</script>

{#snippet personLink(person: PersonRef)}
  {#if onOpenPerson}
    <button type="button" class={LINK} onclick={() => onOpenPerson?.(person.id)}>{personName(person)}</button>
  {:else}
    {personName(person)}
  {/if}
{/snippet}

{#snippet failureBox(failure: Failure, messages: { name: string; label: string; reason: string }[])}
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
{/snippet}

<div class="flex flex-col gap-3">
  <div class="flex gap-1" role="group" aria-label={t('fi.views')}>
    <button
      type="button"
      class="{FOCUS} border px-3 py-1 text-xs"
      class:font-semibold={view === 'cards'}
      class:border-[var(--color-focus)]={view === 'cards'}
      class:border-[var(--color-border)]={view !== 'cards'}
      aria-pressed={view === 'cards'}
      onclick={() => (view = 'cards')}
    >
      {t('fi.title')}
    </button>
    <button
      type="button"
      class="{FOCUS} border px-3 py-1 text-xs"
      class:font-semibold={view === 'stops'}
      class:border-[var(--color-focus)]={view === 'stops'}
      class:border-[var(--color-border)]={view !== 'stops'}
      aria-pressed={view === 'stops'}
      onclick={() => (view = 'stops')}
    >
      {t('stop.title')}
    </button>
  </div>

  {#if view === 'cards'}
    <section class="flex flex-col gap-2" aria-labelledby="fi-heading">
      <div class="flex items-center justify-between gap-2">
        <h2 id="fi-heading" class="text-[15px] font-semibold">{t('fi.title')}</h2>
        <button
          type="button"
          class="{FOCUS} border border-[var(--color-border)] px-3 py-1 text-xs"
          aria-expanded={writing}
          onclick={() => (writing = !writing)}
        >
          {writing ? t('fi.action.closeForm') : t('fi.action.write')}
        </button>
      </div>

      {#if cardFailure}
        {@render failureBox(cardFailure, cardMessages)}
      {/if}
      {#if cardStatus}
        <p class="text-xs text-[var(--color-ink-muted)]" role="status">{cardStatus}</p>
      {/if}

      {#if writing}
        <!-- Ctrl+Enter submits and Escape closes, from any field in the form:
             shortcuts on the form itself, not a click target. -->
        <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
        <form
          class="flex flex-wrap items-end gap-2 border border-[var(--color-border)] p-3"
          onsubmit={writeCard}
          onkeydown={(event) => formKeys(event, () => (writing = false))}
        >
          <p class="w-full text-xs text-[var(--color-ink-muted)]">{t('fi.hint.needs')}</p>
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
          <div class="flex w-64 flex-col gap-1 text-xs" bind:this={associateArea}>
            <span id="fi-associate-label">{t('fi.field.associates')}</span>
            <span class="text-[var(--color-ink-muted)]">
              {t('fi.associateCount', { count: associates.length, max: MAX_ASSOCIATES })}
            </span>
            <EntityPicker
              placeholder={t('picker.person.placeholder')}
              search={searchPersonOptions}
              label={personLabel}
              detail={personDetail}
              getKey={(person) => person.id}
              selectedLabel={null}
              labelledby="fi-associate-label"
              disabled={associates.length >= MAX_ASSOCIATES}
              onSelect={(person) => addAssociate(String(person.id), personLabel(person))}
            />
            {#if associates.length > 0}
              <ul class="flex flex-wrap gap-1">
                {#each associates as associate (associate.id)}
                  <li class="border border-[var(--color-border)] px-1">
                    {associate.label}
                    <button
                      type="button"
                      class="{FOCUS} ml-1 underline"
                      aria-label={t('fi.action.removeAssociate', { name: associate.label })}
                      onclick={() => void removeAssociate(associate.id)}
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
          <button type="submit" class="{FOCUS} border border-[var(--color-border)] px-3 py-1 text-xs">
            {t('fi.action.save')}
          </button>
        </form>
      {/if}

      <!-- The search a card exists for: who has been met, and in what. -->
      <div class="flex flex-wrap items-end gap-2">
        <div class="flex w-56 flex-col gap-1 text-xs">
          <span id="fi-filter-person-label">{t('fi.filter.person')}</span>
          <PersonPicker bind:value={cardFilter.personId} labelledby="fi-filter-person-label" />
        </div>
        <div class="flex w-48 flex-col gap-1 text-xs">
          <span id="fi-filter-vehicle-label">{t('fi.filter.vehicle')}</span>
          <VehiclePicker bind:value={cardFilter.vehicleId} labelledby="fi-filter-vehicle-label" />
        </div>
        <label class="flex items-center gap-1 text-xs">
          <input type="checkbox" bind:checked={cardFilter.mine} />
          {t('fi.filter.mine')}
        </label>
        <button
          type="button"
          class="{FOCUS} border border-[var(--color-border)] px-3 py-1 text-xs"
          onclick={() => {
            cardFailure = null;
            void loadCards();
          }}
        >
          {t('fi.action.search')}
        </button>
      </div>

      <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
        <div class="border border-[var(--color-border)]">
          {#if cardsLoaded && !cardFailure && cards.length === 0}
            <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">{t('fi.empty')}</p>
          {:else if cards.length > 0}
            <table class="w-full text-[12.5px] tabular-nums">
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
                    {@const selected = detail?.id === card.id}
                    <tr
                      class="border-t border-l-2 border-t-[var(--color-border)]"
                      class:border-l-[var(--color-focus)]={selected}
                      class:border-l-transparent={!selected}
                      class:font-semibold={selected}
                    >
                      <td class="px-2 py-1 font-[family-name:var(--font-mono)] whitespace-nowrap">
                        <button
                          type="button"
                          class="{FOCUS} underline-offset-2 hover:underline"
                          aria-current={selected ? 'true' : undefined}
                          onclick={() => void openCard(card.id)}
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
            {#if cards.length >= LIMIT}
              <p class="px-2 py-1 text-xs text-[var(--color-ink-muted)]">{t('fi.capped', { count: LIMIT })}</p>
            {/if}
          {/if}
        </div>

        <div class="border border-[var(--color-border)] p-3 text-[13px]">
          {#if !detail}
            <p class="text-xs text-[var(--color-ink-muted)]">{t('fi.detail.none')}</p>
          {:else}
            <h3 class="mb-1 text-[17px] font-semibold">{t(`fi.reason.${detail.reason}`)}</h3>
            <p class="text-xs text-[var(--color-ink-muted)]">
              <span class="font-[family-name:var(--font-mono)]">{detail.createdByCallsign ?? ''}</span>
              {detail.createdByName ?? ''} · {formatMoment(detail.createdAt)}
            </p>
            {#if detail.callNumber}
              <p class="text-xs text-[var(--color-ink-muted)]">
                {t('fi.onCall')}
                <span class="font-[family-name:var(--font-mono)]">{detail.callNumber}</span>
              </p>
            {/if}
            <dl class="mt-2 grid grid-cols-[8rem_1fr] gap-x-2 gap-y-1">
              <dt class="text-[var(--color-ink-muted)]">{t('fi.field.person')}</dt>
              <dd>
                {#if detail.person}{@render personLink(detail.person)}{:else}—{/if}
              </dd>
              <dt class="text-[var(--color-ink-muted)]">{t('fi.field.vehicle')}</dt>
              <dd class="font-[family-name:var(--font-mono)]">
                {#if detail.vehicle && onOpenVehicle}
                  {@const vehicleId = detail.vehicle.id}
                  <button type="button" class={LINK} onclick={() => onOpenVehicle?.(vehicleId)}>
                    {detail.vehicle.plate}
                  </button>
                {:else}
                  {detail.vehicle ? detail.vehicle.plate : '—'}
                {/if}
              </dd>
              <dt class="text-[var(--color-ink-muted)]">{t('fi.field.locationText')}</dt>
              <dd>{detail.locationText ?? '—'}</dd>
              <dt class="text-[var(--color-ink-muted)]">{t('fi.field.associates')}</dt>
              <dd>
                {#if detail.associates && detail.associates.length > 0}
                  <ul>
                    {#each detail.associates as person (person.id)}
                      <li>{@render personLink(person)}</li>
                    {/each}
                  </ul>
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
  {:else}
    <section class="flex flex-col gap-2" aria-labelledby="stop-heading">
      <div class="flex items-center justify-between gap-2">
        <h2 id="stop-heading" class="text-[15px] font-semibold">{t('stop.title')}</h2>
        <button
          type="button"
          class="{FOCUS} border border-[var(--color-border)] px-3 py-1 text-xs"
          aria-expanded={recording}
          onclick={() => (recording = !recording)}
        >
          {recording ? t('fi.action.closeForm') : t('stop.action.record')}
        </button>
      </div>

      {#if stopFailure}
        {@render failureBox(stopFailure, stopMessages)}
      {/if}
      {#if stopStatus}
        <p class="text-xs text-[var(--color-ink-muted)]" role="status">{stopStatus}</p>
      {/if}

      {#if recording}
        <!-- Ctrl+Enter submits and Escape closes, from any field in the form:
             shortcuts on the form itself, not a click target. -->
        <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
        <form
          class="flex flex-wrap items-end gap-2 border border-[var(--color-border)] p-3"
          onsubmit={recordStop}
          onkeydown={(event) => formKeys(event, () => (recording = false))}
        >
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
          <button type="submit" class="{FOCUS} border border-[var(--color-border)] px-3 py-1 text-xs">
            {t('stop.action.save')}
          </button>
        </form>
      {/if}

      <label class="flex items-center gap-1 text-xs">
        <input type="checkbox" bind:checked={stopMine} onchange={() => void loadStops()} />
        {t('stop.filter.mine')}
      </label>

      {#if stopsLoaded && !stopFailure && stops.length === 0}
        <p class="text-xs text-[var(--color-ink-muted)]">{t('stop.empty')}</p>
      {:else if stops.length > 0}
        <table class="w-full text-[12.5px] tabular-nums">
          <thead class="bg-[var(--color-surface)]">
            <tr>
              <th class="px-2 py-1 text-left font-semibold">{t('fi.column.when')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('stop.field.kind')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('stop.field.reason')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('stop.field.search')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('stop.field.result')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('fi.field.vehicle')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('stop.column.officer')}</th>
            </tr>
          </thead>
          <tbody>
            {#each stops as stop, index (index)}
              {#if isStub(stop)}
                <tr class="border-t border-[var(--color-border)]">
                  <td class="px-2 py-1 text-[var(--color-ink-muted)]" colspan="7">
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
                  <td class="px-2 py-1 font-[family-name:var(--font-mono)]">{stop.createdByCallsign ?? '—'}</td>
                </tr>
              {/if}
            {/each}
          </tbody>
        </table>
        {#if stops.length >= LIMIT}
          <p class="text-xs text-[var(--color-ink-muted)]">{t('fi.capped', { count: LIMIT })}</p>
        {/if}
      {/if}
    </section>
  {/if}
</div>
