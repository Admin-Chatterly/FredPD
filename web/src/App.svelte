<script lang="ts">
  import { nui } from './lib/nui';
  import { t } from './lib/i18n';
  import type { ErrorCode } from '@fredpd/schema';
  import type { Session } from './lib/types';
  import RoleMap from './modules/admin/RoleMap.svelte';
  import Groups from './modules/admin/Groups.svelte';
  import Fleet from './modules/admin/Fleet.svelte';
  import Evidence from './modules/evidence/Evidence.svelte';
  import Lab from './modules/lab/Lab.svelte';
  import Intel from './modules/intel/Intel.svelte';

  /**
   * The application shell (spec 6.3). M1 fills in the command line, tabs and
   * context panel; what is here is the frame: the NUI boots, calls a route, and
   * draws the module rail the *server* said this session may open.
   */

  let session = $state<Session | null>(null);
  let error = $state<ErrorCode | null>(null);
  let loading = $state(true);
  let current = $state<string | null>(null);

  $effect(() => {
    let cancelled = false;

    void (async () => {
      const response = await nui.call<Session>('session.get');
      if (cancelled) return;

      if (response.ok) {
        session = response.data;
        error = null;
        current ??= response.data.modules[0] ?? null;
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

  /**
   * Permissions changed while the MDT was open — a role was added or removed,
   * or an administrator edited the role map. The rail redraws, and a module the
   * session can no longer open stops being selected (spec 4.2).
   */
  $effect(() =>
    nui.on('fredpd:permissions', (message) => {
      const modules = message['modules'];
      if (!session || !Array.isArray(modules)) return;

      session = { ...session, modules: modules as string[] };

      if (current !== null && !session.modules.includes(current)) {
        current = session.modules[0] ?? null;
      }
    }),
  );

  function close(): void {
    void nui.call('fredpd:close');
  }

  /**
   * Administration is three screens, not one: the role map, the groups those
   * roles grant, and the motor pool fleet. They are a sub-navigation rather
   * than three rail entries because the rail draws the *modules* the server
   * opened, and all three sit behind the one `admin` module.
   *
   * Which of them a session may actually use is still the server's answer —
   * each screen's own routes refuse independently, and a tab that leads to a
   * refusal is drawn as a refusal (invariant 4).
   */
  const ADMIN_TABS = ['rolemap', 'groups', 'fleet'] as const;
  type AdminTab = (typeof ADMIN_TABS)[number];

  let adminTab = $state<AdminTab>('rolemap');
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
        <button
          type="button"
          class="block w-full px-2 py-1.5 text-left text-xs hover:bg-[var(--color-surface)]"
          class:font-semibold={current === module}
          onclick={() => (current = module)}
        >
          {t(`shell.module.${module}`)}
        </button>
      {/each}
    </nav>

    <main class="min-w-0 flex-1 overflow-y-auto p-4">
      {#if loading}
        <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
      {:else if error}
        <p class="text-sm">{t(`error.${error}`)}</p>
      {:else if current === 'intel'}
        <Intel />
      {:else if current === 'evidence'}
        <Evidence />
      {:else if current === 'lab'}
        <Lab />
      {:else if session && current === 'admin'}
        <nav class="mb-4 flex gap-1 border-b border-[var(--color-border)]">
          {#each ADMIN_TABS as tab (tab)}
            <button
              type="button"
              class="border-b-2 px-3 py-1.5 text-xs"
              class:border-transparent={adminTab !== tab}
              class:border-[var(--color-ink)]={adminTab === tab}
              class:font-semibold={adminTab === tab}
              onclick={() => (adminTab = tab)}
            >
              {t(`admin.tab.${tab}`)}
            </button>
          {/each}
        </nav>

        {#if adminTab === 'rolemap'}
          <RoleMap agencyId={session.agencyId} />
        {:else if adminTab === 'groups'}
          <Groups />
        {:else}
          <Fleet />
        {/if}
      {/if}
    </main>
  </div>

  <!-- Status bar -->
  <footer
    class="flex items-center gap-4 border-t border-[var(--color-border)] px-4 py-1.5 text-xs text-[var(--color-ink-muted)]"
  >
    {#if session}
      <span>{t('shell.status.unit', { callsign: session.callsign ?? '' })}</span>
      <span>{t('shell.status.signedInAs', { name: session.name })}</span>
      <span>{session.onDuty ? t('shell.status.onDuty') : t('shell.status.offDuty')}</span>
      {#if session.permissionsStale}
        <span>{t('shell.status.permissionsStale')}</span>
      {/if}
    {/if}
  </footer>
</div>
