<script lang="ts">
  import { nui } from '../../lib/nui';
  import { getLocale, t } from '../../lib/i18n';
  import type { ErrorCode } from '@fredpd/schema';
  import { CALL_DISPOSITIONS, CALL_PROGRESS_STATUSES } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import {
    beatLabel,
    clockOf,
    consolePlacement,
    elapsed,
    FIELD_LABELS,
    priorityInk,
    priorityRule,
    priorityShort,
    stamp,
    type Beat,
    type CallCardData,
    type LogEntry,
    type Unit,
  } from './Dispatch.svelte';

  /**
   * The call card (spec 7.16).
   *
   * Everything a call is read back for: what it is and where, who called it in,
   * the narrative log, the units on it, the five timestamps, the persons and
   * vehicles linked to it, and — once it is closed — the disposition that says
   * what came of it.
   *
   * ## What is drawn, and what the server decides
   *
   * Every action is drawn for every reader and refused by the server, which
   * answers with a field code this card reads out: `no_unit` for a session that
   * never signed on, `off_duty` for one that has, `not_assigned` for an officer
   * reporting progress on somebody else's call, `already_assigned`,
   * `call_cleared` for a call closed while the form was open, and
   * `needs_acknowledgement` for an emergency nobody has yet signed off. Hiding
   * a button would be a second access control in the one place it cannot be
   * enforced (invariant 4).
   *
   * The one thing that is drawn conditionally is the **recommendation**, and
   * that is because the server decides whether to send it at all: `call.get`
   * returns `recommended` only for a session that may dispatch, and only for a
   * call that has coordinates to measure from. Absent is not the same as empty
   * — no panel, against a panel that says there is nobody to recommend — and a
   * card that assumed the list was always there would draw an empty picker at
   * every officer in the department.
   */

  interface Props {
    card: CallCardData | null;
    beats: Beat[];
    /** The whole board, so units can be sent to this call from the card. */
    units: Unit[];
    now: number;
    loading: boolean;
    error: ErrorCode | null;
    onchanged: () => void;
  }

  const { card, beats, units, now, loading, error, onchanged }: Props = $props();

  let note = $state('');
  let selectedUnits = $state<string[]>([]);
  let removeUnits = $state<string[]>([]);
  let lead = $state('');
  /** The first disposition on the list, which is `report_taken` (7.16). */
  const FIRST_DISPOSITION = CALL_DISPOSITIONS[0];

  let disposition = $state<string>(FIRST_DISPOSITION);
  let closingNote = $state('');
  let selfAssignArmed = $state(false);

  let failure = $state<Failure | null>(null);
  let busy = $state(false);

  /**
   * Which call the forms below belong to.
   *
   * A dispatcher who half-fills a dispatch on one call and then opens another
   * must not send those units to the second one, so the selections are cleared
   * when the card changes — and only then, or typing a note would clear itself
   * on every push that touches the call.
   */
  let formsFor = $state<number | null>(null);

  $effect(() => {
    const id = card?.id ?? null;
    if (id === formsFor) return;

    formsFor = id;
    note = '';
    selectedUnits = [];
    removeUnits = [];
    lead = '';
    closingNote = '';
    disposition = FIRST_DISPOSITION;
    selfAssignArmed = false;
    failure = null;
  });

  /**
   * The arguments of a generated log line that name a vocabulary rather than
   * carrying data (7.16.1).
   *
   * `message_args` stores the enum member — `en_route`, `caller`,
   * `arrest_made` — and never a rendered label, so the line reads in the
   * reader's language and not in the language of whoever caused it. That means
   * each of these has to be resolved through its own key here, which is the
   * half of the arrangement the NUI owns.
   */
  const VOCABULARY: Record<string, Record<string, string>> = {
    'cad.log.unit_status': { status: 'cad.unitStatus.' },
    'cad.log.call_status': { status: 'cad.callStatus.' },
    'cad.log.linked': { role: 'cad.linkRole.' },
    'cad.log.cleared': { disposition: 'cad.disposition.' },
    'cad.log.cancelled': { disposition: 'cad.disposition.' },
    'cad.log.priority_changed': { from: 'cad.priorityShort.p', to: 'cad.priorityShort.p' },
  };

  /**
   * One line of the narrative, in the reader's language.
   *
   * A note is what a person typed and is printed as it was written. Everything
   * else is a sentence the system wrote, stored as a key and its arguments, so
   * the same line reads as English to one dispatcher and as Swedish to the
   * officer on the call (invariant 6).
   *
   * The arguments arrive as `messageArgs` from `call.get` and as `args` from
   * the `fredpd:cad:log` push; both names are read, because a card that knew
   * only one would render raw placeholders for as long as it stayed open.
   */
  function logText(entry: LogEntry): string {
    if (entry.entryType === 'note') return entry.body ?? '';

    const key = entry.messageKey;
    if (!key) return entry.body ?? '';

    const raw = entry.messageArgs ?? entry.args ?? {};
    const prefixes = VOCABULARY[key] ?? {};
    const args: Record<string, string | number> = {};

    for (const [name, value] of Object.entries(raw)) {
      const prefix = prefixes[name];
      args[name] = prefix ? t(`${prefix}${String(value)}`) : value;
    }

    return t(key, args);
  }

  /** Metres, in the reader's own units and spelling rather than a bare "m". */
  const distance = new Intl.NumberFormat(getLocale(), {
    style: 'unit',
    unit: 'meter',
    unitDisplay: 'short',
    maximumFractionDigits: 0,
  });

  const activeUnits = $derived((card?.units ?? []).filter((unit) => unit.active === 1));

  /** The board, closest thing to hand first: who is free, then everyone else. */
  const assignable = $derived(
    [...units].sort((left, right) => {
      const freeLeft = left.onCallId === null ? 0 : 1;
      const freeRight = right.onCallId === null ? 0 : 1;

      return freeLeft - freeRight || left.callsign.localeCompare(right.callsign);
    }),
  );

  /** Who could be the lead: the units on the call plus the ones being added. */
  const leadChoices = $derived([
    ...activeUnits.map((unit) => ({ officerId: unit.officerId, callsign: unit.callsign })),
    ...assignable
      .filter((unit) => selectedUnits.includes(String(unit.officerId)))
      .filter((unit) => !activeUnits.some((on) => on.officerId === unit.officerId))
      .map((unit) => ({ officerId: unit.officerId, callsign: unit.callsign })),
  ]);

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  /** The position age of a recommended unit, from the board row beside it. */
  function positionAge(officerId: number): string {
    const unit = units.find((candidate) => candidate.officerId === officerId);
    if (!unit || unit.positionAtUnix == null) return t('cad.map.noPosition');

    return t('cad.map.positionAge', { duration: elapsed(unit.positionAtUnix, now) });
  }

  function toggle(list: string[], value: string): string[] {
    return list.includes(value) ? list.filter((entry) => entry !== value) : [...list, value];
  }

  async function send(route: string, payload: Record<string, unknown>): Promise<void> {
    busy = true;

    const response = await nui.call(route, payload);

    if (response.ok) {
      failure = null;
      onchanged();
    } else {
      failure = response;
    }

    busy = false;
  }

  async function addNote(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!card) return;

    const body = note;
    await send('call.note', { callId: card.id, body });

    if (!failure) note = '';
  }

  async function dispatch(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!card) return;

    await send('call.dispatch', {
      placementId: consolePlacement() ?? undefined,
      callId: card.id,
      officerIds: selectedUnits.length > 0 ? selectedUnits : undefined,
      removeOfficerIds: removeUnits.length > 0 ? removeUnits : undefined,
      leadOfficerId: lead || undefined,
    });

    if (!failure) {
      selectedUnits = [];
      removeUnits = [];
      lead = '';
    }
  }

  async function clear(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!card) return;

    await send('call.clear', {
      callId: card.id,
      disposition,
      note: closingNote || undefined,
    });
  }

  /**
   * The three one-button writes.
   *
   * Each one reads the card again rather than closing over the id the button
   * was drawn with: a push can replace the card between the draw and the press,
   * and a write addressed to the call that *was* open is the one mistake a
   * console must not make.
   */
  async function progress(status: string): Promise<void> {
    if (!card) return;

    await send('call.status', { callId: card.id, status });
  }

  async function selfAssign(): Promise<void> {
    if (!card) return;

    await send('call.self_assign', { callId: card.id });
    selfAssignArmed = false;
  }

  async function acknowledge(): Promise<void> {
    if (!card) return;

    await send('call.acknowledge', { callId: card.id });
  }
