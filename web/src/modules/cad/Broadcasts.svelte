<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import type { ErrorCode } from '@fredpd/schema';
  import { BROADCAST_KINDS, CALL_PRIORITIES } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import { FIELD_LABELS, priorityInk, priorityShort, stamp, type Broadcast, type Call } from './Dispatch.svelte';

  /**
   * The broadcast board (spec 7.16 [S], 7.26): what is out on the air.
   *
   * A broadcast is radio traffic rather than a record. A `bolo` here is the
   * message that goes to every unit; it is not the formal BOLO record of 7.13,
   * and putting a plate on one does nothing to that plate — making an ALPR
   * banner fire is a hotlist entry under its own permission (7.18), because a
   * plate worth stopping a car over is a decision with its own key.
   *
   * Nothing is ever deleted. Taking a message off the air stamps the row and
   * leaves it, so "what was out at the time" survives the shift it was asked
   * about — which is what `cad.broadcast.expires` shows against the live board
   * and what the expired board is read for afterwards.
   */

  interface Props {
    /** The console's calls, so a broadcast raised from one can name it. */
    calls: Call[];
  }

  const { calls }: Props = $props();

  let broadcasts = $state<Broadcast[]>([]);
  let includeExpired = $state(false);
  let kindFilter = $state('');

  let error = $state<ErrorCode | null>(null);
  let loading = $state(true);
  let busy = $state(false);
  let failure = $state<Failure | null>(null);
  let formOpen = $state(false);

  const FIRST_KIND: string = BROADCAST_KINDS[0];

  let draft = $state({
    kind: FIRST_KIND,
    priority: '3',
    title: '',
    body: '',
    plate: '',
    expiresInMinutes: '',
  });

  /**
   * The board.
   *
   * The filters are arguments rather than reads of the state above, so the
   * effect below says plainly what it re-reads on: the live board and the
   * history are two different index reads on the server, and moving either
   * filter asks it a different question.
   */
  async function load(expired: boolean, kind: string): Promise<void> {
    loading = true;

    const response = await nui.call<{ broadcasts: Broadcast[] }>('broadcast.list', {
      includeExpired: expired || undefined,
      kind: kind || undefined,
    });

    if (response.ok) {
      broadcasts = response.data.broadcasts;
      error = null;
    } else {
      error = response.err;
    }

    loading = false;
  }

  $effect(() => {
    void load(includeExpired, kindFilter);
  });

  $effect(() =>
    nui.on('fredpd:cad:broadcast', (message) => {
      const cancelledId = message['cancelledId'];

      if (typeof cancelledId === 'number') {
        // Off the air. It leaves the live board and stays on the expired one,
        // which is the same thing the server's own read does.
        broadcasts = includeExpired
          ? broadcasts.map((entry) =>
              entry.id === cancelledId
                ? { ...entry, cancelledAt: new Date().toISOString() }
                : entry,
            )
          : broadcasts.filter((entry) => entry.id !== cancelledId);

        return;
      }

      const incoming = message['broadcast'] as Broadcast | undefined;
      if (!incoming) return;

      broadcasts = [
        incoming,
        ...broadcasts.filter((entry) => entry.id !== incoming.id),
      ];
    }),
  );

  async function create(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    busy = true;

    const response = await nui.call('broadcast.create', {
      kind: draft.kind,
      priority: Number(draft.priority),
      title: draft.title,
      body: draft.body,
      plate: draft.plate || undefined,
      expiresInMinutes: draft.expiresInMinutes ? Number(draft.expiresInMinutes) : undefined,
    });

    if (response.ok) {
      failure = null;
      formOpen = false;
      draft = {
        kind: FIRST_KIND,
        priority: '3',
        title: '',
        body: '',
        plate: '',
        expiresInMinutes: '',
      };
      await load(includeExpired, kindFilter);
    } else {
      failure = response;
    }

    busy = false;
  }

  async function cancel(id: number): Promise<void> {
    busy = true;

    const response = await nui.call('broadcast.cancel', { id });

    if (response.ok) {
      failure = null;
      await load(includeExpired, kindFilter);
    } else {
      failure = response;
    }

    busy = false;
  }

  function callNumber(callId: number | null): string {
    if (callId === null) return '';

    return calls.find((call) => call.id === callId)?.callNumber ?? '';
  }

  const messages = $derived(fieldList(failure, FIELD_LABELS));
</script>

