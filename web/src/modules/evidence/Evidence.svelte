<script module lang="ts">
  import { nui } from '../../lib/nui';

  /**
   * The placement this interface was opened from (spec 3.10, ADR-006).
   *
   * `evidence.intake` carries `context = { accessPoint = 'property_terminal' }`,
   * so the call has to name the terminal it is being made at; the server then
   * checks the officer is genuinely standing at that placement before the
   * handler runs. The id is a *claim*, never a grant — naming a terminal you
   * are not at is refused on the server (invariant 4). Without it every accept
   * and every reject came back as `context`.
   *
   * It is captured in module scope rather than in the component because the
   * game pushes `fredpd:open` once, at the moment the terminal is opened, while
   * this page exists only while the evidence module is the one on screen. An
   * officer who opens the property terminal and then picks Evidence off the
   * rail would mount after the message and never see it. The module is
   * evaluated when the shell is imported, so the handler is registered before
   * the first message can arrive.
   */
  let openedAt: number | null = null;

  nui.on('fredpd:open', (message) => {
    openedAt = typeof message['placementId'] === 'number' ? message['placementId'] : null;
  });

  // Closing the interface ends the visit. The next call has to carry the
  // terminal it was actually made at, not the one from last time.
  nui.on('fredpd:close', () => {
    openedAt = null;
  });
</script>

