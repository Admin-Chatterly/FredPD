<script lang="ts">
  import { nui } from './lib/nui';
  import { t, isLocale, setLocale } from './lib/i18n';
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
  import Court from './modules/court/Court.svelte';
  import Personnel from './modules/personnel/Personnel.svelte';
  import Booking from './modules/booking/Booking.svelte';
  import Comms from './modules/comms/Comms.svelte';

  /**
   * The application shell (spec 6.3). M1 fills in the command line, tabs and
   * context panel; what is here is the frame: the NUI boots, calls a route, and
   * draws the module rail the *server* said this session may open.
   */

  let session = $state<Session | null>(null);
  let error = $state<ErrorCode | null>(null);
  let loading = $state(true);
  let current = $state<string | null>(null);

  /**
   * The shell renders as a bounded, tablet-proportioned frame by default
   * (`.fredpd-device` in app.css) rather than a window filling the screen --
   * closer to the physical MDC the spec's access points describe than to a
   * desktop application. A dense screen (a long grid, the CAD map) is one
   * click from the extra room; it is never where an officer opens into.
   * Reset on every open rather than persisted, so the shell is predictable
   * the same way a real device waking up is.
   */
  let expanded = $state(false);

  function toggleExpanded(): void {
    expanded = !expanded;
  }

  /**
   * Asks the server who this is. Run on boot and again on every open: a
   * character that loaded after the NUI booted, or a roster row created
   * since, used to leave the MDT on "not signed on" until a reconnect.
   */
  let sequence = 0;

  async function loadSession(): Promise<void> {
    const mine = ++sequence;
    const response = await nui.call<Session>('session.get');
    if (mine !== sequence) return;

    if (response.ok) {
      session = response.data;
      error = null;
      // Before anything renders a timestamp: every screen formats in the
      // department's zone, not in the one the player's machine is set to.
      setDepartmentTimezone(response.data.timezone);

      // The department's configured language, unless `main.ts` already
      // applied an explicit `?locale=` override (the dev/test escape
      // hatch) — that override must win even after this resolves.
      const explicit = new URLSearchParams(window.location.search).get('locale');
      if (explicit === null && response.data.locale && isLocale(response.data.locale)) {
        setLocale(response.data.locale);
      }

      if (current === null || !response.data.modules.includes(current)) {
        current = response.data.modules[0] ?? null;
      }
    } else {
      error = response.err;
      session = null;
    }

    loading = false;
  }

  $effect(() => {
    void loadSession();

    return () => {
      sequence++;
    };
  });

  $effect(() => nui.on('fredpd:open', () => void loadSession()));

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
  const BUILT = new Set([
    'records',
    'dispatch',
    'evidence',
    'lab',
    'intel',
    'surveillance',
    'court',
    'admin',
    'personnel',
    'booking',
    'comms',
  ]);
</script>

<div class="fredpd-stage">
<div
  class="fredpd-device flex flex-col bg-[var(--color-panel)] text-[var(--color-ink)]"
  class:fredpd-device--expanded={expanded}
>
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

    <div class="flex items-center gap-2">
      <button
        type="button"
        class="flex items-center justify-center border border-[var(--color-border)] p-1.5 text-[var(--color-ink-muted)] hover:bg-[var(--color-surface)] hover:text-[var(--color-ink)]"
        title={expanded ? t('shell.collapse') : t('shell.expand')}
        aria-label={expanded ? t('shell.collapse') : t('shell.expand')}
        onclick={toggleExpanded}
      >
        {#if expanded}
          <svg
            width="16"
            height="16"
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <rect x="3" y="2" width="10" height="12" rx="1.5" />
            <line x1="6" y1="12.5" x2="10" y2="12.5" />
          </svg>
        {:else}
          <svg
            width="16"
            height="16"
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <path d="M2 6V2h4" />
            <path d="M10 2h4v4" />
            <path d="M14 10v4h-4" />
            <path d="M6 14H2v-4" />
          </svg>
        {/if}
      </button>

      <button
        type="button"
        class="border border-[var(--color-border)] px-3 py-1 text-xs hover:bg-[var(--color-surface)]"
        onclick={close}
      >
        {t('shell.close')}
      </button>
    </div>
  </header>

  <div class="flex min-h-0 flex-1">
    <!-- Module rail: only what this session is permitted to open. The server
         decides the list; the UI just draws it (invariant 4). Sized and
         weighted for a reader who has never used this screen before: a
         visible left bar and tint mark where you are, not font-weight alone. -->
    <nav class="w-48 shrink-0 border-r border-[var(--color-border)] p-2">
      {#each session?.modules ?? [] as module (module)}
        <button
          type="button"
          class="mb-0.5 block w-full border-l-2 border-transparent px-3 py-2.5 text-left text-sm hover:bg-[var(--color-surface)]"
          class:font-semibold={current === module}
          class:border-[var(--color-accent)]={current === module}
          class:bg-[var(--color-surface)]={current === module}
          onclick={() => (current = module)}
        >
          {t(`shell.module.${module}`)}
        </button>
      {/each}
    </nav>

    <main class="min-w-0 flex-1 overflow-y-auto p-4">
      {#if !loading && !error && current !== null}
        <!-- One consistent answer to "where am I", above every module's own
             content, so the active rail entry is never the only confirmation. -->
        <h1 class="mb-3 text-base font-semibold">{t(`shell.module.${current}`)}</h1>
      {/if}

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
      {:else if current === 'court'}
        <Court />
      {:else if current === 'personnel'}
        <Personnel />
      {:else if current === 'booking'}
        <Booking />
      {:else if current === 'comms'}
        <Comms />
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
          <p class="text-xs font-semibold text-[var(--color-ink-muted)]">
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
</div>
