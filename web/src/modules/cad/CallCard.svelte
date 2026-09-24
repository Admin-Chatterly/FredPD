<script lang="ts">
  import { nui } from '../../lib/nui';
  import { getLocale, t } from '../../lib/i18n';
  import type { CallLinkKind, ErrorCode } from '@fredpd/schema';
  import {
    CALL_DISPOSITIONS,
    CALL_LINK_KINDS,
    CALL_LINK_ROLES,
    CALL_PROGRESS_STATUSES,
  } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import { isStub, type Maybe, type PersonResult, type VehicleResult } from '../records/types';
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
    type CallLink,
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
   * Two things are drawn conditionally, and in both cases the server is what
   * decided:
   *
   *   * the **recommendation**. `call.get` returns `recommended` only for a
   *     session that may dispatch, and only for a call that has coordinates to
   *     measure from. Absent is not the same as empty — no panel, against a
   *     panel that says there is nobody to recommend — and a card that assumed
   *     the list was always there would draw an empty picker at every officer
   *     in the department.
   *   * the **acknowledgement**, on `mayAcknowledge`. That one is here because
   *     a refusal the card cannot read out is not a refusal an officer can act
   *     on: `call.acknowledge` is gated on `cad.unit.manage`, and the
   *     permission check runs before any handler, so it answers a bare
   *     `forbidden` with no `fields` — nothing for the panel at the bottom of
   *     this card to name — and leaves an `audit.denied` row behind every
   *     press. Everything else listed above refuses with a code, which is the
   *     line between an action that explains itself and a dead end.
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

  let failure = $state<Failure | null>(null);
  let busy = $state(false);

  /**
   * The links panel (7.16: "linked persons and vehicles").
   *
   * `call.link` takes a register row id and nothing else — a plate or a name is
   * deliberately not accepted, because creating records from a call card would
   * be a second way into the master name index with none of 7.3's checks. So
   * the only way to produce one is to search the register, which is what this
   * does: `person.search` or `vehicle.search`, the same routes Records calls,
   * with the same access control and the same query log behind them (7.2).
   *
   * Two consequences that are the server's answer and are drawn, not
   * anticipated (invariant 4):
   *
   *   * the search is gated on `rms.person.view` / `rms.vehicle.view`, which
   *     `cad.call.link` does not imply — a session holding one and not the
   *     other is refused by the search and told so;
   *   * a record the reader may be told about but not read comes back as a
   *     stub with no id (`isStub`), and there is nothing to link a call to. It
   *     is listed as restricted rather than dropped, because "it exists and is
   *     not yours to attach" is the honest answer.
   */
  interface Candidate {
    id: number;
    /**
     * The register this row came out of.
     *
     * Carried on the row rather than read off the select when the button is
     * pressed: the select is live, and a dispatcher who searched for a person
     * and then flipped the select to vehicles would otherwise send a person id
     * as a vehicle — `not_found` if the department is lucky and the wrong
     * record if it is not.
     */
    kind: CallLinkKind;
    label: string;
  }

  /** The first kind on the list, which is `person`. */
  const FIRST_KIND = CALL_LINK_KINDS[0];

  /** The column default, and the honest role for a part not yet known. */
  const DEFAULT_ROLE = 'involved';

  let linkKind = $state<CallLinkKind>(FIRST_KIND);
  let linkTerm = $state('');
  let candidates = $state<Candidate[]>([]);
  let restrictedCandidates = $state(0);
  /** False until a search has run, so "nothing matched" is not shown before one. */
  let searched = $state(false);
  /** Candidate id -> the role it would be linked under. */
  let candidateRoles = $state<Record<number, string>>({});

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
    failure = null;
    clearSearch();
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
  }

  async function acknowledge(): Promise<void> {
    if (!card) return;

    await send('call.acknowledge', { callId: card.id });
  }

  // ------------------------------------------------- persons and vehicles

  function clearSearch(): void {
    linkKind = FIRST_KIND;
    linkTerm = '';
    candidates = [];
    restrictedCandidates = 0;
    candidateRoles = {};
    searched = false;
  }

  /**
   * How a candidate is written in the picker.
   *
   * The same two columns the server records on the link itself
   * (`Repo.linkTarget`): a person is their name and a vehicle is its plate, so
   * what the dispatcher clicked is what appears in the list above afterwards.
   * The record number and the model ride along because a department has more
   * than one John Doe and more than one black sedan.
   */
  function personLabel(person: PersonResult): string {
    const name = [person.firstName, person.lastName].filter(Boolean).join(' ').trim();

    return name ? `${name} · ${person.personNumber}` : person.personNumber;
  }

  function vehicleLabel(vehicle: VehicleResult): string {
    return vehicle.model ? `${vehicle.plate} · ${vehicle.model}` : vehicle.plate;
  }

  /**
   * Searches the register named by `linkKind`.
   *
   * The term goes over untouched: `person.search` does its own parsing and
   * refuses a term that is too short with a field code this card reads out,
   * which is a better answer than a button that does nothing.
   */
  async function searchTargets(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    busy = true;
    candidates = [];
    candidateRoles = {};
    restrictedCandidates = 0;

    const found: Candidate[] = [];
    let restricted = 0;

    if (linkKind === 'person') {
      const response = await nui.call<{ persons: Maybe<PersonResult>[] }>('person.search', {
        term: linkTerm,
      });

      if (response.ok) {
        for (const row of response.data.persons) {
          if (isStub(row)) restricted += 1;
          else found.push({ id: row.id, kind: 'person', label: personLabel(row) });
        }

        failure = null;
      } else {
        failure = response;
      }
    } else {
      const response = await nui.call<{ vehicles: Maybe<VehicleResult>[] }>('vehicle.search', {
        term: linkTerm,
      });

      if (response.ok) {
        for (const row of response.data.vehicles) {
          if (isStub(row)) restricted += 1;
          else found.push({ id: row.id, kind: 'vehicle', label: vehicleLabel(row) });
        }

        failure = null;
      } else {
        failure = response;
      }
    }

    candidates = found;
    restrictedCandidates = restricted;
    searched = true;
    busy = false;
  }

  /** Links one candidate to the open call, under the role chosen beside it. */
  async function linkTarget(candidate: Candidate): Promise<void> {
    if (!card) return;

    await send('call.link', {
      callId: card.id,
      kind: candidate.kind,
      targetId: candidate.id,
      role: candidateRoles[candidate.id] ?? DEFAULT_ROLE,
    });

    if (!failure) {
      candidates = candidates.filter((row) => row.id !== candidate.id);
    }
  }

  /**
   * Changes the role of a link that is already there.
   *
   * The same route: `Repo.setLink` upserts on `uq_fpd_call_links_target`, so
   * this changes the role rather than stacking a second row, and the narrative
   * gets a `linked` line saying who decided the witness was a suspect (7.16.1).
   */
  async function setLinkRole(link: CallLink, role: string): Promise<void> {
    if (!card || role === link.role) return;

    await send('call.link', {
      callId: card.id,
      kind: link.targetType,
      targetId: link.targetId,
      role,
    });
  }

  async function unlink(link: CallLink): Promise<void> {
    if (!card) return;

    await send('call.link', {
      callId: card.id,
      kind: link.targetType,
      targetId: link.targetId,
      remove: true,
    });
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

      <!--
        Persons and vehicles (7.16).

        Every select below takes its accessible name from the record it acts on,
        which is why each one is wrapped in a label carrying that record's own
        text: a role is only ever read as "this person's part in this call", and
        a bare "Role" over a column of them would be less use, not more.
      -->
      <section class="border-t border-[var(--color-border)] px-3 py-2">
        <h3 class="text-xs font-semibold">{t('cad.card.links')}</h3>

        {#if card.links.length === 0}
          <p class="mt-1 text-xs text-[var(--color-ink-muted)]">{t('cad.card.noLinks')}</p>
        {:else}
          <ul class="mt-1 text-xs">
            {#each card.links as link (link.id)}
              <li class="flex flex-wrap items-baseline gap-2 border-t border-[var(--color-border)] py-0.5">
                <span class="w-16 shrink-0 text-[var(--color-ink-muted)]">
                  {t(`cad.linkKind.${link.targetType}`)}
                </span>
                <label class="flex min-w-0 flex-1 items-baseline gap-2">
                  <span class="min-w-0 flex-1">{link.label}</span>
                  <select
                    class="border border-[var(--color-border)] bg-[var(--color-panel)] px-1 py-0.5"
                    value={link.role}
                    disabled={busy}
                    onchange={(event) => void setLinkRole(link, event.currentTarget.value)}
                  >
                    {#each CALL_LINK_ROLES as role (role)}
                      <option value={role}>{t(`cad.linkRole.${role}`)}</option>
                    {/each}
                  </select>
                </label>
                <button
                  type="button"
                  class="border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-surface)]"
                  disabled={busy}
                  onclick={() => void unlink(link)}
                >
                  {t('cad.link.remove')}
                </button>
              </li>
            {/each}
          </ul>
        {/if}

        <!-- The picker. A link is to a record, so the id comes from the
             register and never from a name typed on this form.

             `cad.link.add` and `cad.link.remove` are this section's own keys
             rather than the two that were borrowed first. The link button read
             `cad.selfAssign.action` -- "Attach to call" -- which is the label
             on the button further down that attaches *your unit*, so the card
             carried two differently-behaved buttons under one name: ambiguous
             to a screen reader, ambiguous to a role-based test, and a dispatcher
             who meant one and pressed the other joined a call they were only
             filing a name against. The unlink button read
             `admin.roleMap.remove`, which is a working label borrowed from a
             screen this module has nothing to do with: rewording the Discord
             role table would have silently reworded a call card. -->

        <form class="mt-2 flex flex-wrap items-end gap-2 text-xs" onsubmit={searchTargets}>
          <label class="flex flex-col gap-1">
            <span class="text-[var(--color-ink-muted)]">{t('cad.column.type')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={linkKind}
            >
              {#each CALL_LINK_KINDS as kind (kind)}
                <option value={kind}>{t(`cad.linkKind.${kind}`)}</option>
              {/each}
            </select>
          </label>

          <label class="flex min-w-40 flex-1 flex-col gap-1">
            <span class="text-[var(--color-ink-muted)]">{t('records.search.term')}</span>
            <input
              type="text"
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              placeholder={linkKind === 'person'
                ? t('records.person.search.termPlaceholder')
                : t('records.vehicle.search.termPlaceholder')}
              bind:value={linkTerm}
            />
          </label>

          <button
            type="submit"
            class="border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]"
            disabled={busy}
          >
            {t('records.search.run')}
          </button>
        </form>

        {#if searched}
          {#if candidates.length === 0 && restrictedCandidates === 0}
            <!-- Nothing matched at all. A search that matched only records this
                 reader may not open is a different answer and is given by the
                 withheld line below instead: "No person matches" over a term
                 that plainly did match one would have the dispatcher retyping a
                 name the register knows perfectly well. -->
            <p class="mt-1 text-xs text-[var(--color-ink-muted)]">
              {t(`records.${linkKind}.empty`)}
            </p>
          {:else}
            <ul class="mt-1 max-h-40 overflow-y-auto text-xs">
              {#each candidates as candidate (candidate.id)}
                <li class="flex flex-wrap items-baseline gap-2 border-t border-[var(--color-border)] py-0.5">
                  <label class="flex min-w-0 flex-1 items-baseline gap-2">
                    <span class="min-w-0 flex-1">{candidate.label}</span>
                    <select
                      class="border border-[var(--color-border)] bg-[var(--color-panel)] px-1 py-0.5"
                      value={candidateRoles[candidate.id] ?? DEFAULT_ROLE}
                      onchange={(event) =>
                        (candidateRoles = {
                          ...candidateRoles,
                          [candidate.id]: event.currentTarget.value,
                        })}
                    >
                      {#each CALL_LINK_ROLES as role (role)}
                        <option value={role}>{t(`cad.linkRole.${role}`)}</option>
                      {/each}
                    </select>
                  </label>
                  <button
                    type="button"
                    class="border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-surface)]"
                    disabled={busy}
                    onclick={() => void linkTarget(candidate)}
                  >
                    {t('cad.link.add')}
                  </button>
                </li>
              {/each}
            </ul>
          {/if}

          {#if restrictedCandidates > 0}
            <!-- Records this reader may be told about and not read (4.5). They
                 have no id, so there is nothing to link; saying how many beats
                 a shorter list the dispatcher cannot account for.

                 The count and not a row each, unlike the register's own result
                 list: there the stub is an entry you act on by ringing the unit
                 named on it, and here it is the reason a name the dispatcher
                 can see in front of them is missing from the picker. One line
                 answers that; five rows of "Restricted record" would bury the
                 candidates that can actually be linked. -->
            <p class="mt-1 text-xs text-[var(--color-ink-muted)]">
              {t('cad.link.withheld', { count: restrictedCandidates })}
            </p>
          {/if}
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

      <!-- Dispatching (7.16). Folded away for an officer on the MDT in the
           field, who sends nobody and whose job on this card is the status
           buttons and "Attach to call" above; open at the console. -->
      <details class="border-t border-[var(--color-border)] px-3 py-2" open={consolePlacement() !== null}>
        <summary class="cursor-pointer"><h3 class="inline text-xs font-semibold">{t('cad.dispatch.title')}</h3></summary>
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
      </details>

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

          <!-- One press: taking a call is going to it, so the server attaches
               the unit and sets it en route together. The confirm step this
               had cost a second click on every call a patrol officer took. -->
          <button
            type="button"
            class="self-start border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]"
            disabled={busy}
            onclick={() => void selfAssign()}
          >
            {t('cad.selfAssign.action')}
          </button>
        </div>

        {#if card.call.source === 'panic' && !card.call.acknowledgedAt && card.mayAcknowledge === true}
          <!-- 7.16: an emergency call cannot be cleared until a supervisor has
               acknowledged it, and the officer who raised it may not sign off
               their own.

               Both of those are still the server's answer — this draws it
               rather than deciding it. `mayAcknowledge` is computed by
               `call.get` from the two tests `call.acknowledge` itself makes,
               and `=== true` is what makes a missing field draw less rather
               than more: invariant 4 says the UI is never the access control,
               so the failure worth defaulting away from is this card offering
               something the server did not authorise. A server that has not
               learned to send the field yet costs a supervisor one press on
               the banner instead, which is the cheap half of being wrong.

               It is read here as well as on the banner because the banner's own
               Respond button lands on this card, and `page.dispatch` — which
               every officer on the console holds — is all it takes to open one.
               A gate on the banner alone left the identical button one
               component away for the same session that had just been correctly
               refused it. -->
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
