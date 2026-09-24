<script lang="ts">
  import { t } from '../../lib/i18n';
  import type { PaperDocument } from '../../lib/paper';
  import PaperSheet from './PaperSheet.svelte';

  /**
   * A printed document, read off the paper that carries it (spec 7.28,
   * ADR-020). A copy, not a window onto the record: it says what the record
   * said when it was printed, to whoever holds the paper. Rendered as text,
   * never as markup (invariant 10).
   *
   * Focus starts on the text, so the keys scroll it; Tab reaches "Put away",
   * and Escape puts it away too (`main.ts`).
   */

  interface Props {
    paper: PaperDocument;
    /** Put away: the client lets go of the focus and says so, which closes the page. */
    onClose: () => void;
  }

  let { paper, onClose }: Props = $props();

  let body = $state<HTMLDivElement | null>(null);
  $effect(() => {
    body?.focus();
  });
</script>

<div class="fixed inset-0 flex items-center justify-center p-4">
  <article
    class="flex max-h-full w-full max-w-2xl flex-col border border-[var(--color-border)] bg-[var(--color-panel)] text-[var(--color-ink)]"
    aria-labelledby="paper-title"
  >
    <PaperSheet {paper} titleId="paper-title" bind:body>
      {#snippet footer()}
        <span>{t('document.paper.printed', { at: paper.printedAt, by: paper.printedBy })}</span>
        <button
          type="button"
          class="border border-[var(--color-border)] px-3 py-1 text-[var(--color-ink)] focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
          onclick={onClose}
        >
          {t('document.paper.close')}
        </button>
      {/snippet}
    </PaperSheet>
  </article>
</div>
