<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { CALL_PRIORITIES, CALL_STATUSES, CALL_TYPES } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import {
    beatLabel,
    beatName,
    consolePlacement,
    elapsed,
    FIELD_LABELS,
    priorityInk,
    priorityRule,
    priorityShort,
    type Beat,
    type Call,
  } from './Dispatch.svelte';

  /**
   * The pending queue and the intake form (spec 7.16).
   *
   * **Stacked by priority then age.** That is the order the server reads the
   * queue in — `idx_fpd_calls_queue` is `(agency_id, queue_priority,
   * received_at)` — and it is applied again here because the list also holds
   * calls that arrived through a push, which land at the end of the array in
   * the order they happened rather than in the order they should be worked.
   *
   * **P1 is unmissable, and not by colour alone** (6.7). Every row carries the
   * priority in words, a left rule that differs in weight and in style between
   * all four, and for a P1 a heavier border and the alert ink on top of that.
   *
   * The filters that narrow the *read* — status, priority, beat, and "my
   * calls" — are sent to the server, because the queue's default is the open
   * calls only and reviewing a cleared one is a different index read. The
   * search box narrows what is already loaded and says nothing to the server:
   * `CallList` has no search field, and a box that quietly did nothing would be
   * worse than one that filters the page in front of you.
   */

  interface Props {
    calls: Call[];
    beats: Beat[];
    now: number;
    queueCount: number;
    selectedId: number | null;
    onselect: (id: number) => void;
    onfilter: (filter: { status: string; priority: string; beatId: string; mine: boolean }) => void;
    oncreated: (id: number) => void;
  }

  const { calls, beats, now, queueCount, selectedId, onselect, onfilter, oncreated }: Props =
    $props();

  /**
   * What the filter bar is set to, which is not what the queue was last read
   * with: the four server-side filters are applied when Apply is pressed, so a
   * dispatcher can set up a narrower question without the list moving under
   * them while they do it.
   */
  let draft = $state({ status: '', priority: '', beatId: '', mine: false });
  let search = $state('');

  let intakeOpen = $state(false);
  let busy = $state(false);
  let failure = $state<Failure | null>(null);

  /**
   * The intake form (7.16).
   *
   * No position, and none is missing: a call taken over the phone happens where
   * the *caller* says it does, which is the location text, and the dispatcher
   * who knows the district picks the beat. The call number, the time and the
   * received stamp are the server's (invariant 1).
   */
  let intake = $state({
    type: 'other',
    priority: '3',
    locationText: '',
    beatId: '',
    callerName: '',
    callerPhone: '',
    details: '',
  });

  /**
   * The types a dispatcher may raise by hand.
   *
   * `officer_emergency` is left off: it is what the emergency button raises,
   * and a hand-raised officer-down call would ring the tone for a unit that
   * never pressed anything. Leaving it out of the picker is a convenience and
   * not a control — the server is what refuses it (invariant 4).
   */
  const INTAKE_TYPES = CALL_TYPES.filter((type) => type !== 'officer_emergency');

  /** Priority first, then oldest first: the order the queue is worked in. */
  const ordered = $derived(
    [...calls]
      .filter((call) => {
        const needle = search.trim().toLowerCase();
        if (!needle) return true;

        return (
          call.callNumber.toLowerCase().includes(needle) ||
          (call.locationText ?? '').toLowerCase().includes(needle) ||
          (call.callerName ?? '').toLowerCase().includes(needle)
        );
      })
      .sort(
        (left, right) =>
          left.priority - right.priority || left.receivedAtUnix - right.receivedAtUnix,
      ),
  );

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  async function create(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    busy = true;

    const response = await nui.call<{ id: number }>('call.create', {
      // The console the dispatcher is standing at. Null when the MDT was opened
      // on the keybind, which the server refuses on `context` — the note above
      // the form says so rather than leaving the refusal unexplained.
      placementId: consolePlacement() ?? undefined,
      type: intake.type,
      priority: Number(intake.priority),
      locationText: intake.locationText,
      beatId: intake.beatId ? Number(intake.beatId) : undefined,
      callerName: intake.callerName || undefined,
      callerPhone: intake.callerPhone || undefined,
      details: intake.details || undefined,
    });

    if (response.ok) {
      failure = null;
      intakeOpen = false;
      intake = {
        type: 'other',
        priority: '3',
        locationText: '',
        beatId: '',
        callerName: '',
        callerPhone: '',
        details: '',
      };
      oncreated(response.data.id);
    } else {
      failure = response;
    }

    busy = false;
  }
