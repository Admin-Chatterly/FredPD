<script lang="ts" module>
  import { nui as bridge } from '../../lib/nui';

  /**
   * The terminal the MDT was opened at: live view is watched from a station
   * terminal or the dispatch console, and the server checks the officer is
   * standing at it.
   */
  let openedAt: number | null = null;

  bridge.on('fredpd:open', (message) => {
    openedAt = typeof message['placementId'] === 'number' ? message['placementId'] : null;
  });

  bridge.on('fredpd:close', () => {
    openedAt = null;
  });
</script>

<script lang="ts">
  import { tick } from 'svelte';
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { uploadImage } from '../../lib/photo';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import LoadMore from '../shared/LoadMore.svelte';
  import { FOOTAGE_SOURCES, FOOTAGE_STATUSES, type FootageSource, type FootageStatus } from '@fredpd/schema';

  /**
   * Cameras (spec 7.19): live view through CCTV, body-worn and dash cameras,
   * and the footage request -- ask to look through one camera for a window,
   * a supervisor approves, and the requester keeps one still as evidence.
   *
   * What may be watched is the server's answer (`camera.sources`,
   * `camera.view.start`); this draws it. Live view itself is the game's
   * (client/camera.lua): the MDT hides while it runs, and a still taken there
   * comes back here to be uploaded and kept.
   */

  interface Sources {
    cameras: { id: number }[];
    bodycams: { officerId: number; callsign?: string | null }[];
    dashcams: { officerId: number; callsign?: string | null }[];
    mayView: boolean;
  }

  interface FootageRequest {
    id: number;
    number: string;
    source: FootageSource;
    cameraId?: number | null;
    officerId?: number | null;
    officerCallsign?: string | null;
    windowFrom: number;
    windowTo: number;
    reason: string;
    status: FootageStatus;
    requestedAt: number;
    decisionNote?: string | null;
    stillThumbUrl?: string | null;
    stillUrl?: string | null;
    version: number;
    mine: boolean;
  }

  const FIELD_LABELS: Record<string, string> = {
    source: 'camera.form.source',
    cameraId: 'camera.form.camera',
    officerId: 'camera.form.officer',
    windowFrom: 'camera.form.from',
    windowTo: 'camera.form.to',
    reason: 'camera.form.reason',
    fuId: 'camera.form.fu',
    placementId: 'camera.live.title',
    requestId: 'camera.requests.still',
    mediaRef: 'camera.requests.still',
    note: 'camera.requests.note',
    version: 'camera.requests.title',
    id: 'camera.requests.title',
  };

  /** Whether the MDT is open at a terminal, drawn: the module variable is the
   *  value at open, kept current here. */
  let atTerminal = $state(openedAt !== null);
  $effect(() => nui.on('fredpd:open', (message) => (atTerminal = typeof message['placementId'] === 'number')));

  let sources = $state<Sources | null>(null);
  /** Why the camera list was refused, drawn rather than an empty section. */
  let sourcesFailure = $state<Failure | null>(null);
  /** Investigations this officer may read, to tie a request to (none when they may not list them). */
  let investigations = $state<{ id: number; number: string }[]>([]);
  let requests = $state<FootageRequest[]>([]);
  let mayApprove = $state(false);
  let nextCursor = $state<string | null>(null);
  let loadingMore = $state(false);
  /** The list's filter: an approver starts on what waits for them, once. */
  let statusFilter = $state<FootageStatus | ''>('');
  let filterChosen = false;
  /** The request whose still is drawn full size. */
  let enlargedStill = $state<number | null>(null);
  /** Requests whose signed still link failed to load. */
  let brokenStills = $state<number[]>([]);
  let failure = $state<Failure | null>(null);
  let status = $state('');
  let busy = $state(false);
  let statusLine = $state<HTMLParagraphElement | null>(null);

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  // A request form, defaulting to the next two hours.
  const nowLocal = (offsetHours: number): string => {
    const minute = Math.floor((Date.now() + offsetHours * 3600_000) / 60_000) * 60_000;
    const offset = new Date(minute).getTimezoneOffset() * 60_000;
    return new Date(minute - offset).toISOString().slice(0, 16);
  };
  let form = $state({
    source: 'cctv' as FootageSource,
    target: '',
    from: nowLocal(0),
    to: nowLocal(2),
    reason: '',
    fuId: '',
  });

  /** The decision being confirmed. */
  let pending = $state<{ request: FootageRequest; approve: boolean } | null>(null);
  let note = $state('');
  let trigger: HTMLButtonElement | null = null;

  async function loadSources(): Promise<void> {
    const response = await nui.call<Sources>('camera.sources', openedAt ? { placementId: openedAt } : {});
    sources = response.ok ? response.data : null;
    sourcesFailure = response.ok ? null : response;
  }

  type RequestPage = { requests: FootageRequest[]; mayApprove: boolean; nextCursor?: string | null };

  /** The first page again, or -- given a cursor -- the next one after it. */
  async function loadRequests(cursor?: string): Promise<void> {
    const response = await nui.call<RequestPage>('camera.footage.list', {
      ...(statusFilter ? { status: statusFilter } : {}),
      ...(cursor ? { cursor } : {}),
    });
    if (!response.ok) {
      failure = response;
      return;
    }

    requests = cursor ? [...requests, ...response.data.requests] : response.data.requests;
    mayApprove = response.data.mayApprove;
    nextCursor = response.data.nextCursor ?? null;

    // Whoever decides requests opens on the ones waiting for a decision.
    if (!filterChosen && !cursor) {
      filterChosen = true;
      if (mayApprove) {
        statusFilter = 'requested';
        await loadRequests();
      }
    }
  }

  async function loadMore(): Promise<void> {
    if (!nextCursor || loadingMore) return;
    loadingMore = true;
    await loadRequests(nextCursor);
    loadingMore = false;
  }

  function filterChanged(): void {
    filterChosen = true;
    enlargedStill = null;
    void loadRequests();
  }

  async function loadInvestigations(): Promise<void> {
    const response = await nui.call<{ forundersokningar: { id?: number; number?: string; restricted?: boolean }[] }>(
      'fu.list',
      { limit: 100 },
    );
    investigations = response.ok
      ? response.data.forundersokningar.flatMap((row) =>
          row.restricted || row.id === undefined || !row.number ? [] : [{ id: row.id, number: row.number }],
        )
      : [];
  }

  void loadSources();
  void loadRequests();
  void loadInvestigations();

  async function announce(text: string): Promise<void> {
    status = text;
    await tick();
    statusLine?.focus();
  }

  async function watch(source: FootageSource, target: { cameraId?: number; officerId?: number }): Promise<void> {
    if (busy) return;
    busy = true;
    failure = null;
    status = '';

    const response = await nui.call<{ source: FootageSource; requestId?: number; position?: unknown }>(
      'camera.view.start',
      { placementId: openedAt ?? 0, source, ...target },
    );

    if (response.ok) {
      // The game takes it from here; the MDT hides until the view ends. If
      // the game refuses (a view already open), the server's view is ended
      // too, so no view is kept -- and audited -- that nobody sees.
      const opened = await nui.call('fredpd:cameraOpen', response.data);
      if (!opened.ok) {
        await nui.call('camera.view.stop', {});
        failure = opened;
        status = t('camera.openFailed');
      }
    } else {
      failure = response;
    }

    busy = false;
  }

  /** A still taken in the view comes back here to be uploaded and kept. */
  $effect(() =>
    nui.on('fredpd:cameraStill', (message) => {
      const requestId = Number(message['requestId']);
      const image = message['image'];
      if (!Number.isInteger(requestId) || typeof image !== 'string') return;
      void keepStill(requestId, image);
    }),
  );

  async function keepStill(requestId: number, image: string): Promise<void> {
    const begun = await nui.call<{ mediaRef: string; uploadUrl: string }>('camera.still.begin', { requestId });
    if (!begun.ok) {
      failure = begun;
      return;
    }

    const refused = await uploadImage(begun.data.uploadUrl, image);
    if (refused && !refused.ok) {
      failure = refused;
      return;
    }

    const committed = await nui.call<{ number: string }>('camera.still.commit', {
      requestId,
      mediaRef: begun.data.mediaRef,
    });
    if (!committed.ok) {
      failure = committed;
      return;
    }

    failure = null;
    status = t('camera.still.kept', { number: committed.data.number });
    await loadRequests();
  }

  /** A signed still link that no longer loads (it expires): said, not a broken image. */
  function stillFailed(id: number): void {
    if (!brokenStills.includes(id)) brokenStills = [...brokenStills, id];
    if (enlargedStill === id) enlargedStill = null;
  }

  function toEpoch(value: string): number {
    return Math.floor(new Date(value).getTime() / 1000);
  }

  async function request(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy) return;
    busy = true;
    failure = null;

    const target = Number(form.target);
    const response = await nui.call<{ number: string }>('camera.footage.request', {
      source: form.source,
      ...(form.source === 'cctv' ? { cameraId: target || undefined } : { officerId: target || undefined }),
      windowFrom: toEpoch(form.from),
      windowTo: toEpoch(form.to),
      reason: form.reason,
      ...(Number(form.fuId) > 0 ? { fuId: Number(form.fuId) } : {}),
    });

    busy = false;

    if (!response.ok) {
      failure = response;
      return;
    }

    form.reason = '';
    form.fuId = '';
    await loadRequests();
    await announce(t('camera.form.sent', { number: response.data.number }));
  }

  function ask(requestRow: FootageRequest, approve: boolean, event: MouseEvent): void {
    trigger = event.currentTarget as HTMLButtonElement;
    failure = null;
    note = '';
    pending = { request: requestRow, approve };
  }

  async function cancel(): Promise<void> {
    pending = null;
    failure = null;
    await tick();
    trigger?.focus();
  }

  async function decide(): Promise<void> {
    if (!pending || busy) return;
    busy = true;

    const response = await nui.call<{ number: string }>('camera.footage.decide', {
      id: pending.request.id,
      version: pending.request.version,
      approve: pending.approve,
      ...(note.trim() ? { note: note.trim() } : {}),
    });

    busy = false;

    if (!response.ok) {
      failure = response;
      return;
    }

    const approved = pending.approve;
    pending = null;
    await loadRequests();
    await announce(t(approved ? 'camera.requests.approved' : 'camera.requests.denied', { number: response.data.number }));
  }

  function cctvName(id: number | null | undefined): string {
    return t('camera.cctvName', { id: id ?? '' });
  }

  function describe(row: FootageRequest): string {
    if (row.source === 'cctv') return cctvName(row.cameraId);
    return `${t(`camera.source.${row.source}`)} ${row.officerCallsign ?? ''}`.trim();
  }

  /** Esc leaves the form alone (the MDT's own Esc closes it); Ctrl+Enter sends. */
  function formKeys(event: KeyboardEvent): void {
    if (event.key === 'Enter' && event.ctrlKey) {
      event.preventDefault();
      (event.currentTarget as HTMLFormElement).requestSubmit();
    }
  }

  const REQUIRED_MARK = '*';

  const targets = $derived.by(() => {
    if (!sources) return [];
    if (form.source === 'cctv') return sources.cameras.map((camera) => ({ value: camera.id, label: cctvName(camera.id) }));
    const list = form.source === 'bodycam' ? sources.bodycams : sources.dashcams;
    return list.map((entry) => ({ value: entry.officerId, label: entry.callsign ?? String(entry.officerId) }));
  });

  const control =
    'border border-[var(--color-border)] px-2 py-1 focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]';
  const button = `${control} px-3`;