<script lang="ts">
  import { t } from '../../lib/i18n';
  import {
    EVIDENCE_DESTINATIONS,
    EVIDENCE_PACKAGING,
    EVIDENCE_STATUSES,
    EVIDENCE_TYPES,
    LAB_ANALYSES,
    LAB_PRIORITIES,
    SCENE_STATUSES,
  } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import type { CustodyEntry, EvidenceItem, PendingTrace, Scene } from './types';
  import type { LabAnalysis } from '../lab/types';

  /**
   * Evidence and property room (spec 8.4-8.6).
   *
   * Two views: the items, and the scenes they came from. An item opens into the
   * record a property clerk actually works from — what it is, where it is, the
   * chain of custody behind it, and the analyses queued on it.
   *
   * Every action here is an intent. The server decides whether it happens: the
   * transfer table, the storage location, the seal and the custody signature are
   * all its business, and a refusal is drawn as a refusal rather than prevented
   * by greying the button out (invariant 4). That is also why no form is hidden
   * by permission — nothing on this screen knows what the session may do, and
   * guessing would only produce a second, wrong, access control.
   */

  type Tab = 'items' | 'scenes';

  /** Which form's label a rejected field belongs to. */
  const FIELD_LABELS: Record<string, string> = {
    // The terminal the intake is being made at. A refusal here reads as the
    // property room counter, because that is the thing the officer is standing
    // at when it happens.
    placementId: 'placement.property_terminal',
    search: 'evidence.filter.search',
    traceKey: 'evidence.collect.trace',
    storageLocation: 'evidence.intake.storage',
    reason: 'evidence.transfer.reason',
    destination: 'evidence.transfer.destination',
    toParty: 'evidence.transfer.toParty',
    packaging: 'evidence.collect.packaging',
    markerNumber: 'evidence.collect.marker',
    description: 'evidence.column.description',
    caseNumber: 'evidence.column.case',
    sceneId: 'evidence.scene.number',
    analyses: 'evidence.labRequest.analyses',
    evidenceIds: 'evidence.labRequest.items',
    priority: 'evidence.labRequest.priority',
    status: 'evidence.column.status',
    radius: 'evidence.scene.radius',
  };

  let tab = $state<Tab>('items');

  // ------------------------------------------------------------------- items

  let items = $state<EvidenceItem[]>([]);
  let applied = $state({ status: '', type: '', search: '' });
  let query = $state({ status: '', type: '', search: '' });

  let selectedId = $state<number | null>(null);
  let item = $state<EvidenceItem | null>(null);
  let analyses = $state<LabAnalysis[]>([]);
  let custody = $state<CustodyEntry[]>([]);

  let failure = $state<Failure | null>(null);
  let loading = $state(true);
  let busy = $state(false);

  // Property room counter (8.6).
  let storageLocation = $state('');
  let intakeReason = $state('');

  // Chain of custody (8.6).
  let destination = $state<string>(EVIDENCE_DESTINATIONS[0]);
  let toParty = $state('');
  let transferReason = $state('');

  // Lab request (8.7), made from the item it concerns.
  let requested = $state<string[]>([]);
  let priority = $state<string>(LAB_PRIORITIES[0]);
  let justification = $state('');

  // ------------------------------------------------------------------ scenes

  let scenes = $state<Scene[]>([]);
  let sceneStatus = $state('');
  let sceneCase = $state('');
  /**
   * `SceneCreate` takes 5 to 500 metres and the table's CHECK caps at 500. The
   * box is bound to those, and holds `null` while it is empty: `bind:value` on
   * a number input yields null for a cleared box, and null on the wire is a
   * silent server-side default rather than a perimeter anybody chose.
   */
  let sceneRadius = $state<number | null>(25);
  let confirmRelease = $state<number | null>(null);

  /**
   * A trace the officer is standing at, pushed by the client when they target
   * one. There is no route that lists traces: the world holds them, the grid
   * holds their truth, and neither is readable from the terminal (8.11). So the
   * collection form exists only while the game says there is something to
   * collect.
   */
  let trace = $state<PendingTrace | null>(null);
  let collectPackaging = $state<string>(EVIDENCE_PACKAGING[0]);
  let markerNumber = $state('');
  let collectDescription = $state('');

  $effect(() =>
    nui.on('fredpd:evidence.trace', (message) => {
      const key = message['traceKey'];
      if (typeof key !== 'string') return;

      trace = {
        traceKey: key,
        type: typeof message['type'] === 'string' && message['type'] !== '' ? message['type'] : null,
        sceneId: typeof message['sceneId'] === 'number' ? message['sceneId'] : null,
      };
    }),
  );

  async function loadItems(): Promise<void> {
    const response = await nui.call<{ items: EvidenceItem[] }>('evidence.list', {
      status: applied.status || undefined,
      type: applied.type || undefined,
      search: applied.search.trim() || undefined,
    });

    if (response.ok) {
      items = response.data.items;
      failure = null;
    } else {
      failure = response;
    }

    loading = false;
  }

  $effect(() => {
    // Reading each filter here is what makes a new search run.
    void applied.status;
    void applied.type;
    void applied.search;
    void loadItems();
  });

  /**
   * The item and its chain, in two calls because they are two reads with two
   * audit entries behind them: looking at an item and reading who has had it
   * are separately logged (invariant 11).
   */
  async function loadDetail(id: number): Promise<void> {
    const [detail, chain] = await Promise.all([
      nui.call<{ item: EvidenceItem; analyses: LabAnalysis[] }>('evidence.get', { id }),
      nui.call<{ custody: CustodyEntry[] }>('evidence.custody', { id }),
    ]);

    if (detail.ok) {
      item = detail.data.item;
      analyses = detail.data.analyses;
      failure = null;
    } else {
      item = null;
      analyses = [];
      failure = detail;
    }

    custody = chain.ok ? chain.data.custody : [];
  }

  $effect(() => {
    const id = selectedId;
    if (id === null) return;

    void loadDetail(id);
  });

  async function loadScenes(): Promise<void> {
    const response = await nui.call<{ scenes: Scene[] }>('scene.list', {
      status: sceneStatus || undefined,
    });

    if (response.ok) {
      scenes = response.data.scenes;
      failure = null;
    } else {
      failure = response;
    }
  }

  $effect(() => {
    if (tab !== 'scenes') return;

    void sceneStatus;
    void loadScenes();
  });

  /** Runs a write, then refreshes whatever it could have changed. */
  async function submit(
    route: string,
    input: Record<string, unknown>,
    after: () => Promise<void>,
  ): Promise<boolean> {
    if (busy) return false;
    busy = true;

    const response = await nui.call(route, input);

    if (response.ok) {
      failure = null;
      await after();
    } else {
      failure = response;
    }

    busy = false;
    return response.ok;
  }

  async function refreshItem(): Promise<void> {
    await loadItems();
    if (selectedId !== null) await loadDetail(selectedId);
  }

  function apply(event: SubmitEvent): void {
    event.preventDefault();
    applied = { ...query };
  }

  async function transfer(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!item) return;

    const done = await submit(
      'evidence.transfer',
      { id: item.id, destination, toParty: toParty.trim() || undefined, reason: transferReason.trim() },
      refreshItem,
    );

    if (done) {
      toParty = '';
      transferReason = '';
    }
  }

  /**
   * Accept or reject at the counter. Both are the same route: a rejection is
   * part of the chain, not the absence of one, and the reason is written where
   * the officer who brought the item can read it (8.6).
   */
  async function intake(accepted: boolean): Promise<void> {
    if (!item) return;

    const done = await submit(
      'evidence.intake',
      {
        // Which property room counter this is. The server checks the officer is
        // standing at it (8.6); sending it is not what makes it true.
        placementId: openedAt ?? undefined,
        id: item.id,
        accepted,
        storageLocation: storageLocation.trim() || undefined,
        reason: intakeReason.trim() || undefined,
      },
      refreshItem,
    );

    if (done) {
      storageLocation = '';
      intakeReason = '';
    }
  }

  async function requestLab(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!item) return;

    const done = await submit(
      'lab.request.create',
      {
        // Strings: the validator has no integer-list type, and the server parses
        // them itself rather than trusting the list.
        evidenceIds: [String(item.id)],
        analyses: requested,
        priority,
        justification: justification.trim() || undefined,
      },
      refreshItem,
    );

    if (done) {
      requested = [];
      justification = '';
    }
  }

  function toggleAnalysis(value: string): void {
    requested = requested.includes(value)
      ? requested.filter((name) => name !== value)
      : [...requested, value];
  }

  async function createScene(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    // No coordinates: the perimeter is where the server says the officer is
    // standing. A scene thrown from the terminal is a scene nobody attended.
    const done = await submit(
      'scene.create',
      {
        caseNumber: sceneCase.trim() || undefined,
        radius: typeof sceneRadius === 'number' ? sceneRadius : undefined,
      },
      loadScenes,
    );

    if (done) sceneCase = '';
  }

  async function releaseScene(id: number): Promise<void> {
    confirmRelease = null;
    await submit('scene.release', { id }, loadScenes);
  }

  async function collect(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!trace) return;

    const marker = Number.parseInt(markerNumber, 10);

    const done = await submit(
      'evidence.collect',
      {
        traceKey: trace.traceKey,
        sceneId: trace.sceneId ?? undefined,
        packaging: collectPackaging,
        markerNumber: Number.isFinite(marker) ? marker : undefined,
        description: collectDescription.trim() || undefined,
      },
      refreshItem,
    );

    if (done) {
      // The grid gave the trace up, so there is nothing left to collect.
      trace = null;
      markerNumber = '';
      collectDescription = '';
    }
  }

  /** Server timestamps arrive as ISO strings; the grid wants minutes. */
  function when(value: string | null): string {
    return value ? value.replace('T', ' ').slice(0, 16) : '';
  }

  const tabs: Tab[] = ['items', 'scenes'];
  const messages = $derived(fieldList(failure, FIELD_LABELS));
