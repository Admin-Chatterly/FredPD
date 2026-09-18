<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { SELF_SET_UNIT_STATUSES, SUPERVISOR_UNIT_STATUSES, UNIT_STATUSES } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import {
    beatLabel,
    beatName,
    elapsed,
    FIELD_LABELS,
    priorityInk,
    priorityShort,
    type Beat,
    type Unit,
  } from './Dispatch.svelte';

  /**
   * The unit board (spec 7.16): every unit, its status, what it is on, and the
   * time it has been in that status.
   *
   * **Time in status is the number a dispatcher actually watches**, so it ticks
   * from the console's own clock against `status_since` rather than waiting for
   * a reload. The server stamps that column in one place — the status write —
   * which is why the figure can be trusted to mean what it says.
   *
   * The board is who is working: a unit that has signed off keeps its row on the
   * server so it comes back on the same call after a reconnect, and is not on
   * the board until it does. That is the server's filter, not this screen's.
   *
   * Three writes live here beside the table, because they are what a board is
   * read in order to do: an officer moving their own status, an officer raising
   * the emergency, and a supervisor moving somebody else's. All three are drawn
   * for everybody and refused by the server — `no_unit` for a session that never
   * signed on, `off_duty` for one that has signed off, `forbidden` for an
   * officer trying to manage a colleague (invariant 4).
   */

  interface Props {
    units: Unit[];
    beats: Beat[];
    now: number;
    onchanged: () => void;
  }

  const { units, beats, now, onchanged }: Props = $props();

  let statusFilter = $state('');
  let beatFilter = $state('');

  let selectedOfficerId = $state<number | null>(null);

  const FIRST_SELF_STATUS = SELF_SET_UNIT_STATUSES[0];

  let ownStatus = $state<string>(FIRST_SELF_STATUS);
  let emergencyArmed = $state(false);

  let manage = $state({ status: '', callsign: '', beatId: '', reason: '' });

  let failure = $state<Failure | null>(null);
  let notice = $state<string | null>(null);
  let busy = $state(false);

  const shown = $derived(
    units
      .filter((unit) => (statusFilter ? unit.status === statusFilter : true))
      .filter((unit) => (beatFilter ? String(unit.beatId ?? '') === beatFilter : true))
      .sort(
        (left, right) =>
          left.status.localeCompare(right.status) || left.statusSinceUnix - right.statusSinceUnix,
      ),
  );

  const selected = $derived(
    units.find((unit) => unit.officerId === selectedOfficerId) ?? null,
  );

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  async function send(route: string, payload: Record<string, unknown>): Promise<boolean> {
    busy = true;

    const response = await nui.call(route, payload);

    if (response.ok) {
      failure = null;
    } else {
      failure = response;
      notice = null;
    }

    busy = false;

    if (response.ok) onchanged();

    return response.ok;
  }

  async function setOwnStatus(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    if (await send('unit.status', { status: ownStatus })) {
      notice = t('cad.status.changed', { status: t(`cad.unitStatus.${ownStatus}`) });
    }
  }

  /**
   * The emergency (7.16).
   *
   * It sends nothing at all: the position comes off the ped on the server, the
   * priority and the type are fixed there, and the officer is the session. A
   * confirmation step because it turns out every unit in range, and 6.4 asks
   * for one before an action of that weight.
   */
  async function raiseEmergency(): Promise<void> {
    emergencyArmed = false;

    if (await send('unit.emergency', {})) notice = t('cad.emergency.sent');
  }

  async function saveUnit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!selected) return;

    await send('unit.manage', {
      officerId: selected.officerId,
      status: manage.status || undefined,
      callsign: manage.callsign || undefined,
      beatId: manage.beatId ? Number(manage.beatId) : undefined,
      reason: manage.reason || undefined,
    });
  }

  /** Fills the manage form from the row that was picked, and nothing more. */
  function select(unit: Unit): void {
    selectedOfficerId = unit.officerId;
    manage = {
      status: '',
      callsign: unit.callsign,
      beatId: unit.beatId === null ? '' : String(unit.beatId),
      reason: '',
    };
  }
</script>