</script>

<div class="flex min-h-0 flex-col border border-[var(--color-border)]">
  {#if loading}
    <p class="px-3 py-3 text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
  {:else if error}
    <p class="px-3 py-3 text-sm">{t(`error.${error}`)}</p>
  {:else if !card}
    <p class="px-3 py-3 text-sm text-[var(--color-ink-muted)]">{t('cad.card.none')}</p>
  {:else}
    <header
      class="flex flex-wrap items-baseline gap-x-3 gap-y-1 border-b border-[var(--color-border)] px-3 py-2 {priorityRule(
        card.call.priority,
      )}"
    >
      <h2 class="text-sm font-semibold">
        {t('cad.card.title', { number: card.call.callNumber })}
      </h2>
      <span
        class="text-xs font-semibold {priorityInk(card.call.priority)}"
        title={t(`cad.priority.p${card.call.priority}`)}
      >
        {priorityShort(card.call.priority)}
      </span>
      <span class="text-xs">{t(`cad.callType.${card.call.type}`)}</span>
      <span class="text-xs text-[var(--color-ink-muted)]">
        {t(`cad.callStatus.${card.call.status}`)}
      </span>

      {#if card.call.source === 'panic'}
        <span class="text-xs font-semibold text-[var(--color-alert)]">
          {card.call.acknowledgedAt
            ? t('cad.emergency.acknowledged', { callsign: card.call.acknowledgedBy ?? '' })
            : t('cad.emergency.notAcknowledged')}
        </span>
      {/if}
    </header>

    <div class="min-h-0 flex-1 overflow-y-auto">
      <!-- What the call is. -->
      <dl class="grid grid-cols-[10rem_1fr] gap-x-3 gap-y-1 px-3 py-2 text-xs">
        <dt class="text-[var(--color-ink-muted)]">{t('cad.column.location')}</dt>
        <dd>{card.call.locationText ?? ''}</dd>

        <dt class="text-[var(--color-ink-muted)]">{t('cad.column.beat')}</dt>
        <dd>{beatLabel(beats, card.call.beatId)}</dd>

        <dt class="text-[var(--color-ink-muted)]">{t('cad.column.caller')}</dt>
        <dd>{card.call.callerName ?? ''}</dd>

        <dt class="text-[var(--color-ink-muted)]">{t('cad.column.callerPhone')}</dt>
        <dd class="font-[family-name:var(--font-mono)]">{card.call.callerPhone ?? ''}</dd>

        <dt class="text-[var(--color-ink-muted)]">{t('cad.column.source')}</dt>
        <dd>
          {#if card.call.source === 'export'}
            {t('cad.source.export', { resource: card.call.sourceResource ?? '' })}
          {:else}
            {t(`cad.source.${card.call.source}`)}
          {/if}
        </dd>

        {#if card.call.disposition}
          <dt class="text-[var(--color-ink-muted)]">{t('cad.column.disposition')}</dt>
          <dd>{t(`cad.disposition.${card.call.disposition}`)}</dd>
        {/if}
      </dl>

      <!-- The five timestamps a response-time report is arithmetic on. -->
      <div class="border-t border-[var(--color-border)] px-3 py-2">
        <table class="w-full border-collapse text-xs">
          <tbody>
            <tr>
              <th scope="row" class="py-0.5 text-left font-normal text-[var(--color-ink-muted)]">
                {t('cad.time.received')}
              </th>
              <td class="py-0.5 text-right font-[family-name:var(--font-mono)]">
                {stamp(card.call.receivedAt)}
              </td>
            </tr>
            <tr>
              <th scope="row" class="py-0.5 text-left font-normal text-[var(--color-ink-muted)]">
                {t('cad.time.dispatched')}
              </th>
              <td class="py-0.5 text-right font-[family-name:var(--font-mono)]">
                {card.call.dispatchedAt ? stamp(card.call.dispatchedAt) : t('cad.time.none')}
              </td>
            </tr>
            <tr>
              <th scope="row" class="py-0.5 text-left font-normal text-[var(--color-ink-muted)]">
                {t('cad.time.enRoute')}
              </th>
              <td class="py-0.5 text-right font-[family-name:var(--font-mono)]">
                {card.call.enRouteAt ? stamp(card.call.enRouteAt) : t('cad.time.none')}
              </td>
            </tr>
            <tr>
              <th scope="row" class="py-0.5 text-left font-normal text-[var(--color-ink-muted)]">
                {t('cad.time.onScene')}
              </th>
              <td class="py-0.5 text-right font-[family-name:var(--font-mono)]">
                {card.call.onSceneAt ? stamp(card.call.onSceneAt) : t('cad.time.none')}
              </td>
            </tr>
            <tr>
              <th scope="row" class="py-0.5 text-left font-normal text-[var(--color-ink-muted)]">
                {t('cad.time.cleared')}
              </th>
              <td class="py-0.5 text-right font-[family-name:var(--font-mono)]">
                {card.call.clearedAt ? stamp(card.call.clearedAt) : t('cad.time.none')}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <!-- Who is on it. -->
      <section class="border-t border-[var(--color-border)] px-3 py-2">
        <h3 class="text-xs font-semibold">{t('cad.card.units')}</h3>

        {#if activeUnits.length === 0}
          <p class="mt-1 text-xs text-[var(--color-ink-muted)]">{t('cad.card.noUnits')}</p>
        {:else}
          <table class="mt-1 w-full border-collapse text-xs">
            <thead>
              <tr class="text-left text-[var(--color-ink-muted)]">
                <th scope="col" class="py-0.5 font-normal">{t('cad.column.callsign')}</th>
                <th scope="col" class="py-0.5 font-normal">{t('cad.column.unitStatus')}</th>
                <th scope="col" class="py-0.5 font-normal">{t('cad.column.lead')}</th>
              </tr>
            </thead>
            <tbody>
              {#each activeUnits as unit (unit.id)}
                {@const board = units.find((row) => row.officerId === unit.officerId)}
                <tr class="border-t border-[var(--color-border)]">
                  <td class="py-0.5 font-[family-name:var(--font-mono)]">{unit.callsign}</td>
                  <td class="py-0.5">
                    {board ? t(`cad.unitStatus.${board.status}`) : ''}
                  </td>
                  <td class="py-0.5">
                    {unit.isLead === 1 ? t('cad.dispatch.lead') : ''}
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
        {/if}
      </section>

      <!-- Persons and vehicles (7.16). -->
      <section class="border-t border-[var(--color-border)] px-3 py-2">
        <h3 class="text-xs font-semibold">{t('cad.card.links')}</h3>

        {#if card.links.length === 0}
          <p class="mt-1 text-xs text-[var(--color-ink-muted)]">{t('cad.card.noLinks')}</p>
        {:else}
          <ul class="mt-1 text-xs">
            {#each card.links as link (link.id)}
              <li class="flex gap-2 border-t border-[var(--color-border)] py-0.5">
                <span class="w-16 shrink-0 text-[var(--color-ink-muted)]">
                  {t(`cad.linkKind.${link.targetType}`)}
                </span>
                <span class="flex-1">{link.label}</span>
                <span class="text-[var(--color-ink-muted)]">{t(`cad.linkRole.${link.role}`)}</span>
              </li>
            {/each}
          </ul>
        {/if}
      </section>

      <!-- The narrative (7.16.1). -->
      <section class="border-t border-[var(--color-border)] px-3 py-2">
        <h3 class="text-xs font-semibold">{t('cad.card.narrative')}</h3>

        {#if card.log.length === 0}
          <p class="mt-1 text-xs text-[var(--color-ink-muted)]">{t('cad.note.empty')}</p>
        {:else}
          <ol class="mt-1 text-xs">
            {#each card.log as entry, index (entry.id ?? `pushed-${index}`)}
              <li class="flex gap-2 border-t border-[var(--color-border)] py-1">
                <span class="w-12 shrink-0 font-[family-name:var(--font-mono)] text-[var(--color-ink-muted)]">
                  {clockOf(entry.createdAt)}
                </span>
                <span class="w-28 shrink-0 text-[var(--color-ink-muted)]">
                  {t(`cad.logKind.${entry.entryType}`)}
                </span>
                <span class="flex-1">{logText(entry)}</span>
                <span class="w-16 shrink-0 text-right font-[family-name:var(--font-mono)] text-[var(--color-ink-muted)]">
                  {entry.callsign ?? ''}
                </span>
              </li>
            {/each}
          </ol>
        {/if}

        <form class="mt-2 flex flex-col gap-1 text-xs" onsubmit={addNote}>
          <label class="flex flex-col gap-1">
            <span class="text-[var(--color-ink-muted)]">{t('cad.note.title')}</span>
            <textarea
              rows="2"
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              placeholder={t('cad.note.placeholder')}
              bind:value={note}
            ></textarea>
          </label>
          <button
            type="submit"
            class="self-start border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]"
            disabled={busy}
          >
            {t('cad.note.submit')}
          </button>
        </form>
      </section>

      <!-- Dispatching (7.16). -->
      <section class="border-t border-[var(--color-border)] px-3 py-2">
        <h3 class="text-xs font-semibold">{t('cad.dispatch.title')}</h3>
        <p class="mt-1 text-xs text-[var(--color-ink-muted)]">{t('cad.dispatch.intro')}</p>

        {#if consolePlacement() === null}
          <p class="mt-1 border border-[var(--color-caution)] px-2 py-1 text-xs text-[var(--color-caution)]">
            {t('cad.console.away')}
          </p>
        {/if}

        {#if card.recommended}
          <!-- Sent only to a session that may dispatch, and only for a call
               with coordinates to measure from. Absent means no panel at all;
               empty means the board has nobody to send. -->
          <h4 class="mt-2 text-xs font-semibold">{t('cad.dispatch.recommended')}</h4>

          {#if card.recommended.length === 0}
            <p class="text-xs text-[var(--color-ink-muted)]">{t('cad.dispatch.noRecommendation')}</p>
          {:else}
            <ul class="text-xs">
              {#each card.recommended as unit (unit.officerId)}
                <li class="flex flex-wrap items-baseline gap-2 border-t border-[var(--color-border)] py-0.5">
                  <span class="font-[family-name:var(--font-mono)]">{unit.callsign}</span>
                  <span>{t(`cad.unitStatus.${unit.status}`)}</span>
                  <span>{t('cad.dispatch.distance', { distance: distance.format(unit.distance) })}</span>
                  <span class="text-[var(--color-ink-muted)]">{positionAge(unit.officerId)}</span>
                  <button
                    type="button"
                    class="ml-auto border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-surface)]"
                    onclick={() =>
                      (selectedUnits = toggle(selectedUnits, String(unit.officerId)))}
                  >
                    {t('cad.dispatch.add')}
                  </button>
                </li>
              {/each}
            </ul>
          {/if}
        {/if}

        <form class="mt-2 flex flex-col gap-2 text-xs" onsubmit={dispatch}>
          <fieldset class="border border-[var(--color-border)] px-2 py-1">
            <legend class="px-1 text-[var(--color-ink-muted)]">{t('cad.dispatch.units')}</legend>

            {#if assignable.length === 0}
              <p class="text-[var(--color-ink-muted)]">{t('cad.board.empty')}</p>
            {:else}
              <div class="flex max-h-40 flex-col overflow-y-auto">
                {#each assignable as unit (unit.officerId)}
                  <label class="flex items-baseline gap-2 py-0.5">
                    <input
                      type="checkbox"
                      checked={selectedUnits.includes(String(unit.officerId))}
                      onchange={() =>
                        (selectedUnits = toggle(selectedUnits, String(unit.officerId)))}
                    />
                    <span class="font-[family-name:var(--font-mono)]">{unit.callsign}</span>
                    <span class="text-[var(--color-ink-muted)]">
                      {t(`cad.unitStatus.${unit.status}`)}
                    </span>
                    <span class="ml-auto text-[var(--color-ink-muted)]">
                      {unit.onCallNumber ?? t('cad.board.noAssignment')}
                    </span>
                  </label>
                {/each}
              </div>
            {/if}
          </fieldset>

          {#if activeUnits.length > 0}
            <fieldset class="border border-[var(--color-border)] px-2 py-1">
              <legend class="px-1 text-[var(--color-ink-muted)]">{t('cad.dispatch.remove')}</legend>

              {#each activeUnits as unit (unit.id)}
                <label class="flex items-baseline gap-2 py-0.5">
                  <input
                    type="checkbox"
                    checked={removeUnits.includes(String(unit.officerId))}
                    onchange={() => (removeUnits = toggle(removeUnits, String(unit.officerId)))}
                  />
                  <span class="font-[family-name:var(--font-mono)]">{unit.callsign}</span>
                </label>
              {/each}
            </fieldset>
          {/if}

          <label class="flex items-center gap-2">
            <span class="w-24 shrink-0 text-[var(--color-ink-muted)]">{t('cad.dispatch.lead')}</span>
            <select
              class="min-w-0 flex-1 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={lead}
            >
              <option value="">{t('cad.beat.unassigned')}</option>
              {#each leadChoices as choice (choice.officerId)}
                <option value={String(choice.officerId)}>{choice.callsign}</option>
              {/each}
            </select>
          </label>

          <button
            type="submit"
            class="self-start border border-[var(--color-border)] px-3 py-1 font-semibold hover:bg-[var(--color-surface)]"
            disabled={busy}
          >
            {t('cad.dispatch.submit')}
          </button>
        </form>
      </section>

      <!-- What the unit on the call does with it. -->
      <section class="flex flex-wrap items-start gap-3 border-t border-[var(--color-border)] px-3 py-2">
        <div class="flex flex-col gap-1 text-xs">
          <span class="text-[var(--color-ink-muted)]">{t('cad.status.callProgress')}</span>
          <span class="flex gap-2">
            {#each CALL_PROGRESS_STATUSES as status (status)}
              <button
                type="button"
                class="border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]"
                disabled={busy}
                onclick={() => void progress(status)}
              >
                {t(`cad.unitStatus.${status}`)}
              </button>
            {/each}
          </span>
        </div>

        <div class="flex flex-col gap-1 text-xs">
          <span class="text-[var(--color-ink-muted)]">{t('cad.selfAssign.action')}</span>

          {#if selfAssignArmed}
            <span class="flex items-center gap-2">
              <span>{t('cad.selfAssign.confirm', { number: card.call.callNumber })}</span>
              <button
                type="button"
                class="border border-[var(--color-border)] px-3 py-1 font-semibold hover:bg-[var(--color-surface)]"
                disabled={busy}
                onclick={() => void selfAssign()}
              >
                {t('cad.selfAssign.action')}
              </button>
              <button
                type="button"
                class="border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]"
                onclick={() => (selfAssignArmed = false)}
              >
                {t('form.cancel')}
              </button>
            </span>
          {:else}
            <button
              type="button"
              class="self-start border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]"
              onclick={() => (selfAssignArmed = true)}
            >
              {t('cad.selfAssign.action')}
            </button>
          {/if}
        </div>

        {#if card.call.source === 'panic' && !card.call.acknowledgedAt}
          <!-- 7.16: an emergency call cannot be cleared until a supervisor has
               acknowledged it, and the officer who raised it may not sign off
               their own. Both refusals come from the server. -->
          <div class="flex flex-col gap-1 text-xs">
            <span class="text-[var(--color-ink-muted)]">{t('cad.emergency.title')}</span>
            <button
              type="button"
              class="self-start border border-[var(--color-alert)] px-3 py-1 font-semibold text-[var(--color-alert)] hover:bg-[var(--color-surface)]"
              disabled={busy}
              onclick={() => void acknowledge()}
            >
              {t('cad.emergency.acknowledge')}
            </button>
          </div>
        {/if}
      </section>

      <!-- Clearing (7.16). -->
      <section class="border-t border-[var(--color-border)] px-3 py-2">
        <h3 class="text-xs font-semibold">{t('cad.clear.title')}</h3>
        <p class="mt-1 text-xs text-[var(--color-ink-muted)]">{t('cad.clear.intro')}</p>

        {#if card.call.source === 'panic' && !card.call.acknowledgedAt}
          <p class="mt-1 border border-[var(--color-caution)] px-2 py-1 text-xs text-[var(--color-caution)]">
            {t('cad.clear.needsAcknowledgement')}
          </p>
        {/if}

        <form class="mt-2 flex flex-col gap-2 text-xs" onsubmit={clear}>
          <label class="flex items-center gap-2">
            <span class="w-24 shrink-0 text-[var(--color-ink-muted)]">
              {t('cad.clear.disposition')}
            </span>
            <select
              class="min-w-0 flex-1 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={disposition}
            >
              {#each CALL_DISPOSITIONS as code (code)}
                <option value={code}>{t(`cad.disposition.${code}`)}</option>
              {/each}
            </select>
          </label>

          <label class="flex flex-col gap-1">
            <span class="text-[var(--color-ink-muted)]">{t('cad.clear.note')}</span>
            <textarea
              rows="2"
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={closingNote}
            ></textarea>
          </label>

          <button
            type="submit"
            class="self-start border border-[var(--color-border)] px-3 py-1 font-semibold hover:bg-[var(--color-surface)]"
            disabled={busy}
          >
            {t('cad.clear.submit')}
          </button>
        </form>
      </section>

      <!-- Every refusal on this card, in one place: the code, and the field the
           server named with the reason it gave (spec 3.5). -->
      {#if failure}
        <div class="border-t border-[var(--color-alert)] px-3 py-2 text-xs">
          <p class="font-semibold">{t(`error.${failure.err}`)}</p>
          {#each messages as message (message.name)}
            <p class="text-[var(--color-alert)]">{message.label} — {message.reason}</p>
          {/each}
        </div>
      {/if}
    </div>
  {/if}
</div>