</script>

<div class="flex min-h-0 flex-col border border-[var(--color-border)]">
  <header
    class="flex items-baseline justify-between border-b border-[var(--color-border)] px-3 py-2"
  >
    <h2 class="text-sm font-semibold">{t('cad.queue.title')}</h2>
    <span class="text-xs text-[var(--color-ink-muted)]">
      {t('cad.queue.stacked', { count: queueCount })}
    </span>
  </header>

  <!-- Filters. Four go to the server; the search box narrows this page. -->
  <div class="flex flex-col gap-2 border-b border-[var(--color-border)] px-3 py-2 text-xs">
    <label class="flex items-center gap-2">
      <span class="w-20 shrink-0 text-[var(--color-ink-muted)]">{t('cad.filter.search')}</span>
      <input
        type="search"
        class="min-w-0 flex-1 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
        placeholder={t('cad.filter.searchPlaceholder')}
        bind:value={search}
      />
    </label>

    <label class="flex items-center gap-2">
      <span class="w-20 shrink-0 text-[var(--color-ink-muted)]">{t('cad.filter.status')}</span>
      <select
        class="min-w-0 flex-1 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
        bind:value={draft.status}
      >
        <option value="">{t('cad.filter.any')}</option>
        {#each CALL_STATUSES as status (status)}
          <option value={status}>{t(`cad.callStatus.${status}`)}</option>
        {/each}
      </select>
    </label>

    <label class="flex items-center gap-2">
      <span class="w-20 shrink-0 text-[var(--color-ink-muted)]">{t('cad.filter.priority')}</span>
      <select
        class="min-w-0 flex-1 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
        bind:value={draft.priority}
      >
        <option value="">{t('cad.filter.any')}</option>
        {#each CALL_PRIORITIES as priority (priority)}
          <option value={String(priority)}>{priorityShort(priority)}</option>
        {/each}
      </select>
    </label>

    <label class="flex items-center gap-2">
      <span class="w-20 shrink-0 text-[var(--color-ink-muted)]">{t('cad.filter.beat')}</span>
      <select
        class="min-w-0 flex-1 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
        bind:value={draft.beatId}
      >
        <option value="">{t('cad.filter.any')}</option>
        {#each beats as beat (beat.id)}
          <option value={String(beat.id)}>{beatName(beat)}</option>
        {/each}
      </select>
    </label>

    <div class="flex items-center justify-between gap-2">
      <label class="flex items-center gap-2">
        <input type="checkbox" bind:checked={draft.mine} />
        <span>{t('cad.filter.mine')}</span>
      </label>

      <button
        type="button"
        class="border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]"
        onclick={() => onfilter({ ...draft })}
      >
        {t('cad.filter.apply')}
      </button>
    </div>
  </div>

  <!-- The queue itself. -->
  <ul class="min-h-0 flex-1 overflow-y-auto">
    {#each ordered as call (call.id)}
      <li>
        <button
          type="button"
          class="block w-full border-b border-[var(--color-border)] px-3 py-2 text-left hover:bg-[var(--color-surface)] {priorityRule(
            call.priority,
          )}"
          class:bg-[var(--color-surface)]={call.id === selectedId}
          onclick={() => onselect(call.id)}
        >
          <span class="flex items-baseline gap-2">
            <span
              class="text-xs font-semibold {priorityInk(call.priority)}"
              title={t(`cad.priority.p${call.priority}`)}
            >
              {priorityShort(call.priority)}
            </span>
            <span class="font-[family-name:var(--font-mono)] text-xs">{call.callNumber}</span>
            <span class="ml-auto text-xs text-[var(--color-ink-muted)]">
              {t('cad.queue.waiting', { duration: elapsed(call.receivedAtUnix, now) })}
            </span>
          </span>

          <span class="mt-0.5 block text-xs font-semibold">
            {t(`cad.callType.${call.type}`)}
          </span>

          <span class="mt-0.5 flex flex-wrap items-baseline gap-x-2 text-xs text-[var(--color-ink-muted)]">
            <span>{call.locationText ?? beatLabel(beats, call.beatId)}</span>
            <span>·</span>
            <span>{t(`cad.callStatus.${call.status}`)}</span>
            <span>·</span>
            {#if call.unitCount}
              <span>{t('cad.column.units')} {call.unitCount}</span>
            {:else}
              <span>{t('cad.queue.unassigned')}</span>
            {/if}
          </span>
        </button>
      </li>
    {:else}
      <li class="px-3 py-3 text-xs text-[var(--color-ink-muted)]">{t('cad.queue.empty')}</li>
    {/each}
  </ul>

  <!-- Intake (7.16). -->
  <div class="border-t border-[var(--color-border)] px-3 py-2">
    <button
      type="button"
      class="w-full border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
      onclick={() => (intakeOpen = !intakeOpen)}
    >
      {t('cad.create.title')}
    </button>

    {#if intakeOpen}
      <form class="mt-2 flex flex-col gap-2 text-xs" onsubmit={create}>
        <p class="text-[var(--color-ink-muted)]">{t('cad.create.intro')}</p>

        {#if consolePlacement() === null}
          <!-- Drawn, not disabled: the server is the one that refuses, and the
               dispatcher reads why before pressing rather than meeting a dead
               button with no explanation (invariant 4, 6.4). -->
          <p class="border border-[var(--color-caution)] px-2 py-1 text-[var(--color-caution)]">
            {t('cad.console.away')}
          </p>
        {/if}

        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('cad.create.type')}</span>
          <select
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={intake.type}
          >
            {#each INTAKE_TYPES as type (type)}
              <option value={type}>{t(`cad.callType.${type}`)}</option>
            {/each}
          </select>
        </label>

        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('cad.create.priority')}</span>
          <select
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={intake.priority}
          >
            {#each CALL_PRIORITIES as priority (priority)}
              <option value={String(priority)}>{t(`cad.priority.p${priority}`)}</option>
            {/each}
          </select>
        </label>

        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('cad.create.location')}</span>
          <input
            type="text"
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            placeholder={t('cad.create.locationPlaceholder')}
            bind:value={intake.locationText}
          />
        </label>

        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('cad.create.beat')}</span>
          <select
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={intake.beatId}
          >
            <option value="">{t('cad.beat.none')}</option>
            {#each beats as beat (beat.id)}
              <option value={String(beat.id)}>{beatName(beat)}</option>
            {/each}
          </select>
        </label>

        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('cad.create.callerName')}</span>
          <input
            type="text"
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={intake.callerName}
          />
        </label>

        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('cad.create.callerPhone')}</span>
          <input
            type="text"
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={intake.callerPhone}
          />
        </label>

        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('cad.create.details')}</span>
          <textarea
            rows="3"
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={intake.details}
          ></textarea>
        </label>

        {#if failure}
          <p class="border border-[var(--color-alert)] px-2 py-1">{t(`error.${failure.err}`)}</p>
          {#each messages as message (message.name)}
            <p class="text-[var(--color-alert)]">{message.label} — {message.reason}</p>
          {/each}
        {/if}

        <button
          type="submit"
          class="border border-[var(--color-border)] px-3 py-1.5 font-semibold hover:bg-[var(--color-surface)]"
          disabled={busy}
        >
          {t('cad.create.submit')}
        </button>
      </form>
    {/if}
  </div>
</div>