</script>

<div class="flex flex-col gap-4 text-xs">
  {#if status}
    <p
      bind:this={statusLine}
      tabindex="-1"
      class="text-[var(--color-ink-muted)] outline-offset-2 focus-visible:outline focus-visible:outline-[var(--color-focus)]"
      role="status"
    >
      {status}
    </p>
  {/if}
  {#if failure && !pending}
    <div class="border border-[var(--color-alert)] px-2 py-1" role="alert">
      <p>{t(`error.${failure.err}`)}</p>
      {#each messages as message (message.name)}
        <p class="text-[var(--color-ink-muted)]">{message.label} — {message.reason}</p>
      {/each}
    </div>
  {/if}

  <section aria-labelledby="camera-live-title">
    <h2 id="camera-live-title" class="mb-1 text-[15px] font-semibold">{t('camera.live.title')}</h2>
    {#if !atTerminal}
      <p class="mb-2 text-[var(--color-ink-muted)]">{t('camera.live.atTerminal')}</p>
    {/if}
    {#if sources && !sources.mayView}
      <p class="mb-2 text-[var(--color-ink-muted)]">{t('camera.live.byRequest')}</p>
    {/if}
    {#if sourcesFailure}
      <p class="mb-2">{t('camera.live.refused')} {t(`error.${sourcesFailure.err}`)}</p>
    {/if}

    {#if sources}
      <div class="grid gap-3 md:grid-cols-3">
        {#each [['cameras', 'cctv'], ['bodycams', 'bodycam'], ['dashcams', 'dashcam']] as const as [group, source] (group)}
          <div>
            <h3 class="mb-1 font-semibold">{t(`camera.live.${group}`)}</h3>
            {#if sources[group].length === 0}
              <p class="text-[var(--color-ink-muted)]">{t('camera.live.none')}</p>
            {:else}
              <ul>
                {#each sources[group] as entry (source === 'cctv' ? `c${'id' in entry ? entry.id : 0}` : `o${'officerId' in entry ? entry.officerId : 0}`)}
                  {@const label = 'id' in entry ? cctvName(entry.id) : (entry.callsign ?? String(entry.officerId))}
                  <li class="flex items-center justify-between gap-2 border-t border-[var(--color-border)] py-1">
                    <span>{label}</span>
                    <button
                      type="button"
                      class={button}
                      aria-label={t('camera.live.watchLabel', { label })}
                      onclick={() =>
                        void watch(source, 'id' in entry ? { cameraId: entry.id } : { officerId: entry.officerId })}
                    >
                      {t('camera.live.watch')}
                    </button>
                  </li>
                {/each}
              </ul>
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  </section>

  <section aria-labelledby="camera-requests-title">
    <div class="mb-1 flex items-end justify-between gap-2">
      <h2 id="camera-requests-title" class="text-[15px] font-semibold">{t('camera.requests.title')}</h2>
      <label class="flex items-center gap-1">
        {t('camera.requests.filter')}
        <select bind:value={statusFilter} class={control} onchange={filterChanged}>
          {#each FOOTAGE_STATUSES as value (value)}
            <option {value}>{t(`camera.status.${value}`)}</option>
          {/each}
          <option value="">{t('camera.requests.all')}</option>
        </select>
      </label>
    </div>
    {#if requests.length === 0}
      <p class="text-[var(--color-ink-muted)]">{t('camera.requests.none')}</p>
    {:else}
      <div class="overflow-x-auto">
        <table class="w-full text-left text-[12.5px] tabular-nums">
          <thead>
            <tr class="text-[var(--color-ink-muted)]">
              <th class="px-2 py-1 font-normal">{t('camera.requests.number')}</th>
              <th class="px-2 py-1 font-normal">{t('camera.requests.source')}</th>
              <th class="px-2 py-1 font-normal">{t('camera.requests.window')}</th>
              <th class="px-2 py-1 font-normal">{t('camera.requests.status')}</th>
              <th class="px-2 py-1 font-normal">{t('camera.requests.still')}</th>
              <th class="px-2 py-1 font-normal"><span class="sr-only">{t('camera.requests.decision')}</span></th>
            </tr>
          </thead>
          <tbody>
            {#each requests as row (row.id)}
              <tr class="border-t border-[var(--color-border)] align-top">
                <td class="px-2 py-1 font-[family-name:var(--font-mono)]">{row.number}</td>
                <td class="px-2 py-1">
                  {describe(row)}
                  <p class="text-[var(--color-ink-muted)]">{row.reason}</p>
                </td>
                <td class="px-2 py-1">{formatMoment(row.windowFrom)} – {formatMoment(row.windowTo)}</td>
                <td class="px-2 py-1">
                  {t(`camera.status.${row.status}`)}
                  {#if row.decisionNote}<p class="text-[var(--color-ink-muted)]">{row.decisionNote}</p>{/if}
                </td>
                <td class="px-2 py-1">
                  {#if row.stillThumbUrl && brokenStills.includes(row.id)}
                    <p class="text-[var(--color-ink-muted)]">{t('camera.requests.stillGone')}</p>
                  {:else if row.stillThumbUrl}
                    <button
                      type="button"
                      class="block focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
                      aria-expanded={enlargedStill === row.id}
                      aria-controls={`footage-still-${row.id}`}
                      aria-label={t(enlargedStill === row.id ? 'camera.requests.hideStill' : 'camera.requests.showStill', {
                        number: row.number,
                      })}
                      onclick={() => (enlargedStill = enlargedStill === row.id ? null : row.id)}
                    >
                      <img
                        src={row.stillThumbUrl}
                        alt={t('camera.requests.stillAlt', { number: row.number })}
                        loading="lazy"
                        class="h-12 border border-[var(--color-border)]"
                        onerror={() => stillFailed(row.id)}
                      />
                    </button>
                  {/if}
                </td>
                <td class="px-2 py-1">
                  {#if mayApprove && !row.mine && row.status === 'requested'}
                    <div class="flex gap-1">
                      <button
                        type="button"
                        class={button}
                        aria-label={t('camera.requests.approveLabel', { number: row.number })}
                        onclick={(event) => ask(row, true, event)}
                      >
                        {t('camera.requests.approve')}
                      </button>
                      <button
                        type="button"
                        class={button}
                        aria-label={t('camera.requests.denyLabel', { number: row.number })}
                        onclick={(event) => ask(row, false, event)}
                      >
                        {t('camera.requests.deny')}
                      </button>
                    </div>
                  {/if}
                </td>
              </tr>
              {#if enlargedStill === row.id && row.stillUrl && !brokenStills.includes(row.id)}
                <tr id={`footage-still-${row.id}`}>
                  <td class="px-2 py-1" colspan="6">
                    <img
                      src={row.stillUrl}
                      alt={t('camera.requests.stillAlt', { number: row.number })}
                      class="max-h-96 max-w-full border border-[var(--color-border)]"
                      onerror={() => stillFailed(row.id)}
                    />
                  </td>
                </tr>
              {/if}
            {/each}
          </tbody>
        </table>
      </div>
      <LoadMore {nextCursor} busy={loadingMore} loadMore={() => void loadMore()} />
    {/if}

    {#if pending}
      <div class="mt-2">
        <ConfirmDialog
          label={t(pending.approve ? 'camera.requests.approve' : 'camera.requests.deny')}
          question={t(pending.approve ? 'camera.requests.confirmApprove' : 'camera.requests.confirmDeny', {
            number: pending.request.number,
          })}
          {busy}
          {failure}
          fieldLabels={FIELD_LABELS}
          confirm={() => void decide()}
          cancel={() => void cancel()}
        >
          <label class="mt-2 flex flex-col gap-1">
            {t('camera.requests.note')}
            <textarea bind:value={note} maxlength="500" rows="2" class={control}></textarea>
          </label>
        </ConfirmDialog>
      </div>
    {/if}
  </section>

  <section aria-labelledby="camera-form-title">
    <h2 id="camera-form-title" class="mb-1 text-[15px] font-semibold">{t('camera.form.title')}</h2>
    <!-- Ctrl+Enter sends, from any field in the form: a shortcut on the form
         itself, not a click target. -->
    <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
    <form class="flex flex-wrap items-end gap-3" novalidate onsubmit={request} onkeydown={formKeys}>
      <label class="flex flex-col gap-1">
        {t('camera.form.source')}
        <select bind:value={form.source} class={control} onchange={() => (form.target = '')}>
          {#each FOOTAGE_SOURCES as source (source)}
            <option value={source}>{t(`camera.source.${source}`)}</option>
          {/each}
        </select>
      </label>
      <label class="flex flex-col gap-1">
        <!-- Named by its text alone: a wrapping label would add the chosen option to the name. -->
        <span id="camera-form-target">
          {form.source === 'cctv' ? t('camera.form.camera') : t('camera.form.officer')}
          <span aria-hidden="true">{REQUIRED_MARK}</span>
        </span>
        <select
          bind:value={form.target}
          class={control}
          required
          aria-required="true"
          aria-labelledby="camera-form-target"
        >
          <option value="">{t('camera.form.choose')}</option>
          {#each targets as target (target.value)}
            <option value={String(target.value)}>{target.label}</option>
          {/each}
        </select>
      </label>
      <label class="flex flex-col gap-1">
        <span>{t('camera.form.from')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
        <input type="datetime-local" bind:value={form.from} class={control} required aria-required="true" />
      </label>
      <label class="flex flex-col gap-1">
        <span>{t('camera.form.to')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
        <input type="datetime-local" bind:value={form.to} class={control} required aria-required="true" />
      </label>
      <label class="flex flex-1 flex-col gap-1">
        <span>{t('camera.form.reason')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
        <input bind:value={form.reason} maxlength="500" class={control} required aria-required="true" />
      </label>
      {#if investigations.length > 0}
        <label class="flex flex-col gap-1">
          <span id="camera-form-fu">{t('camera.form.fu')}</span>
          <select bind:value={form.fuId} class={control} aria-labelledby="camera-form-fu">
            <option value="">{t('camera.form.choose')}</option>
            {#each investigations as fu (fu.id)}
              <option value={String(fu.id)}>{fu.number}</option>
            {/each}
          </select>
        </label>
      {/if}
      <button type="submit" class={`${button} aria-disabled:opacity-60`} aria-disabled={busy}>
        {t('camera.form.submit')}
      </button>
    </form>
  </section>
</div>
