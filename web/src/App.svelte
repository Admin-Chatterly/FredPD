<script lang="ts">
  import { nui } from './lib/nui';
  import { t } from './lib/i18n';
  import type { ErrorCode } from '@fredpd/schema';

  /**
   * The application shell (spec 6.3). M1 fills in the module rail, command line,
   * tabs and context panel properly; M0 proves the frame: the NUI boots, calls a
   * route through the bridge, and renders success, failure and loading states
   * without a game server.
   */

  interface Session {
    callsign: string;
    name: string;
    agencyName: string;
    onDuty: boolean;
    modules: string[];
  }

  let session = $state<Session | null>(null);
  let error = $state<ErrorCode | null>(null);
  let loading = $state(true);

  $effect(() => {
    let cancelled = false;

    void (async () => {
      const response = await nui.call<Session>('session.get');
      if (cancelled) return;

      if (response.ok) {
        session = response.data;
        error = null;
      } else {
        error = response.err;
        session = null;
      }

      loading = false;
    })();

    return () => {
      cancelled = true;
    };
  });

  function close(): void {
    void nui.call('fredpd:close');
  }
</script>

<div class="flex h-full flex-col bg-[var(--color-panel)] text-[var(--color-ink)]">
  <!-- Title bar -->
  <header
    class="flex items-center justify-between border-b border-[var(--color-border)] px-4 py-2"
  >
    <div class="flex items-baseline gap-3">
      <span class="text-sm font-semibold tracking-wide">{t('app.name')}</span>
      {#if session}
        <span class="text-xs text-[var(--color-ink-muted)]">{session.agencyName}</span>
      {/if}
    </div>

    <button
      type="button"
      class="border border-[var(--color-border)] px-3 py-1 text-xs hover:bg-[var(--color-surface)]"
      onclick={close}
    >
      {t('shell.close')}
    </button>
  </header>

  <div class="flex min-h-0 flex-1">
    <!-- Module rail: only what this session is permitted to open. The server
         decides the list; the UI just draws it (invariant 4). -->
    <nav class="w-44 shrink-0 border-r border-[var(--color-border)] p-2">
      {#each session?.modules ?? [] as module (module)}
        <div class="px-2 py-1.5 text-xs text-[var(--color-ink-muted)]">
          {t(`shell.module.${module}`)}
        </div>
      {/each}
    </nav>

    <main class="min-w-0 flex-1 p-4">
      {#if loading}
        <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
      {:else if error}
        <p class="text-sm">{t(`error.${error}`)}</p>
      {/if}
    </main>
  </div>

  <!-- Status bar -->
  <footer
    class="flex items-center gap-4 border-t border-[var(--color-border)] px-4 py-1.5 text-xs text-[var(--color-ink-muted)]"
  >
    {#if session}
      <span>{t('shell.status.unit', { callsign: session.callsign })}</span>
      <span>{t('shell.status.signedInAs', { name: session.name })}</span>
      <span>{session.onDuty ? t('shell.status.onDuty') : t('shell.status.offDuty')}</span>
    {/if}
  </footer>
</div>
