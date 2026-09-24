<script lang="ts" module>
  import { nui as bridge } from '../../lib/nui';

  type Capabilities = { paper: boolean; pdf: boolean };

  /**
   * What this server can print: a paper item, a gateway, or both. Only an
   * answer is kept -- a refusal, a timeout or a call made before the session
   * was ready is asked again next time -- and it is forgotten whenever the
   * interface opens or the officer's permissions change.
   */
  let capabilities: Promise<Capabilities | null> | null = null;

  function loadCapabilities(): Promise<Capabilities | null> {
    capabilities ??= bridge.call<Capabilities>('document.capabilities', {}).then((response) => {
      if (response.ok) return response.data;
      capabilities = null;
      return null;
    });
    return capabilities;
  }

  bridge.on('fredpd:open', () => (capabilities = null));
  bridge.on('fredpd:permissions', () => (capabilities = null));
</script>

<script lang="ts">
  import { tick } from 'svelte';
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { parsePaper, type PaperDocument } from '../../lib/paper';
  import { fieldList, type Failure } from '../shared/failure';
  import type { DocumentKind } from '@fredpd/schema';
  import PrintPreview from './PrintPreview.svelte';

  /**
   * Printing a record (spec 7.28, ADR-020). "Print…" opens the preview: the
   * page as it will print, and the copies this record may have. The copy is
   * chosen there, and only then is anything numbered or kept. What is
   * printed is the server's own reading of the record, through the record's
   * own access check.
   */

  interface Props {
    kind: DocumentKind;
    id: number;
  }

  let { kind, id }: Props = $props();

  type CopyAnswer = true | string;

  let can = $state<Capabilities | null>(null);
  let busy = $state(false);
  let failure = $state<Failure | null>(null);
  let status = $state('');
  let pdfUrl = $state<string | null>(null);
  let pdfExpiresAt = $state<number | null>(null);
  let linkInput = $state<HTMLInputElement | null>(null);
  let trigger = $state<HTMLButtonElement | null>(null);

  let preview = $state<{ paper: PaperDocument; copies: { paper: CopyAnswer; pdf: CopyAnswer } } | null>(null);
  let previewFailure = $state<Failure | null>(null);

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
    preview = null;
  });

  async function openPreview(): Promise<void> {
    if (busy) return;
    busy = true;
    failure = null;
    status = '';

    const response = await nui.call<{ document: unknown; copies: { paper: CopyAnswer; pdf: CopyAnswer } }>(
      'document.preview',
      { kind, id },
    );

    busy = false;

    const paper = response.ok ? parsePaper(response.data.document) : null;
    if (response.ok && paper) {
      previewFailure = null;
      preview = { paper, copies: response.data.copies };
    } else if (!response.ok) {
      failure = response;
    }
  }

  async function closePreview(): Promise<void> {
    preview = null;
    await tick();
    trigger?.focus();
  }

  async function print(copy: 'paper' | 'pdf'): Promise<void> {
    if (busy) return;
    busy = true;
    pdfUrl = null;

    const response = await nui.call<{ number: string; url?: string; expiresAt?: number }>('document.print', {
      kind,
      id,
      copy,
    });

    busy = false;

    if (!response.ok) {
      // Drawn in the preview, where the officer is looking.
      previewFailure = response;
      return;
    }

    status = t(copy === 'paper' ? 'document.print.paperDone' : 'document.print.pdfDone', {
      number: response.data.number,
    });
    pdfUrl = response.data.url ?? null;
    pdfExpiresAt = response.data.expiresAt ?? null;
    await closePreview();
  }

  function copyLink(): void {
    linkInput?.select();
    const copied = document.execCommand('copy');
    status = t(copied ? 'document.print.copied' : 'document.print.copyFailed');
  }
</script>

{#if can && (can.paper || can.pdf)}
  <div class="mb-3 flex flex-col gap-2 text-xs">
    <div>
      <button
        bind:this={trigger}
        type="button"
        class="border border-[var(--color-border)] px-3 py-1 focus-visible:outline-2 focus-visible:outline-[var(--color-focus)] aria-disabled:opacity-60"
        aria-disabled={busy}
        onclick={() => void openPreview()}
      >
        {t('document.print.open')}
      </button>
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
      <div class="flex items-end gap-2">
        <label class="flex flex-1 flex-col gap-1">
          {pdfExpiresAt
            ? t('document.print.link', { time: formatMoment(pdfExpiresAt) })
            : t('document.print.linkNoExpiry')}
          <input
            bind:this={linkInput}
            readonly
            value={pdfUrl}
            class="border border-[var(--color-border)] px-2 py-1 font-[family-name:var(--font-mono)]"
          />
        </label>
        <button
          type="button"
          class="border border-[var(--color-border)] px-3 py-1 focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
          onclick={copyLink}
        >
          {t('document.print.copy')}
        </button>
      </div>
    {/if}
  </div>
{/if}

{#if preview}
  <PrintPreview
    paper={preview.paper}
    copies={preview.copies}
    {busy}
    failure={previewFailure}
    print={(copy) => void print(copy)}
    cancel={() => void closePreview()}
  />
{/if}