</script>

<section class="flex min-h-0 flex-col gap-4">
  <nav class="flex gap-1 border-b border-[var(--color-border)]">
    {#each tabs as name (name)}
      <button
        type="button"
        class="px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
        class:font-semibold={tab === name}
        onclick={() => (tab = name)}
      >
        {t(`evidence.tab.${name}`)}
      </button>
    {/each}
  </nav>

  {#if failure}
    <div class="border border-[var(--color-border)] px-3 py-2 text-sm">
      <p>{t(`error.${failure.err}`)}</p>
      {#if messages.length > 0}
        <ul class="mt-1 text-xs text-[var(--color-ink-muted)]">
          {#each messages as message (message.name)}
            <li>{message.label} — {message.reason}</li>
          {/each}
        </ul>
      {/if}
    </div>
  {/if}

  <!-- Collection (8.4). Only here while the game says the officer is standing
       at a revealed trace: the terminal cannot list what is in the world. -->
  {#if trace}
    <form class="flex flex-wrap items-end gap-3 border border-[var(--color-border)] p-3" onsubmit={collect}>
      <p class="w-full text-xs">
        {t('evidence.collect.title')}
        {#if trace.type}
          <span class="text-[var(--color-ink-muted)]">{t(`evidence.type.${trace.type}`)}</span>
        {/if}
      </p>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('evidence.collect.packaging')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={collectPackaging}
        >
          {#each EVIDENCE_PACKAGING as value (value)}
            <option {value}>{t(`evidence.packaging.${value}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('evidence.collect.marker')}</span>
        <input
          class="w-20 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={markerNumber}
          inputmode="numeric"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('evidence.column.description')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={collectDescription}
        />
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
        disabled={busy}
      >
        {t('evidence.collect.submit')}
      </button>
    </form>
  {/if}

  {#if tab === 'items'}
    <form class="flex flex-wrap items-end gap-3" onsubmit={apply}>
      <label class="flex flex-col gap-1 text-xs">
        <span>{t('evidence.filter.status')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={query.status}
        >
          <option value="">{t('evidence.filter.any')}</option>
          {#each EVIDENCE_STATUSES as value (value)}
            <option {value}>{t(`evidence.status.${value}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('evidence.filter.type')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={query.type}
        >
          <option value="">{t('evidence.filter.any')}</option>
          {#each EVIDENCE_TYPES as value (value)}
            <option {value}>{t(`evidence.type.${value}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('evidence.filter.search')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={query.search}
          maxlength="64"
          placeholder={t('evidence.filter.searchPlaceholder')}
        />
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
      >
        {t('evidence.filter.apply')}
      </button>
    </form>

    {#if loading}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
    {:else}
      <div class="overflow-x-auto border border-[var(--color-border)]">
        <table class="w-full border-collapse text-xs">
          <thead>
            <tr class="border-b border-[var(--color-border)] text-left">
              <th class="px-3 py-2 font-semibold">{t('evidence.column.number')}</th>
              <th class="px-3 py-2 font-semibold">{t('evidence.column.type')}</th>
              <th class="px-3 py-2 font-semibold">{t('evidence.column.packaging')}</th>
              <th class="px-3 py-2 font-semibold">{t('evidence.column.seal')}</th>
              <th class="px-3 py-2 font-semibold">{t('evidence.column.status')}</th>
              <th class="px-3 py-2 font-semibold">{t('evidence.column.storage')}</th>
              <th class="px-3 py-2 font-semibold">{t('evidence.column.case')}</th>
              <th class="px-3 py-2 font-semibold">{t('evidence.column.collected')}</th>
            </tr>
          </thead>
          <tbody>
            {#each items as row (row.id)}
              <tr class="border-b border-[var(--color-border)] last:border-b-0">
                <td class="px-3 py-2">
                  <button
                    type="button"
                    class="font-[family-name:var(--font-mono)] underline-offset-2 hover:underline"
                    class:font-semibold={selectedId === row.id}
                    onclick={() => (selectedId = row.id)}
                  >
                    {row.evidenceNumber}
                  </button>
                </td>
                <td class="px-3 py-2">{t(`evidence.type.${row.type}`)}</td>
                <td class="px-3 py-2">
                  {row.packaging ? t(`evidence.packaging.${row.packaging}`) : ''}
                </td>
                <td class="px-3 py-2">{t(`evidence.seal.${row.sealState}`)}</td>
                <td class="px-3 py-2">{t(`evidence.status.${row.status}`)}</td>
                <td class="px-3 py-2">{row.storageLocation ?? ''}</td>
                <td class="px-3 py-2 font-[family-name:var(--font-mono)]">{row.caseNumber ?? ''}</td>
                <td class="px-3 py-2">{when(row.collectedAt)}</td>
              </tr>
            {:else}
              <tr>
                <td class="px-3 py-3 text-[var(--color-ink-muted)]" colspan="8">
                  {t('evidence.empty')}
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}

    {#if item}
      <article class="flex flex-col gap-4 border border-[var(--color-border)] p-3">
        <header class="flex flex-wrap items-baseline justify-between gap-3">
          <h2 class="text-sm font-semibold font-[family-name:var(--font-mono)]">
            {item.evidenceNumber}
          </h2>
          <span class="text-xs text-[var(--color-ink-muted)]">
            {t(`evidence.status.${item.status}`)}
          </span>
        </header>

        <dl class="grid grid-cols-2 gap-x-6 gap-y-1 text-xs md:grid-cols-4">
          <dt class="text-[var(--color-ink-muted)]">{t('evidence.column.type')}</dt>
          <dd>{t(`evidence.type.${item.type}`)}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('evidence.column.packaging')}</dt>
          <dd>{item.packaging ? t(`evidence.packaging.${item.packaging}`) : ''}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('evidence.column.seal')}</dt>
          <dd>{t(`evidence.seal.${item.sealState}`)}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('evidence.column.marker')}</dt>
          <dd class="font-[family-name:var(--font-mono)]">{item.markerNumber ?? ''}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('evidence.column.case')}</dt>
          <dd class="font-[family-name:var(--font-mono)]">{item.caseNumber ?? ''}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('evidence.column.storage')}</dt>
          <dd>{item.storageLocation ?? ''}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('evidence.column.collected')}</dt>
          <dd>{when(item.collectedAt)}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('evidence.column.ref')}</dt>
          <dd class="font-[family-name:var(--font-mono)]">{item.ref}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('evidence.column.description')}</dt>
          <dd class="col-span-3">{item.description ?? ''}</dd>
        </dl>

        <!-- Chain of custody. Append-only on the server; read-only here. -->
        <div>
          <h3 class="text-xs font-semibold">{t('evidence.custody.title')}</h3>
          <div class="mt-1 overflow-x-auto border border-[var(--color-border)]">
            <table class="w-full border-collapse text-xs">
              <thead>
                <tr class="border-b border-[var(--color-border)] text-left">
                  <th class="px-3 py-2 font-semibold">{t('evidence.custody.time')}</th>
                  <th class="px-3 py-2 font-semibold">{t('evidence.custody.action')}</th>
                  <th class="px-3 py-2 font-semibold">{t('evidence.custody.from')}</th>
                  <th class="px-3 py-2 font-semibold">{t('evidence.custody.to')}</th>
                  <th class="px-3 py-2 font-semibold">{t('evidence.custody.reason')}</th>
                  <th class="px-3 py-2 font-semibold">{t('evidence.custody.signedBy')}</th>
                </tr>
              </thead>
              <tbody>
                {#each custody as entry (entry.id)}
                  <tr class="border-b border-[var(--color-border)] last:border-b-0">
                    <td class="px-3 py-2">{when(entry.occurredAt)}</td>
                    <td class="px-3 py-2">{t(`evidence.custodyAction.${entry.action}`)}</td>
                    <td class="px-3 py-2">{entry.fromParty ?? ''}</td>
                    <td class="px-3 py-2">{entry.toParty ?? ''}</td>
                    <td class="px-3 py-2">{entry.reason ?? ''}</td>
                    <td class="px-3 py-2 font-[family-name:var(--font-mono)]">{entry.signedBy}</td>
                  </tr>
                {:else}
                  <tr>
                    <td class="px-3 py-3 text-[var(--color-ink-muted)]" colspan="6">
                      {t('evidence.custody.empty')}
                    </td>
                  </tr>
                {/each}
              </tbody>
            </table>
          </div>
        </div>

        <!-- Analyses queued on this item. What they found is withheld from a
             reader without a lab permission, and the server simply does not
             send it (8.11) -- so an empty result column is the access control
             working, not a gap in the screen. -->
        <div>
          <h3 class="text-xs font-semibold">{t('evidence.analyses.title')}</h3>
          <div class="mt-1 overflow-x-auto border border-[var(--color-border)]">
            <table class="w-full border-collapse text-xs">
              <thead>
                <tr class="border-b border-[var(--color-border)] text-left">
                  <th class="px-3 py-2 font-semibold">{t('lab.column.analysis')}</th>
                  <th class="px-3 py-2 font-semibold">{t('lab.column.priority')}</th>
                  <th class="px-3 py-2 font-semibold">{t('lab.column.status')}</th>
                  <th class="px-3 py-2 font-semibold">{t('lab.column.due')}</th>
                  <th class="px-3 py-2 font-semibold">{t('lab.column.result')}</th>
                </tr>
              </thead>
              <tbody>
                {#each analyses as analysis (analysis.id)}
                  <tr class="border-b border-[var(--color-border)] last:border-b-0">
                    <td class="px-3 py-2">{t(`lab.analysis.${analysis.analysis}`)}</td>
                    <td class="px-3 py-2">{t(`lab.priority.${analysis.priority}`)}</td>
                    <td class="px-3 py-2">{t(`lab.status.${analysis.status}`)}</td>
                    <td class="px-3 py-2">{when(analysis.dueAt)}</td>
                    <td class="px-3 py-2">
                      {analysis.resultCode ? t(`lab.result.${analysis.resultCode}`) : ''}
                    </td>
                  </tr>
                {:else}
                  <tr>
                    <td class="px-3 py-3 text-[var(--color-ink-muted)]" colspan="5">
                      {t('evidence.analyses.empty')}
                    </td>
                  </tr>
                {/each}
              </tbody>
            </table>
          </div>
        </div>

        <!-- Property room intake (8.6). Two outcomes, one route. -->
        <div class="flex flex-wrap items-end gap-3 border-t border-[var(--color-border)] pt-3">
          <p class="w-full text-xs font-semibold">{t('evidence.intake.title')}</p>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('evidence.intake.storage')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={storageLocation}
              placeholder={t('evidence.intake.storagePlaceholder')}
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('evidence.intake.reason')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={intakeReason}
            />
          </label>

          <button
            type="button"
            class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
            disabled={busy}
            onclick={() => intake(true)}
          >
            {t('evidence.intake.accept')}
          </button>

          <button
            type="button"
            class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
            disabled={busy}
            onclick={() => intake(false)}
          >
            {t('evidence.intake.reject')}
          </button>
        </div>

        <form
          class="flex flex-wrap items-end gap-3 border-t border-[var(--color-border)] pt-3"
          onsubmit={transfer}
        >
          <p class="w-full text-xs font-semibold">{t('evidence.transfer.title')}</p>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('evidence.transfer.destination')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={destination}
            >
              {#each EVIDENCE_DESTINATIONS as value (value)}
                <option {value}>{t(`evidence.destination.${value}`)}</option>
              {/each}
            </select>
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('evidence.transfer.toParty')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={toParty}
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('evidence.transfer.reason')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={transferReason}
              required
            />
          </label>

          <button
            type="submit"
            class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
            disabled={busy}
          >
            {t('evidence.transfer.submit')}
          </button>
        </form>

        <form
          class="flex flex-col gap-2 border-t border-[var(--color-border)] pt-3"
          onsubmit={requestLab}
        >
          <p class="text-xs font-semibold">{t('evidence.labRequest.title')}</p>

          <fieldset class="flex flex-wrap gap-3 text-xs">
            <legend class="mb-1">{t('evidence.labRequest.analyses')}</legend>
            {#each LAB_ANALYSES as value (value)}
              <label class="flex items-center gap-1.5">
                <input
                  type="checkbox"
                  checked={requested.includes(value)}
                  onchange={() => toggleAnalysis(value)}
                />
                <span>{t(`lab.analysis.${value}`)}</span>
              </label>
            {/each}
          </fieldset>

          <div class="flex flex-wrap items-end gap-3">
            <label class="flex flex-col gap-1 text-xs">
              <span>{t('evidence.labRequest.priority')}</span>
              <select
                class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
                bind:value={priority}
              >
                {#each LAB_PRIORITIES as value (value)}
                  <option {value}>{t(`lab.priority.${value}`)}</option>
                {/each}
              </select>
            </label>

            <label class="flex flex-col gap-1 text-xs">
              <span>{t('evidence.labRequest.justification')}</span>
              <input
                class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
                bind:value={justification}
              />
            </label>

            <button
              type="submit"
              class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
              disabled={busy}
            >
              {t('evidence.labRequest.submit')}
            </button>
          </div>
        </form>
      </article>
    {:else if !loading && items.length > 0}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('evidence.detail.none')}</p>
    {/if}
  {:else}
    <!-- Scenes (8.4) -->
    <div class="flex flex-wrap items-end gap-3">
      <label class="flex flex-col gap-1 text-xs">
        <span>{t('evidence.filter.status')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={sceneStatus}
        >
          <option value="">{t('evidence.filter.any')}</option>
          {#each SCENE_STATUSES as value (value)}
            <option {value}>{t(`evidence.scene.status.${value}`)}</option>
          {/each}
        </select>
      </label>
    </div>

    <div class="overflow-x-auto border border-[var(--color-border)]">
      <table class="w-full border-collapse text-xs">
        <thead>
          <tr class="border-b border-[var(--color-border)] text-left">
            <th class="px-3 py-2 font-semibold">{t('evidence.scene.number')}</th>
            <th class="px-3 py-2 font-semibold">{t('evidence.column.case')}</th>
            <th class="px-3 py-2 font-semibold">{t('evidence.column.status')}</th>
            <th class="px-3 py-2 font-semibold">{t('evidence.scene.items')}</th>
            <th class="px-3 py-2 font-semibold">{t('evidence.scene.entries')}</th>
            <th class="px-3 py-2 font-semibold">{t('evidence.scene.opened')}</th>
            <th class="px-3 py-2"></th>
          </tr>
        </thead>
        <tbody>
          {#each scenes as scene (scene.id)}
            <tr class="border-b border-[var(--color-border)] last:border-b-0">
              <td class="px-3 py-2 font-[family-name:var(--font-mono)]">{scene.sceneNumber}</td>
              <td class="px-3 py-2 font-[family-name:var(--font-mono)]">{scene.caseNumber ?? ''}</td>
              <td class="px-3 py-2">{t(`evidence.scene.status.${scene.status}`)}</td>
              <td class="px-3 py-2">{scene.evidenceCount ?? 0}</td>
              <td class="px-3 py-2">{scene.entryCount ?? 0}</td>
              <td class="px-3 py-2">{when(scene.createdAt)}</td>
              <td class="px-3 py-2 text-right">
                {#if confirmRelease === scene.id}
                  <!-- Releasing the perimeter ends the only window in which the
                       scene can be worked, so it asks first (spec 6.4). -->
                  <span class="mr-2 text-[var(--color-ink-muted)]">
                    {t('evidence.scene.releaseConfirm')}
                  </span>
                  <button
                    type="button"
                    class="border border-[var(--color-border)] px-2 py-1 hover:bg-[var(--color-surface)]"
                    disabled={busy}
                    onclick={() => releaseScene(scene.id)}
                  >
                    {t('evidence.scene.release')}
                  </button>
                  <button
                    type="button"
                    class="ml-1 border border-[var(--color-border)] px-2 py-1 hover:bg-[var(--color-surface)]"
                    onclick={() => (confirmRelease = null)}
                  >
                    {t('form.cancel')}
                  </button>
                {:else if scene.status === 'open'}
                  <button
                    type="button"
                    class="border border-[var(--color-border)] px-2 py-1 hover:bg-[var(--color-surface)]"
                    onclick={() => (confirmRelease = scene.id)}
                  >
                    {t('evidence.scene.release')}
                  </button>
                {/if}
              </td>
            </tr>
          {:else}
            <tr>
              <td class="px-3 py-3 text-[var(--color-ink-muted)]" colspan="7">
                {t('evidence.scene.empty')}
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>

    <form class="flex flex-wrap items-end gap-3" onsubmit={createScene}>
      <p class="w-full text-xs text-[var(--color-ink-muted)]">{t('evidence.scene.createIntro')}</p>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('evidence.column.case')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={sceneCase}
          maxlength="32"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('evidence.scene.radius')}</span>
        <input
          class="w-24 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          type="number"
          min="5"
          max="500"
          step="0.5"
          bind:value={sceneRadius}
        />
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
        disabled={busy}
      >
        {t('evidence.scene.create')}
      </button>
    </form>
  {/if}
</section>
