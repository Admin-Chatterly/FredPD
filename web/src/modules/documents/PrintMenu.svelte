<script lang="ts" module>
  import { nui as bridge } from '../../lib/nui';

  /** What this server can print, asked once: a paper item, a gateway, or both. */
  let capabilities: Promise<{ paper: boolean; pdf: boolean } | null> | null = null;

  function loadCapabilities(): Promise<{ paper: boolean; pdf: boolean } | null> {
    capabilities ??= bridge
      .call<{ paper: boolean; pdf: boolean }>('document.capabilities', {})
      .then((response) => (response.ok ? response.data : null));
    return capabilities;
  }
</script>

<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { fieldList, type Failure } from '../shared/failure';
  import type { DocumentKind } from '@fredpd/schema';

  /**
   * Printing a record (spec 7.28, ADR-020): a paper copy into the officer's
   * inventory, or a PDF from the gateway. Each is offered only when the
   * server can make it; what is printed is the server's own reading of the
   * record, through the record's own access check.
   */

  interface Props {
    kind: DocumentKind;
    id: number;
  }

  let { kind, id }: Props = $props();

  let can = $state<{ paper: boolean; pdf: boolean } | null>(null);
  let busy = $state(false);
  let failure = $state<Failure | null>(null);
  let status = $state('');
  let pdfUrl = $state<string | null>(null);
  let linkInput = $state<HTMLInputElement | null>(null);

  const messages = $derived(fieldList(failure, {}));

  $effect(() => {
    void loadCapabilities().then((answer) => (can = answer));
  });

  // Another record: nothing said about the last one carries over.
  $effect(() => {
    void id;
    failure = null;
    status = '';
    pdfUrl = null;
  });

  async function print(copy: 'paper' | 'pdf'): Promise<void> {
    if (busy) return;
    busy = true;
    status = '';
    pdfUrl = null;

    const response = await nui.call<{ number: string; url?: string }>('document.print', { kind, id, copy });

    if (response.ok) {
      failure = null;
      status = t(copy === 'paper' ? 'document.print.paperDone' : 'document.print.pdfDone', {
        number: response.data.number,
      });
      pdfUrl = response.data.url ?? null;
    } else {
      failure = response;
    }

    busy = false;
  }

  function copyLink(): void {
    linkInput?.select();
    document.execCommand('copy');
  }
</script>

{#if can && (can.paper || can.pdf)}
  <div class="flex flex-col gap-2 text-xs">
    <div class="flex flex-wrap gap-2">
      {#if can.paper}
        <button
          type="button"
          class="border border-[var(--color-border)] px-3 py-1 focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
          disabled={busy}
          onclick={() => void print('paper')}
        >
          {t('document.print.paper')}
        </button>
      {/if}
      {#if can.pdf}
        <button
          type="button"
          class="border border-[var(--color-border)] px-3 py-1 focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
          disabled={busy}
          onclick={() => void print('pdf')}
        >
          {t('document.print.pdf')}
        </button>
      {/if}
    </div>

    {#if failure}
      <div class="border border-[var(--color-alert)] px-2 py-1" role="alert">
        <p>{messages.length > 0 ? t('document.print.failed') : t(`error.${failure.err}`)}</p>
        {#each messages as message (message.name)}
          <p class="text-[var(--color-ink-muted)]">{message.reason}</p>
        {/each}
      </div>
    {/if}
    {#if status}
      <p class="text-[var(--color-ink-muted)]" role="status">{status}</p>
    {/if}
    {#if pdfUrl}
      <div class="flex items-center gap-2">
        <label class="flex flex-1 flex-col gap-1">
          {t('document.print.link')}
          <input
            bind:this={linkInput}
            readonly
            value={pdfUrl}
            class="border border-[var(--color-border)] px-2 py-1 font-[family-name:var(--font-mono)]"
          />
        </label>
        <button
          type="button"
          class="mt-4 border border-[var(--color-border)] px-3 py-1 focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
          onclick={copyLink}
        >
          {t('document.print.copy')}
        </button>
      </div>
    {/if}
  </div>
{/if}
