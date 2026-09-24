<script lang="ts">
  import { t } from '../../lib/i18n';
  import type { PaperBlock, PaperDocument, PaperText } from '../../lib/paper';

  /**
   * A printed document, read off the paper that carries it (spec 7.28,
   * ADR-020). A copy, not a window onto the record: it says what the record
   * said when it was printed, to whoever holds the paper. Rendered as text,
   * never as markup (invariant 10).
   */

  interface Props {
    paper: PaperDocument;
    /** Put away: the page closes, and the client lets go of the focus. */
    onClose: () => void;
  }

  let { paper, onClose }: Props = $props();

  let closeButton = $state<HTMLButtonElement | null>(null);
  $effect(() => {
    closeButton?.focus();
  });
</script>

{#snippet inline(content: PaperText[])}
  {#each content as run, index (index)}
    {#if run.bold && run.italic}<strong><em>{run.text}</em></strong>{:else if run.bold}<strong>{run.text}</strong>{:else if run.italic}<em>{run.text}</em>{:else}{run.text}{/if}
  {/each}
{/snippet}

{#snippet blocks(list: PaperBlock[])}
  {#each list as block, index (index)}
    {#if block.type === 'paragraph'}
      <p class="mb-2">{@render inline(block.content)}</p>
    {:else if block.type === 'heading'}
      <p class="mt-3 mb-1 font-semibold" role="heading" aria-level={block.level + 1}>{@render inline(block.content)}</p>
    {:else if block.ordered}
      <ol class="mb-2 list-decimal pl-5">
        {#each block.items as item, itemIndex (itemIndex)}<li>{@render blocks(item)}</li>{/each}
      </ol>
    {:else}
      <ul class="mb-2 list-disc pl-5">
        {#each block.items as item, itemIndex (itemIndex)}<li>{@render blocks(item)}</li>{/each}
      </ul>
    {/if}
  {/each}
{/snippet}

<div class="fixed inset-0 flex items-center justify-center p-4">
  <article
    class="flex max-h-full w-full max-w-2xl flex-col border border-[var(--color-border)] bg-[var(--color-panel)] text-[var(--color-ink)]"
    aria-labelledby="paper-title"
  >
    <header class="flex items-start justify-between gap-4 border-b border-[var(--color-border)] px-5 py-3">
      <div>
        <p class="text-xs text-[var(--color-ink-muted)]">{paper.agency}</p>
        <h1 id="paper-title" class="text-[17px] font-semibold">{paper.title}</h1>
      </div>
      <div class="flex flex-col items-end gap-1 text-xs">
        {#if paper.classification}
          <span class="border border-[var(--color-ink)] px-2 py-0.5 font-semibold">{paper.classification}</span>
        {/if}
        <span class="font-[family-name:var(--font-mono)]">{paper.number}</span>
      </div>
    </header>

    <div class="overflow-y-auto px-5 py-4 text-[13px]">
      <dl class="mb-4 grid grid-cols-[10rem_1fr] gap-x-3 gap-y-1">
        {#each paper.fields as field, index (index)}
          <dt class="text-[var(--color-ink-muted)]">{field.label}</dt>
          <dd class="whitespace-pre-wrap">{field.value}</dd>
        {/each}
      </dl>

      {@render blocks(paper.body)}

      {#if paper.cut}
        <p class="mt-3 text-xs text-[var(--color-ink-muted)]">{t('document.paper.cut')}</p>
      {/if}
    </div>

    <footer class="flex items-center justify-between gap-4 border-t border-[var(--color-border)] px-5 py-2 text-xs text-[var(--color-ink-muted)]">
      <span>{t('document.paper.printed', { at: paper.printedAt, by: paper.printedBy })}</span>
      <button
        type="button"
        bind:this={closeButton}
        class="border border-[var(--color-border)] px-3 py-1 text-[var(--color-ink)] focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
        onclick={onClose}
      >
        {t('document.paper.close')}
      </button>
    </footer>
  </article>
</div>