<section class="flex min-h-0 flex-col gap-3">
  <header class="flex flex-wrap items-baseline gap-3">
    <h2 class="text-sm font-semibold">{t('cad.board.title')}</h2>

    <label class="flex items-center gap-2 text-xs">
      <span class="text-[var(--color-ink-muted)]">{t('cad.filter.status')}</span>
      <select
        class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
        bind:value={statusFilter}
      >
        <option value="">{t('cad.filter.any')}</option>
        {#each UNIT_STATUSES as status (status)}
          <option value={status}>{t(`cad.unitStatus.${status}`)}</option>
        {/each}
      </select>
    </label>

    <label class="flex items-center gap-2 text-xs">
      <span class="text-[var(--color-ink-muted)]">{t('cad.filter.beat')}</span>
      <select
        class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
        bind:value={beatFilter}
      >
        <option value="">{t('cad.filter.any')}</option>
        {#each beats as beat (beat.id)}
          <option value={String(beat.id)}>{beatName(beat)}</option>
        {/each}
      </select>
    </label>
  </header>

  {#if shown.length === 0}
    <p class="border border-[var(--color-border)] px-3 py-2 text-xs text-[var(--color-ink-muted)]">
      {t('cad.board.empty')}
    </p>
  {:else}
    <div class="overflow-x-auto border border-[var(--color-border)]">
      <table class="w-full border-collapse text-xs">
        <thead>
          <tr class="border-b border-[var(--color-border)] text-left">
            <th scope="col" class="px-3 py-1.5 font-semibold">{t('cad.column.callsign')}</th>
            <th scope="col" class="px-3 py-1.5 font-semibold">{t('cad.column.unitStatus')}</th>
            <th scope="col" class="px-3 py-1.5 font-semibold">{t('cad.column.timeInStatus')}</th>
            <th scope="col" class="px-3 py-1.5 font-semibold">{t('cad.column.assignment')}</th>
            <th scope="col" class="px-3 py-1.5 font-semibold">{t('cad.column.beat')}</th>
            <th scope="col" class="px-3 py-1.5 font-semibold">{t('cad.column.vehicle')}</th>
          </tr>
        </thead>
        <tbody>
          {#each shown as unit (unit.officerId)}
            <tr
              class="border-b border-[var(--color-border)] hover:bg-[var(--color-surface)]"
              class:bg-[var(--color-surface)]={unit.officerId === selectedOfficerId}
            >
              <td class="px-3 py-1">
                <button
                  type="button"
                  class="font-[family-name:var(--font-mono)] underline-offset-2 hover:underline"
                  onclick={() => select(unit)}
                >
                  {unit.callsign}
                </button>
              </td>
              <td
                class="px-3 py-1"
                class:font-semibold={unit.status === 'emergency'}
                class:text-[var(--color-alert)]={unit.status === 'emergency'}
              >
                {t(`cad.unitStatus.${unit.status}`)}
              </td>
              <td class="px-3 py-1 font-[family-name:var(--font-mono)]">
                {t('cad.board.inStatus', { duration: elapsed(unit.statusSinceUnix, now) })}
              </td>
              <td class="px-3 py-1">
                {#if unit.onCallNumber}
                  <span class="font-[family-name:var(--font-mono)]">{unit.onCallNumber}</span>
                  {#if unit.onCallPriority}
                    <span class="{priorityInk(unit.onCallPriority)} font-semibold">
                      {priorityShort(unit.onCallPriority)}
                    </span>
                  {/if}
                  {#if unit.onCallLead === 1}
                    <span class="text-[var(--color-ink-muted)]">{t('cad.column.lead')}</span>
                  {/if}
                {:else}
                  <span class="text-[var(--color-ink-muted)]">{t('cad.board.noAssignment')}</span>
                {/if}
              </td>
              <td class="px-3 py-1">{beatLabel(beats, unit.beatId)}</td>
              <!-- Where the unit is belongs to the map, which has a sentence
                   for how old a position is; the board is what they are doing. -->
              <td class="px-3 py-1 font-[family-name:var(--font-mono)]">
                {unit.vehiclePlate ?? ''}
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}

  {#if notice}
    <p class="border border-[var(--color-clear)] px-3 py-1.5 text-xs text-[var(--color-clear)]">
      {notice}
    </p>
  {/if}

  {#if failure}
    <div class="border border-[var(--color-alert)] px-3 py-1.5 text-xs">
      <p class="font-semibold">{t(`error.${failure.err}`)}</p>
      {#each messages as message (message.name)}
        <p class="text-[var(--color-alert)]">{message.label} — {message.reason}</p>
      {/each}
    </div>
  {/if}

  <div class="flex flex-wrap items-start gap-4">
    <!-- The officer's own status and the button (7.1's F-keys, 7.16). -->
    <form class="flex flex-col gap-2 border border-[var(--color-border)] p-3 text-xs" onsubmit={setOwnStatus}>
      <h3 class="font-semibold">{t('cad.status.title')}</h3>

      <select
        class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
        bind:value={ownStatus}
      >
        {#each SELF_SET_UNIT_STATUSES as status (status)}
          <option value={status}>{t(`cad.unitStatus.${status}`)}</option>
        {/each}
      </select>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]"
        disabled={busy}
      >
        {t('cad.status.submit')}
      </button>

      {#if emergencyArmed}
        <p class="text-[var(--color-alert)]">{t('cad.emergency.confirm')}</p>
        <span class="flex gap-2">
          <button
            type="button"
            class="border border-[var(--color-alert)] px-3 py-1 font-semibold text-[var(--color-alert)] hover:bg-[var(--color-surface)]"
            disabled={busy}
            onclick={() => void raiseEmergency()}
          >
            {t('cad.emergency.button')}
          </button>
          <button
            type="button"
            class="border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]"
            onclick={() => (emergencyArmed = false)}
          >
            {t('form.cancel')}
          </button>
        </span>
      {:else}
        <button
          type="button"
          class="border-2 border-[var(--color-alert)] px-3 py-1 font-semibold text-[var(--color-alert)] hover:bg-[var(--color-surface)]"
          onclick={() => (emergencyArmed = true)}
        >
          {t('cad.emergency.button')}
        </button>
      {/if}
    </form>

    <!-- A supervisor or dispatcher moving somebody else (7.16). -->
    <form class="flex min-w-72 flex-col gap-2 border border-[var(--color-border)] p-3 text-xs" onsubmit={saveUnit}>
      <h3 class="font-semibold">{t('cad.manage.title')}</h3>
      <p class="max-w-prose text-[var(--color-ink-muted)]">{t('cad.manage.intro')}</p>

      <p>
        <span class="text-[var(--color-ink-muted)]">{t('cad.manage.unit')}</span>
        <span class="ml-2 font-[family-name:var(--font-mono)]">{selected?.callsign ?? ''}</span>
      </p>

      <label class="flex flex-col gap-1">
        <span class="text-[var(--color-ink-muted)]">{t('cad.manage.status')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={manage.status}
        >
          <option value="">{t('cad.filter.any')}</option>
          {#each SUPERVISOR_UNIT_STATUSES as status (status)}
            <option value={status}>{t(`cad.unitStatus.${status}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1">
        <span class="text-[var(--color-ink-muted)]">{t('cad.manage.callsign')}</span>
        <input
          type="text"
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={manage.callsign}
        />
      </label>

      <label class="flex flex-col gap-1">
        <span class="text-[var(--color-ink-muted)]">{t('cad.manage.beat')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={manage.beatId}
        >
          <option value="">{t('cad.beat.none')}</option>
          {#each beats as beat (beat.id)}
            <option value={String(beat.id)}>{beatName(beat)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1">
        <!-- Required by the server for the two changes that read as discipline
             afterwards — out of service, and signing somebody off — and asked
             for here every time, because the audit row is what has to explain
             it months later. -->
        <span class="text-[var(--color-ink-muted)]">{t('cad.manage.reason')}</span>
        <input
          type="text"
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={manage.reason}
        />
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1 font-semibold hover:bg-[var(--color-surface)]"
        disabled={busy}
      >
        {t('cad.manage.submit')}
      </button>
    </form>
  </div>
</section>
