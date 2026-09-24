<script lang="ts">
  import { t } from '../../lib/i18n';
  import type { PaperDocument } from '../../lib/paper';
  import { fieldList, type Failure } from '../shared/failure';
  import PaperSheet from './PaperSheet.svelte';

  /**
   * The print preview (spec 6.4, 7.28): the page as it will print, and the
   * copies this record may have. Nothing is numbered or kept until a copy is
   * chosen here. A copy the record may not have is not offered, and the
   * sheet says why (ADR-020: a classified record is PDF-only, and a
   * restricted PDF is an export).
   *
   * A modal with a real focus trap, as `ConfirmDialog` has: Escape closes
   * this box and not the whole interface.
   */

  type CopyAnswer = true | string;

  interface Props {
    paper: PaperDocument;
    copies: { paper: CopyAnswer; pdf: CopyAnswer };
    busy: boolean;
    failure: Failure | null;
    print: (copy: 'paper' | 'pdf') => void;
    cancel: () => void;
  }

  let { paper, copies, busy, failure, print, cancel }: Props = $props();

  let box = $state<HTMLDivElement | null>(null);
  let body = $state<HTMLDivElement | null>(null);

  const messages = $derived(fieldList(failure, {}));

  /** Why a copy is not offered, once per reason. */
  const refusals = $derived(
    [...new Set([copies.paper, copies.pdf].filter((answer): answer is string => answer !== true))].map((reason) =>
      t(`document.copy.${reason}`),
    ),
  );

  $effect(() => {
    body?.focus();
  });

  function focusable(): HTMLElement[] {
    if (!box) return [];
    return [...box.querySelectorAll<HTMLElement>('button:not([aria-disabled="true"]), [tabindex="0"]')];
  }

  function onKeydown(event: KeyboardEvent): void {
    if (event.key === 'Escape') {
      event.stopPropagation();
      event.preventDefault();
      cancel();
      return;
    }

    if (event.key !== 'Tab') return;

    const items = focusable();
    const first = items[0];
    const last = items[items.length - 1];
    if (!first || !last) return;

    if (event.shiftKey && (document.activeElement === first || document.activeElement === box)) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  const button =
    'border border-[var(--color-border)] px-3 py-1 text-[var(--color-ink)] focus-visible:outline-2 focus-visible:outline-[var(--color-focus)] aria-disabled:opacity-60';
</script>

<!--
  Fixed inside the device (`contain: layout` on `.fredpd-device`), so it
  covers the MDT and not the world. Escape is caught on the backdrop too: a
  click there leaves focus on nothing, and the next Escape would otherwise
  reach `main.ts` and close the whole interface.
-->
<div
  class="fixed inset-0 z-50 flex items-center justify-center bg-[var(--color-surface)] p-4"
  role="presentation"
  onkeydown={onKeydown}
  onmousedown={(event) => {
    if (event.target === event.currentTarget) {
      event.preventDefault();
      body?.focus();
    }
  }}
>
  <div
    bind:this={box}
    role="dialog"
    aria-modal="true"
    aria-labelledby="print-preview-title"
    tabindex="-1"
    class="flex max-h-full w-full max-w-2xl flex-col border border-[var(--color-focus)] bg-[var(--color-panel)] text-[var(--color-ink)]"
  >
    <p id="print-preview-title" class="border-b border-[var(--color-border)] px-5 py-2 text-xs font-semibold">
      {t('document.preview.title')}
    </p>

    <PaperSheet {paper} titleId="print-preview-sheet" bind:body>
      {#snippet footer()}
        <div class="flex w-full flex-col gap-2">
          {#each refusals as reason (reason)}
            <p>{reason}</p>
          {/each}

          {#if failure}
            <div class="border border-[var(--color-alert)] px-2 py-1 text-[var(--color-ink)]" role="alert">
              <p>{messages.length > 0 ? t('document.print.failed') : t(`error.${failure.err}`)}</p>
              {#each messages as message (message.name)}
                <p class="text-[var(--color-ink-muted)]">{message.reason}</p>
              {/each}
            </div>
          {/if}

          <div class="flex flex-wrap justify-end gap-2">
            {#if copies.paper === true}
              <button
                type="button"
                class={button}
                aria-disabled={busy}
                onclick={() => {
                  if (!busy) print('paper');
                }}
              >
                {t('document.print.paper')}
              </button>
            {/if}
            {#if copies.pdf === true}
              <button
                type="button"
                class={button}
                aria-disabled={busy}
                onclick={() => {
                  if (!busy) print('pdf');
                }}
              >
                {t('document.print.pdf')}
              </button>
            {/if}
            <button type="button" class={button} onclick={cancel}>{t('form.cancel')}</button>
          </div>
        </div>
      {/snippet}
    </PaperSheet>
  </div>
</div>
