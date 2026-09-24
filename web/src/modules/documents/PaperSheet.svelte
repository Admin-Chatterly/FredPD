<script lang="ts">
  import type { Snippet } from 'svelte';
  import { CLASSIFICATIONS } from '@fredpd/schema';
  import { t } from '../../lib/i18n';
  import type { PaperBlock, PaperDocument, PaperText } from '../../lib/paper';

  /**
   * One printed sheet (spec 7.28, ADR-020): the letterhead, the fields and the
   * body, as the paper copy and the print preview both show it. Text only,
   * never markup (invariant 10).
   *
   * The body is the part that scrolls, and it takes focus, so a long custody
   * log can be read with the arrow keys and Page Down (6.4: every action
   * works without a mouse).
   */

  interface Props {
    paper: PaperDocument;
    /** The id the sheet's heading carries, for the surrounding landmark. */
    titleId: string;
    /** The scrolling body, for the caller to focus on open. */
    body?: HTMLDivElement | null;
    footer: Snippet;
  }

  let { paper, titleId, body = $bindable(null), footer }: Props = $props();

  /**
   * A classification as the reader's language names it. The value comes off
   * an item's metadata, so only a level the schema knows is shown; anything
   * else is not a classification and is left off rather than printed raw.
   */
  const classification = $derived(
    (CLASSIFICATIONS as readonly string[]).includes(paper.classification)
      ? t(`records.classification.${paper.classification}`)
      : '',
  );
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
      <p class="mt-3 mb-1 font-semibold" role="heading" aria-level={block.level}>{@render inline(block.content)}</p>
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

<header class="flex items-start justify-between gap-4 border-b border-[var(--color-border)] px-5 py-3">
  <div>
    <p class="text-xs text-[var(--color-ink-muted)]">{paper.agency}</p>
    <h1 id={titleId} class="text-[17px] font-semibold">{paper.title}</h1>
  </div>
  <div class="flex flex-col items-end gap-1 text-xs">
    {#if classification}
      <span class="border border-[var(--color-ink)] px-2 py-0.5 font-semibold">{classification}</span>
    {/if}
    {#if paper.number}
      <span class="font-[family-name:var(--font-mono)]">{paper.number}</span>
    {/if}
  </div>
</header>

<!--
  A scrolling region a keyboard must be able to reach to scroll: the one case
  where a focusable non-control is the accessible pattern, not a mistake.
-->
<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
<div
  bind:this={body}
  tabindex="0"
  role="region"
  aria-labelledby={titleId}
  class="overflow-y-auto px-5 py-4 text-[13px] outline-offset-[-2px] focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
>
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

<footer class="flex flex-wrap items-center justify-between gap-2 border-t border-[var(--color-border)] px-5 py-2 text-xs text-[var(--color-ink-muted)]">
  {@render footer()}
</footer>