<section class="flex min-h-0 flex-col gap-3">
  <header class="flex flex-wrap items-center gap-3">
    <h2 class="text-sm font-semibold">{t('cad.broadcast.title')}</h2>

    <label class="flex items-center gap-2 text-xs">
      <span class="text-[var(--color-ink-muted)]">{t('cad.broadcast.kind')}</span>
      <select
        class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
        bind:value={kindFilter}
      >
        <option value="">{t('cad.filter.any')}</option>
        {#each BROADCAST_KINDS as kind (kind)}
          <option value={kind}>{t(`cad.broadcastKind.${kind}`)}</option>
        {/each}
      </select>
    </label>

    <label class="flex items-center gap-2 text-xs">
      <input type="checkbox" bind:checked={includeExpired} />
      <span>{t('cad.broadcast.cancelled')}</span>
    </label>

    <button
      type="button"
      class="ml-auto border border-[var(--color-border)] px-3 py-1 text-xs hover:bg-[var(--color-surface)]"
      onclick={() => (formOpen = !formOpen)}
    >
      {t('cad.broadcast.create')}
    </button>
  </header>

  {#if error}
    <p class="border border-[var(--color-border)] px-3 py-2 text-sm">{t(`error.${error}`)}</p>
  {/if}

  {#if failure}
    <div class="border border-[var(--color-alert)] px-3 py-1.5 text-xs">
      <p class="font-semibold">{t(`error.${failure.err}`)}</p>
      {#each messages as message (message.name)}
        <p class="text-[var(--color-alert)]">{message.label} — {message.reason}</p>
      {/each}
    </div>
  {/if}

  {#if formOpen}
    <form class="flex max-w-xl flex-col gap-2 border border-[var(--color-border)] p-3 text-xs" onsubmit={create}>
      <label class="flex items-center gap-2">
        <span class="w-28 shrink-0 text-[var(--color-ink-muted)]">{t('cad.broadcast.kind')}</span>
        <select
          class="min-w-0 flex-1 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={draft.kind}
        >
          {#each BROADCAST_KINDS as kind (kind)}
            <option value={kind}>{t(`cad.broadcastKind.${kind}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex items-center gap-2">
        <span class="w-28 shrink-0 text-[var(--color-ink-muted)]">{t('cad.filter.priority')}</span>
        <select
          class="min-w-0 flex-1 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={draft.priority}
        >
          {#each CALL_PRIORITIES as priority (priority)}
            <option value={String(priority)}>{t(`cad.priority.p${priority}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex items-center gap-2">
        <span class="w-28 shrink-0 text-[var(--color-ink-muted)]">
          {t('cad.broadcast.headline')}
        </span>
        <input
          type="text"
          class="min-w-0 flex-1 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={draft.title}
        />
      </label>

      <label class="flex flex-col gap-1">
        <span class="text-[var(--color-ink-muted)]">{t('cad.broadcast.body')}</span>
        <textarea
          rows="3"
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={draft.body}
        ></textarea>
      </label>

      <label class="flex items-center gap-2">
        <span class="w-28 shrink-0 text-[var(--color-ink-muted)]">{t('cad.broadcast.plate')}</span>
        <input
          type="text"
          class="min-w-0 flex-1 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={draft.plate}
        />
      </label>

      <label class="flex items-center gap-2">
        <span class="w-28 shrink-0 text-[var(--color-ink-muted)]">
          {t('cad.broadcast.expiresIn')}
        </span>
        <input
          type="number"
          min="5"
          max="10080"
          class="min-w-0 flex-1 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={draft.expiresInMinutes}
        />
      </label>
      <p class="text-[var(--color-ink-muted)]">{t('cad.broadcast.expiresInHint')}</p>

      <button
        type="submit"
        class="self-start border border-[var(--color-border)] px-3 py-1 font-semibold hover:bg-[var(--color-surface)]"
        disabled={busy}
      >
        {t('cad.broadcast.submit')}
      </button>
    </form>
  {/if}

  {#if loading}
    <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
  {:else if broadcasts.length === 0}
    <p class="border border-[var(--color-border)] px-3 py-2 text-xs text-[var(--color-ink-muted)]">
      {t('cad.broadcast.empty')}
    </p>
  {:else}
    <ul class="flex flex-col">
      {#each broadcasts as entry (entry.id)}
        <li class="border border-b-0 border-[var(--color-border)] px-3 py-2 last:border-b">
          <div class="flex flex-wrap items-baseline gap-2">
            <span class="{priorityInk(entry.priority)} text-xs font-semibold" title={t(`cad.priority.p${entry.priority}`)}>
              {priorityShort(entry.priority)}
            </span>
            <span class="text-xs text-[var(--color-ink-muted)]">
              {t(`cad.broadcastKind.${entry.kind}`)}
            </span>
            <span class="text-sm font-semibold">{entry.title}</span>

            {#if entry.plate}
              <span class="font-[family-name:var(--font-mono)] text-xs">{entry.plate}</span>
            {/if}

            <!-- Only when the number can actually be named: the board is read
                 from the console's own call list, and a broadcast can outlive
                 the call it came out of. "From call ——" says less than
                 nothing. -->
            {#if entry.callId !== null && callNumber(entry.callId) !== ''}
              <span class="text-xs text-[var(--color-ink-muted)]">
                {t('cad.broadcast.fromCall', { number: callNumber(entry.callId) })}
              </span>
            {/if}

            <span class="ml-auto flex items-baseline gap-3 text-xs">
              {#if entry.cancelledAt}
                <span class="text-[var(--color-ink-muted)]">{t('cad.broadcast.cancelled')}</span>
              {:else}
                {#if entry.expiresAt}
                  <span class="text-[var(--color-ink-muted)]">
                    {t('cad.broadcast.expires')}
                  </span>
                  <span class="font-[family-name:var(--font-mono)] text-[var(--color-ink-muted)]">
                    {stamp(entry.expiresAt)}
                  </span>
                {/if}
                <button
                  type="button"
                  class="border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-surface)]"
                  disabled={busy}
                  onclick={() => void cancel(entry.id)}
                >
                  {t('cad.broadcast.cancel')}
                </button>
              {/if}
            </span>
          </div>

          <p class="mt-1 text-xs">{entry.body}</p>
        </li>
      {/each}
    </ul>
  {/if}
</section>
