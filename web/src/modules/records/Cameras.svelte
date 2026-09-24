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
  import { FOOTAGE_SOURCES, type FootageSource, type FootageStatus } from '@fredpd/schema';

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
  /** Investigations this officer may read, to tie a request to (none when they may not list them). */
  let investigations = $state<{ id: number; number: string }[]>([]);
  let requests = $state<FootageRequest[]>([]);
  let mayApprove = $state(false);
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
  }

  async function loadRequests(): Promise<void> {
    const response = await nui.call<{ requests: FootageRequest[]; mayApprove: boolean }>('camera.footage.list', {});
    if (response.ok) {
      requests = response.data.requests;
      mayApprove = response.data.mayApprove;
    }
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

    const response = await nui.call<{ source: FootageSource; label: string; requestId?: number; position?: unknown }>(
      'camera.view.start',
      { placementId: openedAt ?? 0, source, ...target },
    );

    if (response.ok) {
      // The game takes it from here; the MDT hides until the view ends.
      await nui.call('fredpd:cameraOpen', response.data);
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

    pending = null;
    await loadRequests();
    await announce(t('camera.requests.decided', { number: response.data.number }));
  }

  function describe(row: FootageRequest): string {
    const label = t(`camera.source.${row.source}`);
    if (row.source === 'cctv') return `${label} ${row.cameraId ?? ''}`.trim();
    return `${label} ${row.officerCallsign ?? ''}`.trim();
  }

  const targets = $derived.by(() => {
    if (!sources) return [];
    if (form.source === 'cctv') return sources.cameras.map((camera) => ({ value: camera.id, label: `CCTV ${camera.id}` }));
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
                  {@const label =
                    'id' in entry ? `CCTV ${entry.id}` : (entry.callsign ?? String(entry.officerId))}
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
    <h2 id="camera-requests-title" class="mb-1 text-[15px] font-semibold">{t('camera.requests.title')}</h2>
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
              <th class="px-2 py-1 font-normal"><span class="sr-only">{t('camera.requests.approve')}</span></th>
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
                  {#if row.stillThumbUrl}
                    <img src={row.stillThumbUrl} alt={t('camera.requests.openStill')} class="h-12 border border-[var(--color-border)]" />
                  {/if}
                </td>
                <td class="px-2 py-1">
                  {#if mayApprove && !row.mine && row.status === 'requested'}
                    <div class="flex gap-1">
                      <button type="button" class={button} onclick={(event) => ask(row, true, event)}>
                        {t('camera.requests.approve')}
                      </button>
                      <button type="button" class={button} onclick={(event) => ask(row, false, event)}>
                        {t('camera.requests.deny')}
                      </button>
                    </div>
                  {/if}
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
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
    <form class="flex flex-wrap items-end gap-3" novalidate onsubmit={request}>
      <label class="flex flex-col gap-1">
        {t('camera.form.source')}
        <select bind:value={form.source} class={control} onchange={() => (form.target = '')}>
          {#each FOOTAGE_SOURCES as source (source)}
            <option value={source}>{t(`camera.source.${source}`)}</option>
          {/each}
        </select>
      </label>
      <label class="flex flex-col gap-1">
        {form.source === 'cctv' ? t('camera.form.camera') : t('camera.form.officer')}
        <select bind:value={form.target} class={control}>
          <option value=""></option>
          {#each targets as target (target.value)}
            <option value={String(target.value)}>{target.label}</option>
          {/each}
        </select>
      </label>
      <label class="flex flex-col gap-1">
        {t('camera.form.from')}
        <input type="datetime-local" bind:value={form.from} class={control} />
      </label>
      <label class="flex flex-col gap-1">
        {t('camera.form.to')}
        <input type="datetime-local" bind:value={form.to} class={control} />
      </label>
      <label class="flex flex-1 flex-col gap-1">
        {t('camera.form.reason')}
        <input bind:value={form.reason} maxlength="500" class={control} />
      </label>
      {#if investigations.length > 0}
        <label class="flex flex-col gap-1">
          {t('camera.form.fu')}
          <select bind:value={form.fuId} class={control}>
            <option value=""></option>
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
