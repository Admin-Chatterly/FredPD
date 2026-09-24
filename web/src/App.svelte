<script lang="ts">
  import { tick } from 'svelte';
  import { nui } from './lib/nui';
  import { t, isLocale, setLocale } from './lib/i18n';
  import { setDepartmentTimezone } from './lib/time';
  import { onIntent, parseIntent, setIntent } from './lib/intent';
  import { parseCommand } from './lib/command';
  import { setAllowedModules } from './lib/modules';
  import type { ErrorCode } from '@fredpd/schema';
  import type { Session } from './lib/types';
  import RoleMap from './modules/admin/RoleMap.svelte';
  import Groups from './modules/admin/Groups.svelte';
  import Fleet from './modules/admin/Fleet.svelte';
  import Health from './modules/admin/Health.svelte';
  import Records from './modules/records/Records.svelte';
  import Overview from './modules/overview/Overview.svelte';
  import Dispatch from './modules/cad/Dispatch.svelte';
  import Evidence from './modules/evidence/Evidence.svelte';
  import Lab from './modules/lab/Lab.svelte';
  import Intel from './modules/intel/Intel.svelte';
  import Surveillance from './modules/surveillance/Surveillance.svelte';
  import Court from './modules/court/Court.svelte';
  import Personnel from './modules/personnel/Personnel.svelte';
  import Booking from './modules/booking/Booking.svelte';
  import Comms from './modules/comms/Comms.svelte';
  import PaperViewer from './modules/documents/PaperViewer.svelte';
  import CivilianDesk from './modules/civilian/CivilianDesk.svelte';
  import { parsePaper, type PaperDocument } from './lib/paper';

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

  /**
   * The module a terminal opens into. An officer who walks up to the property
   * room wants the evidence screen, not whatever they had open last.
   */
  const MODULE_FOR_PLACEMENT: Record<string, string> = {
    station_terminal: 'records',
    property_terminal: 'evidence',
    lab_terminal: 'lab',
    booking_terminal: 'booking',
    dispatch_console: 'dispatch',
    courthouse_terminal: 'court',
  };

  async function loadSession(preferred: string | null = null): Promise<void> {
    const mine = ++sequence;
    const response = await nui.call<Session>('session.get');
    if (mine !== sequence) return;

    if (response.ok) {
      session = response.data;
      setAllowedModules(response.data.modules);
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

      if (preferred !== null && response.data.modules.includes(preferred)) {
        current = preferred;
      } else if (current === null || !response.data.modules.includes(current)) {
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

  // A screen handing over to another module ("Book this person" on a
  // custody chain): switch to it, if this session may open it at all.
  $effect(() =>
    onIntent((intent) => {
      if (session?.modules.includes(intent.module)) current = intent.module;
    }),
  );

  /**
   * The command line (Appendix F). A query opens the query screen through an
   * intent; a status, attach or clear is the same route the status keys in
   * the game call. The server decides every one of them.
   */
  let commandInput = $state<HTMLInputElement | null>(null);
  let commandText = $state('');
  let commandNote = $state<{ text: string; error: boolean } | null>(null);
  let commandBusy = $state(false);

  /** What a refusal means here, in the officer's terms where the route's own
   * field reason says more than the generic error does. */
  const COMMAND_REASONS = new Set(['not_assigned', 'none_nearby']);

  function refusalText(response: { err: ErrorCode; fields?: Record<string, string> }): string {
    const reason = response.fields?.['callId'];
    return reason && COMMAND_REASONS.has(reason)
      ? t(`command.error.${reason}`)
      : t(`error.${response.err}`);
  }

  async function runCommand(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (commandBusy) return;

    const command = parseCommand(commandText);

    if (command.kind === 'invalid') {
      commandNote = { text: t(`command.invalid.${command.reason}`), error: true };
      return;
    }

    if (command.kind === 'query') {
      // Navigation only to a screen this session could click to anyway.
      if (!session?.modules.includes('records')) {
        commandNote = { text: t('error.forbidden'), error: true };
        return;
      }

      setIntent({
        module: 'records',
        tab: 'query',
        term: command.term,
        ...(command.type ? { type: command.type } : {}),
      });
      commandText = '';
      commandNote = null;
      return;
    }

    commandBusy = true;

    let response;
    let done: string;

    if (command.kind === 'status') {
      // En route and on scene move the call along with the unit, exactly as
      // the in-game keys do; the rest are the unit's own business.
      const progress = command.status === 'en_route' || command.status === 'on_scene';
      response = await nui.call(progress ? 'unit.progress' : 'unit.status', { status: command.status });
      done = t('status.done', { status: t(`cad.unitStatus.${command.status}`) });
    } else if (command.kind === 'attach') {
      response = await nui.call<{ callNumber?: string }>('call.attach_nearest', {});
      done = response.ok ? t('status.attached', { number: response.data.callNumber ?? '' }) : '';
    } else {
      response = await nui.call('call.clear_mine', { disposition: command.disposition });
      // Says which ending was recorded: a bare CLR records "handled on scene".
      done = t('cad.log.cleared', { disposition: t(`cad.disposition.${command.disposition}`) });
    }

    commandBusy = false;

    if (response.ok) {
      commandText = '';
      commandNote = { text: done, error: false };
    } else {
      commandNote = { text: refusalText(response), error: true };
    }

    await tick();
    commandInput?.focus();
  }

  // Ctrl+K (Cmd+K) puts the cursor in the command line from anywhere.
  $effect(() => {
    function focusCommand(event: KeyboardEvent): void {
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') {
        // Never out of an open confirmation: its focus trap would lose the
        // officer, and Esc would then close the whole MDT under it.
        if (document.querySelector('[aria-modal="true"]')) return;
        event.preventDefault();
        commandInput?.focus();
      }
    }

    window.addEventListener('keydown', focusCommand);
    return () => window.removeEventListener('keydown', focusCommand);
  });

  $effect(() =>
    nui.on('fredpd:open', (message) => {
      // A field action's "Open in MDT" names the screen outright; a terminal
      // names it by its kind. The screen itself takes the rest of the intent.
      const intent = parseIntent(message['intent']);
      if (intent) setIntent(intent);

      const kind = message['placementKind'];
      const preferred =
        intent?.module ?? (typeof kind === 'string' ? (MODULE_FOR_PLACEMENT[kind] ?? null) : null);
      void loadSession(preferred);
    }),
  );

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
      setAllowedModules(session.modules);

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
    'overview',
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

  /**
   * A printed document being read (7.28, ADR-020): opened by using the paper
   * item, by anybody holding it, with or without an MDT session. The MDT
   * stays mounted underneath, hidden, so nothing open in it is lost.
   */
  let paper = $state<PaperDocument | null>(null);
  $effect(() => nui.on('fredpd:paper', (message) => (paper = parsePaper(message['document']))));
  $effect(() => nui.on('fredpd:close', () => (paper = null)));
  $effect(() => nui.on('fredpd:open', () => (paper = null)));

  /**
   * A police front desk (7.29): opened by standing at one, by anybody. Like
   * a paper copy, it is not the MDT, which stays mounted and hidden beneath.
   */
  let desk = $state<number | null>(null);
  $effect(() =>
    nui.on('fredpd:civilian', (message) => {
      // A visitor has no session: the department's language and clock come
      // with the message, and an explicit `?locale=` still wins.
      const timezone = message['timezone'];
      if (typeof timezone === 'string') setDepartmentTimezone(timezone);
      const locale = message['locale'];
      const explicit = new URLSearchParams(window.location.search).get('locale');
      if (explicit === null && typeof locale === 'string' && isLocale(locale)) setLocale(locale);

      const id = Number(message['placementId']);
      desk = Number.isInteger(id) && id > 0 ? id : null;
    }),
  );
  $effect(() => nui.on('fredpd:close', () => (desk = null)));
  $effect(() => nui.on('fredpd:open', () => (desk = null)));
</script>

{#if paper}
  <PaperViewer
    {paper}
    onClose={() => {
      // The client's own `fredpd:close` puts it away: cleared here first,
      // the MDT underneath would show for the round trip.
      void nui.call('fredpd:close');
    }}
  />
{/if}

{#if desk !== null}
  <CivilianDesk
    placementId={desk}
    onClose={() => {
      // The client's own `fredpd:close` puts it away, as for a paper copy.
      void nui.call('fredpd:close');
    }}
  />
{/if}

<div class="fredpd-stage" hidden={paper !== null || desk !== null}>
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

  <!--
    The command line (Appendix F), in its own row under the title bar as 6.3
    draws it: a visible label, the line, and the answer beside it with room
    to be read in full.
  -->
  {#if session}
    <form
      class="flex flex-wrap items-center gap-x-2 gap-y-1 border-b border-[var(--color-border)] px-4 py-1.5"
      onsubmit={runCommand}
    >
      <label for="fredpd-command" class="text-xs font-semibold">{t('command.prompt')}</label>
      <input
        id="fredpd-command"
        bind:this={commandInput}
        bind:value={commandText}
        type="text"
        autocomplete="off"
        spellcheck="false"
        aria-keyshortcuts="Control+K"
        aria-describedby="fredpd-command-note"
        placeholder={t('shell.commandPlaceholder')}
        readonly={commandBusy}
        aria-busy={commandBusy}
        oninput={() => (commandNote = null)}
        onkeydown={(event) => {
          // Esc abandons a half-typed command; only an empty line lets it
          // through to close the MDT.
          if (event.key === 'Escape' && commandText !== '') {
            event.stopPropagation();
            commandText = '';
            commandNote = null;
          }
        }}
        class="w-72 max-w-full shrink-0 border border-[var(--color-border)] bg-[var(--color-surface)] px-2 py-1 font-[family-name:var(--font-mono)] text-xs focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
      />
      <span
        id="fredpd-command-note"
        aria-live="polite"
        class="min-w-0 flex-1 text-xs"
        class:text-[var(--color-alert)]={commandNote?.error}
        class:text-[var(--color-ink-muted)]={!commandNote?.error}
      >
        {commandNote?.text ?? ''}
      </span>
    </form>
  {/if}

  <div class="flex min-h-0 flex-1">
    <!-- Module rail: only what this session is permitted to open. The server
         decides the list; the UI just draws it (invariant 4). Sized and
         weighted for a reader who has never used this screen before: a
         visible left bar and tint mark where you are, not font-weight alone. -->
    <nav class="w-48 shrink-0 overflow-y-auto border-r border-[var(--color-border)] p-2">
      {#each session?.modules ?? [] as module (module)}
        <button
          type="button"
          class="mb-0.5 block w-full border-l-2 border-transparent px-3 py-2 text-left text-sm hover:bg-[var(--color-surface)]"
          class:font-semibold={current === module}
          class:border-[var(--color-accent)]={current === module}
          class:bg-[var(--color-surface)]={current === module}
          aria-current={current === module ? 'page' : undefined}
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
      {:else if session && current === 'overview'}
        <Overview
          {session}
          onOpenModule={(module) => {
            if (session?.modules.includes(module)) current = module;
          }}
        />
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
