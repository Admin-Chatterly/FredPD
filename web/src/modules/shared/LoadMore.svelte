<script lang="ts">
  import { t } from '../../lib/i18n';

  /**
   * The one "load more" control every keyset-paginated list uses (spec 12.2).
   *
   * Deliberately not infinite scroll: a button the officer presses is a
   * button whose absence is legible -- no `nextCursor` means no button, which
   * reads as "that is everything" rather than as a screen that stopped
   * loading for no visible reason.
   */

  interface Props {
    nextCursor: string | null | undefined;
    busy: boolean;
    loadMore: () => void;
  }

  let { nextCursor, busy, loadMore }: Props = $props();
</script>

{#if nextCursor}
  <div class="flex justify-center py-2">
    <button
      type="button"
      class="border border-[var(--color-border)] px-3 py-1 text-xs hover:bg-[var(--color-surface)]"
      disabled={busy}
      onclick={loadMore}
    >
      {t('form.loadMore')}
    </button>
  </div>
{/if}
