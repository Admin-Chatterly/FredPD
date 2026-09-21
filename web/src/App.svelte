<script lang="ts">
  import { nui } from './lib/nui';
  import { t } from './lib/i18n';
  import { setDepartmentTimezone } from './lib/time';
  import type { ErrorCode } from '@fredpd/schema';
  import type { Session } from './lib/types';
  import RoleMap from './modules/admin/RoleMap.svelte';
  import Groups from './modules/admin/Groups.svelte';
  import Fleet from './modules/admin/Fleet.svelte';
  import Health from './modules/admin/Health.svelte';
  import Records from './modules/records/Records.svelte';
  import Dispatch from './modules/cad/Dispatch.svelte';
  import Evidence from './modules/evidence/Evidence.svelte';
  import Lab from './modules/lab/Lab.svelte';
  import Intel from './modules/intel/Intel.svelte';
  import Surveillance from './modules/surveillance/Surveillance.svelte';

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
        // Before anything renders a timestamp: every screen formats in the
        // department's zone, not in the one the player's machine is set to.
        setDepartmentTimezone(response.data.timezone);
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
   * Administration is four screens, not one: the role map, the groups those
   * roles grant, the motor pool fleet, and the server's own counters. They are
   * a sub-navigation rather than four rail entries because the rail draws the
   * *modules* the server opened, and all four sit behind the one `admin`
   * module.
   *
   * Which of them a session may actually use is still the server's answer —
   * each screen's own routes refuse independently, and a tab that leads to a
   * refusal is drawn as a refusal (invariant 4): the seed gives `page.admin`
   * and `admin.health.view` to the same group, but a server that authors its
   * own groups can separate them, and a session holding one without the other
   * gets the tab and a refusal behind it.
   */
  const ADMIN_TABS = ['rolemap', 'groups', 'fleet', 'health'] as const;
  type AdminTab = (typeof ADMIN_TABS)[number];

  let adminTab = $state<AdminTab>('rolemap');

  /**
   * The rail entries that have a screen behind them today.
   *
   * `session.allowedModules()` on the server derives the rail from `page.*`
   * permissions, and it lists every module the spec plans — so a patrol group
   * has opened Records and got a blank panel since M1. The permission is not
   * wrong and must not be trimmed to match what is built: it says what the
   * officer is cleared for. What was missing is the interface saying so.
   *
   * A module joins this list when its page is imported above; until then the
   * rail entry draws the placeholder.
   */
  const BUILT = new Set(['records', 'dispatch', 'evidence', 'lab', 'intel', 'surveillance', 'admin']);
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
      {:else if current === 'records'}
        <Records />
      {:else if current === 'dispatch'}
        <Dispatch />
      {:else if current === 'evidence'}
        <Evidence />
      {:else if current === 'lab'}
        <Lab />
      {:else if current === 'surveillance'}
        <Surveillance />
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
        {:else if adminTab === 'fleet'}
          <Fleet />
        {:else}
          <Health />
        {/if}
      {:else if current !== null && !BUILT.has(current)}
        <!-- A module the session is cleared for that has no screen yet. Saying
             so is not the same as saying "forbidden": the officer's access is
             intact and the text has to make that difference plain, because the
             two look identical from an empty panel (spec 6.6). -->
        <section class="max-w-prose border border-[var(--color-border)] p-4">
          <h2 class="text-sm font-semibold">{t(`shell.module.${current}`)}</h2>
          <p class="mt-2 text-xs font-semibold text-[var(--color-ink-muted)]">
            {t('shell.unbuilt.title')}
          </p>
          <p class="mt-1 text-xs text-[var(--color-ink-muted)]">{t('shell.unbuilt.body')}</p>
        </section>
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
