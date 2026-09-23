<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import type { ErrorCode } from '@fredpd/schema';
  import type { ChatMessage } from '../../lib/types';

  /**
   * The internal police channel's comms log (spec 7.26).
   *
   * Sending stays where it already is -- the `/pd` command in the game's own
   * chat box -- so this screen only reads `chat.history`, gated on
   * `comms.pdchat.view` the same way every other restricted read is
   * (invariant 4): a session without it gets a refusal here, not a hidden
   * tab, and one without `comms.pdchat.all` sees only its own agency's
   * traffic, both decided on the server before this ever calls it.
   *
   * `chat.history` takes a flat `limit`, not a cursor, so this is a refresh
   * button rather than `LoadMore` (spec 12.2's keyset control): there is no
   * cursor to keep, only a larger window to ask for again.
   */

  const DEFAULT_LIMIT = 100;
  const MAX_LIMIT = 200;

  let messages = $state<ChatMessage[]>([]);
  let error = $state<ErrorCode | null>(null);
  let loading = $state(true);
  let busy = $state(false);
  let limit = $state(DEFAULT_LIMIT);

  async function load(): Promise<void> {
    busy = true;

    const response = await nui.call<{ messages: ChatMessage[] }>('chat.history', { limit });

    if (response.ok) {
      messages = response.data.messages;
      error = null;
    } else {
      error = response.err;
    }

    loading = false;
    busy = false;
  }

  function showMore(): void {
    limit = Math.min(limit + DEFAULT_LIMIT, MAX_LIMIT);
    void load();
  }

  function sender(message: ChatMessage): string {
    return message.callsign ? `${message.callsign} ${message.authorName ?? ''}`.trim() : (message.authorName ?? '');
  }

  void load();
</script>

<section class="flex min-h-0 flex-1 flex-col gap-3">
  <div class="flex items-center justify-between">
    <p class="text-xs text-[var(--color-ink-muted)]">{t('comms.hint')}</p>
    <button
      type="button"
      class="border border-[var(--color-border)] px-3 py-1 text-xs hover:bg-[var(--color-surface)]"
      disabled={busy}
      onclick={() => void load()}
    >
      {t('comms.refresh')}
    </button>
  </div>

  {#if error}
    <p class="border border-[var(--color-border)] px-3 py-2 text-sm">{t(`error.${error}`)}</p>
  {/if}

  {#if loading}
    <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
  {:else if messages.length === 0}
    <p class="text-sm text-[var(--color-ink-muted)]">{t('comms.empty')}</p>
  {:else}
    <ol class="flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto border border-[var(--color-border)] p-3 font-[family-name:var(--font-mono)] text-xs">
      {#each messages as message (message.id)}
        <li>
          <span class="text-[var(--color-ink-muted)]">{formatMoment(message.sentAt)}</span>
          <span class="font-semibold">{sender(message)}</span>:
          <span>{message.body}</span>
        </li>
      {/each}
    </ol>

    {#if messages.length >= limit && limit < MAX_LIMIT}
      <div class="flex justify-center">
        <button
          type="button"
          class="border border-[var(--color-border)] px-3 py-1 text-xs hover:bg-[var(--color-surface)]"
          disabled={busy}
          onclick={showMore}
        >
          {t('form.loadMore')}
        </button>
      </div>
    {/if}
  {/if}
</section>
