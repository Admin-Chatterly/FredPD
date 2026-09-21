<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { HAK_METHODS, HAK_TARGETS } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import { isStub, type Maybe, type Restricted } from '../records/types';

  /**
   * Surveillance — the secret coercive measures under RB 27:18, 27:20d (spec 9).
   *
   * Three things carry over from `Tvang.svelte`, at a stricter gate:
   *
   *   * **Liveness is the server's answer.** `hak.list` and `hak.get` send
   *     `live`; `get` also sends `notLiveBecause`. The same `Surveillance.isValid`
   *     answers `HasActiveWarrant`, so a second reading here would be the one
   *     nobody tested.
   *   * **Who may decide what is a capacity, not a rank**, and this module has
   *     *two* of them where tvång has one: `surv.request` (åklagare) files an
   *     application, `surv.decide` (domare) alone may grant or refuse it. A
   *     server refusing `wrong_capacity` on either action means exactly that —
   *     never a Discord role problem (invariant 4, spec 6.4).
   *   * **Observing needs a third, narrower permission again**: which method
   *     this session may actually listen to. The server checks it on
   *     `hak.session.start` and `hak.intercept.add` and answers
   *     `wrong_capability` when it is missing — a domare who granted an HRA has
   *     not thereby been handed the device.
   *
   * The observer session id is kept in this component's own state rather than
   * read back from the server: no route lists "sessions I currently hold", so
   * the only place that fact exists between `hak.session.start` and
   * `hak.session.end` is the button that started it.
   */

  interface HakRow {
    id: number;
    number: string;
    fuId: number;
    targetKind: string;
    targetId?: number | null;
    targetLabel?: string | null;
    method: string;
    grund: string;
    status: string;
    requestedBy?: string | null;
    requestedAt?: number | null;
    decidedBy?: string | null;
    decidedAt?: number | null;
    refusedGrund?: string | null;
    courtRef?: string | null;
    /** Epoch seconds, as `UNIX_TIMESTAMP` sends them. */
    validFrom?: number | null;
    validUntil?: number | null;
    upphavdAt?: number | null;
    upphavdBy?: string | null;
    upphavdGrund?: string | null;
    classification: string;
    version: number;
    /** `Surveillance.isValid`, computed on the server for every row it sends. */
    live?: boolean;
    banner?: string;
    needsRenewal?: boolean;
    /** Why not, on `hak.get` only. */
    notLiveBecause?: string | null;
  }

  interface HakSession {
    id: number;
    hakId: number;
    observer: string;
    startedAt: number;
    endedAt?: number | null;
    minimizationNote?: string | null;
  }

  interface HakIntercept {
    id: number;
    hakId: number;
    kind: string;
    occurredAt: number;
    summary?: string | null;
    mediaRef?: string | null;
    classification: string;
    loggedBy?: string | null;
    loggedAt: number;
  }

  /** The grounds RB gives for these measures. Locale keys, never prose. */
  const GRUNDER = ['skalig_misstanke', 'sarskild_vikt', 'fara_i_drojsmal', 'grov_brottslighet', 'annan'];
  const UPPHAVANDEGRUNDER = ['skal_upphorda', 'syfte_uppnatt', 'annan'];

  /** The default captures a screen offers, plus a free-text one for the rest. */
  const INTERCEPT_KINDS = ['call', 'message', 'position', 'audio', 'image', 'other'];

  /** How long a grant may run. Days, bounded by `HakGrant`'s schema (30 max). */
  const VALIDITY_DAYS = [1, 7, 14, 30];
  const DAY = 86400;

  let rows = $state<Maybe<HakRow>[]>([]);
  let detail = $state<HakRow | null>(null);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);
  let statusFilter = $state('');
  let liveOnly = $state(false);
  let openId = $state<number | null>(null);

  let sessions = $state<HakSession[]>([]);
  let intercepts = $state<HakIntercept[]>([]);
  let logAvailable = $state(false);

  /** The session id this workstation currently holds open on `detail`, if any. */
  let openSessionId = $state<number | null>(null);

  let confirmingGrant = $state(false);
  let confirmingRefuse = $state(false);
  let confirmingUpphav = $state(false);
  let trigger: HTMLButtonElement | null = null;

  /** What just happened, for the officer who cannot see the list change. */
  let status = $state('');

  let requesting = $state(false);
  let request = $state({
    fuId: '',
    targetKind: HAK_TARGETS[0] as string,
    targetId: '',
    targetLabel: '',
    method: HAK_METHODS[0] as string,
    grund: '',
  });

  let grantForm = $state({ courtRef: '', validDays: 7 });
  let refuseGrund = $state('');
  let upphavGrund = $state('');

  let interceptForm = $state({ kind: INTERCEPT_KINDS[0] as string, summary: '', mediaRef: '' });

  const REQUIRED_MARK = '*';

  /** Which field a rejected code belongs to (spec 3.5). */
  const FIELD_LABELS: Record<string, string> = {
    _input: 'surveillance.column.status',
    fuId: 'surveillance.field.fuId',
    targetKind: 'surveillance.column.target',
    targetId: 'surveillance.column.target',
    targetLabel: 'surveillance.field.targetLabel',
    method: 'surveillance.column.method',
    grund: 'surveillance.field.grundChoose',
    classification: 'records.person.field.classification',
    courtRef: 'surveillance.field.courtRef',
    validSeconds: 'surveillance.field.valid',
    kind: 'surveillance.field.kind',
    version: 'anmalan.column.version',
  };

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  function cancelConfirm(): void {
    confirmingGrant = false;
    confirmingRefuse = false;
    confirmingUpphav = false;
    failure = null;
    trigger?.focus();
  }

  async function load(): Promise<void> {
    busy = true;

    const response = await nui.call<{ hak: Maybe<HakRow>[] }>('hak.list', {
      status: statusFilter || undefined,
      liveOnly: liveOnly || undefined,
      limit: 50,
    });

    if (response.ok) {
      rows = response.data.hak ?? [];
      failure = null;
    } else {
      failure = response;
    }

    busy = false;
  }

  async function loadLog(id: number): Promise<void> {
    const response = await nui.call<{ id: number; sessions: HakSession[]; intercepts: HakIntercept[] }>(
      'hak.log',
      { hakId: id },
    );

    if (response.ok) {
      sessions = response.data.sessions ?? [];
      intercepts = response.data.intercepts ?? [];
      logAvailable = true;
    } else {
      // `surv.log.view` is a narrower grant than `surv.view` (spec 9). A
      // refusal here is routine, not an error the officer needs to see —
      // the section is simply not drawn (invariant 4).
      sessions = [];
      intercepts = [];
      logAvailable = false;
    }
  }

  async function open(id: number): Promise<void> {
    busy = true;
    confirmingGrant = false;
    confirmingRefuse = false;
    confirmingUpphav = false;
    openSessionId = null;

    const response = await nui.call<{ hak: HakRow }>('hak.get', { id });

    if (response.ok) {
      detail = response.data.hak;
      openId = id;
      failure = null;
      await loadLog(id);
    } else {
      detail = null;
      openId = null;
      failure = response;
    }

    busy = false;
  }

  async function submitRequest(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    busy = true;

    const response = await nui.call<{ id: number; number: string }>('hak.request', {
      fuId: Number(request.fuId) || undefined,
      targetKind: request.targetKind,
      targetId: request.targetId ? Number(request.targetId) : undefined,
      targetLabel: request.targetLabel || undefined,
      method: request.method,
      grund: request.grund || undefined,
    });

    if (response.ok) {
      failure = null;
      requesting = false;
      status = t('surveillance.requested', { number: response.data.number });
      request.targetId = '';
      request.targetLabel = '';
      request.grund = '';
      await Promise.all([load(), open(response.data.id)]);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function grant(): Promise<void> {
    if (!detail) return;

    busy = true;
    const id = detail.id;
    const number = detail.number;

    const response = await nui.call('hak.grant', {
      id,
      version: detail.version,
      courtRef: grantForm.courtRef || undefined,
      validSeconds: grantForm.validDays * DAY,
    });

    if (response.ok) {
      failure = null;
      confirmingGrant = false;
      status = t('surveillance.granted', { number });
      trigger?.focus();
      await Promise.all([open(id), load()]);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function refuse(): Promise<void> {
    if (!detail) return;

    busy = true;
    const id = detail.id;
    const number = detail.number;

    const response = await nui.call('hak.refuse', {
      id,
      version: detail.version,
      grund: refuseGrund || undefined,
    });

    if (response.ok) {
      failure = null;
      confirmingRefuse = false;
      status = t('surveillance.refused', { number });
      trigger?.focus();
      await Promise.all([open(id), load()]);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function upphav(): Promise<void> {
    if (!detail) return;

    busy = true;
    const id = detail.id;
    const number = detail.number;

    const response = await nui.call('hak.upphav', {
      id,
      version: detail.version,
      grund: upphavGrund || undefined,
    });

    if (response.ok) {
      failure = null;
      confirmingUpphav = false;
      status = t('surveillance.revoked', { number });
      trigger?.focus();
      await Promise.all([open(id), load()]);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function startSession(): Promise<void> {
    if (!detail) return;

    busy = true;
    const response = await nui.call<{ id: number }>('hak.session.start', { hakId: detail.id });

    if (response.ok) {
      failure = null;
      openSessionId = response.data.id;
      await loadLog(detail.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  async function endSession(): Promise<void> {
    if (!detail || openSessionId === null) return;

    busy = true;
    const id = detail.id;
    const response = await nui.call('hak.session.end', { id: openSessionId });

    if (response.ok) {
      failure = null;
      openSessionId = null;
      await loadLog(id);
    } else {
      failure = response;
    }

    busy = false;
  }

  async function logIntercept(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail) return;

    busy = true;
    const id = detail.id;

    const response = await nui.call('hak.intercept.add', {
      hakId: id,
      kind: `surveillance.intercept.${interceptForm.kind}`,
      summary: interceptForm.summary || undefined,
      mediaRef: interceptForm.mediaRef || undefined,
    });

    if (response.ok) {
      failure = null;
      interceptForm.summary = '';
      interceptForm.mediaRef = '';
      await loadLog(id);
    } else {
      failure = response;
    }

    busy = false;
  }

  /**
   * What a row's status says, in the server's own word.
   *
   * `status` alone already distinguishes `begard`/`avslagen`/`upphavd`; what
   * it cannot say is *when* a `beviljad` grant is outside its window, which is
   * what `notLiveBecause` — `hak.get` only — carries.
   */
  function statusText(row: HakRow): string {
    if (row.live) return t('surveillance.status.beviljad');
    if (row.notLiveBecause) return t(`surveillance.status.${row.notLiveBecause}`);

    return t(`surveillance.status.${row.status}`);
  }

  function targetText(row: HakRow): string {
    const kind = t(`surveillance.target.${row.targetKind}`);

    return row.targetLabel ? `${kind} — ${row.targetLabel}` : `${kind} #${row.targetId}`;
  }

  /** `surveillance.intercept.call` -> `call`, for the select and the display. */
  function interceptKindSuffix(kind: string): string {
    return kind.startsWith('surveillance.intercept.') ? kind.slice('surveillance.intercept.'.length) : kind;
  }

  function stubContact(row: Restricted): string {
    return t('records.restricted.contact', { unit: t(`access.unit.${row.contact}`) });
  }

  void load();
</script>

<div class="flex flex-col gap-3">
  <form
    class="flex flex-wrap items-end gap-2"
    onsubmit={(event) => {
      event.preventDefault();
      void load();
    }}
  >
    <label class="flex items-center gap-1 text-xs">
      <input type="checkbox" bind:checked={liveOnly} />
      {t('tvang.filter.liveOnly')}
    </label>

    <label class="flex flex-col gap-1 text-xs">
      {t('surveillance.column.status')}
      <select bind:value={statusFilter} class="border border-[var(--color-border)] px-2 py-1">
        <option value="">{t('form.any')}</option>
        {#each ['begard', 'beviljad', 'avslagen', 'upphavd'] as key (key)}
          <option value={key}>{t(`surveillance.status.${key}`)}</option>
        {/each}
      </select>
    </label>

    <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
      {t('form.search')}
    </button>

    <button
      type="button"
      class="border border-[var(--color-border)] px-3 py-1 text-xs"
      onclick={() => (requesting = !requesting)}
    >
      {t('surveillance.action.request')}
    </button>
  </form>

  {#if failure}
    <div class="border border-[var(--color-alert)] px-3 py-2 text-sm" role="alert">
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

  {#if requesting}
    <!-- The åklagare's application. Filed against an open investigation, and
         a domare decides it — never this form. -->
    <form
      class="flex flex-wrap items-end gap-2 border border-[var(--color-border)] p-3"
      onsubmit={(event) => void submitRequest(event)}
    >
      <label class="flex flex-col gap-1 text-xs">
        <span>{t('surveillance.field.fuId')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
        <input
          bind:value={request.fuId}
          inputmode="numeric"
          required
          aria-required="true"
          class="w-24 border border-[var(--color-border)] px-2 py-1"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        {t('surveillance.column.method')}
        <select bind:value={request.method} class="border border-[var(--color-border)] px-2 py-1">
          {#each HAK_METHODS as method (method)}
            <option value={method}>{t(`surveillance.method.${method}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        {t('surveillance.column.target')}
        <select bind:value={request.targetKind} class="border border-[var(--color-border)] px-2 py-1">
          {#each HAK_TARGETS as target (target)}
            <option value={target}>{t(`surveillance.target.${target}`)}</option>
          {/each}
        </select>
      </label>

      {#if request.targetKind === 'phone' || request.targetKind === 'location'}
        <label class="flex flex-col gap-1 text-xs">
          <span>{t('surveillance.field.targetLabel')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
          <input
            bind:value={request.targetLabel}
            maxlength="191"
            required
            aria-required="true"
            class="w-56 border border-[var(--color-border)] px-2 py-1"
          />
        </label>
      {:else}
        <label class="flex flex-col gap-1 text-xs">
          <span>{t('surveillance.field.targetId')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
          <input
            bind:value={request.targetId}
            inputmode="numeric"
            required
            aria-required="true"
            class="w-24 border border-[var(--color-border)] px-2 py-1"
          />
        </label>
      {/if}

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('surveillance.field.grundChoose')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
        <select
          bind:value={request.grund}
          required
          aria-required="true"
          class="border border-[var(--color-border)] px-2 py-1"
        >
          <option value="">{t('surveillance.field.grundChoose')}</option>
          {#each GRUNDER as key (key)}
            <option value={key}>{t(`surveillance.grund.${key}`)}</option>
          {/each}
        </select>
      </label>

      <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
        {t('surveillance.action.request')}
      </button>
    </form>
  {/if}

  {#if status}
    <p class="text-xs text-[var(--color-ink-muted)]" role="status">{status}</p>
  {/if}

  <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
    <div class="border border-[var(--color-border)]">
      {#if rows.length === 0}
        <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">{t('surveillance.empty')}</p>
      {:else}
        <div class="overflow-x-auto">
          <table class="w-full text-xs">
            <thead class="bg-[var(--color-surface)]">
              <tr>
                <th class="px-2 py-1 text-left font-semibold">{t('surveillance.column.number')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('surveillance.column.method')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('surveillance.column.target')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('surveillance.column.status')}</th>
              </tr>
            </thead>
            <tbody>
              <!-- Keyed by index: a stub carries no id (4.5). -->
              {#each rows as row, index (index)}
                {#if isStub(row)}
                  <tr class="border-t border-[var(--color-border)]">
                    <td class="px-2 py-1 text-[var(--color-ink-muted)]" colspan="4">
                      {t('records.restricted.title')} — {stubContact(row)}
                    </td>
                  </tr>
                {:else}
                  <tr class="border-t border-[var(--color-border)]">
                    <td class="px-2 py-1 font-[family-name:var(--font-mono)] whitespace-nowrap">
                      <button
                        type="button"
                        class="underline-offset-2 hover:underline"
                        class:font-semibold={openId === row.id}
                        onclick={() => void open(row.id)}
                      >
                        {row.number}
                      </button>
                    </td>
                    <td class="px-2 py-1">{t(`surveillance.method.${row.method}`)}</td>
                    <td class="px-2 py-1">{targetText(row)}</td>
                    <td class="px-2 py-1 whitespace-nowrap">
                      <span class:text-[var(--color-ink-muted)]={!row.live}>
                        {statusText(row)}
                      </span>
                    </td>
                  </tr>
                {/if}
              {/each}
            </tbody>
          </table>
        </div>
      {/if}
    </div>

    <div class="border border-[var(--color-border)] p-3">
      {#if !detail}
        <p class="text-xs text-[var(--color-ink-muted)]">{t('surveillance.detail.none')}</p>
      {:else}
        <header class="mb-3">
          <h2 class="font-[family-name:var(--font-mono)] text-sm font-semibold">
            {detail.number}
          </h2>
          <p class="text-xs text-[var(--color-ink-muted)]">
            {t(`surveillance.method.${detail.method}`)} · {targetText(detail)}
          </p>
        </header>

        {#if !detail.live}
          <p class="mb-3 border border-[var(--color-alert)] px-2 py-1 text-xs" role="alert">
            {t('surveillance.notLive', { reason: statusText(detail) })}
          </p>
        {/if}

        <dl class="mb-3 text-xs">
          <div class="flex justify-between border-t border-[var(--color-border)] py-1">
            <dt>{t('surveillance.column.status')}</dt>
            <dd>{statusText(detail)}</dd>
          </div>
          <div class="flex justify-between border-t border-[var(--color-border)] py-1">
            <dt>{t('surveillance.field.grundChoose')}</dt>
            <dd>{t(`surveillance.grund.${detail.grund}`)}</dd>
          </div>
          {#if detail.status === 'beviljad'}
            <div class="flex justify-between border-t border-[var(--color-border)] py-1">
              <dt>{t('surveillance.column.valid')}</dt>
              <dd class="font-[family-name:var(--font-mono)]">
                {formatMoment(detail.validFrom ?? null)} – {formatMoment(detail.validUntil ?? null)}
              </dd>
            </div>
          {/if}
          {#if detail.courtRef}
            <div class="flex justify-between border-t border-[var(--color-border)] py-1">
              <dt>{t('surveillance.field.courtRef')}</dt>
              <dd class="font-[family-name:var(--font-mono)]">{detail.courtRef}</dd>
            </div>
          {/if}
          {#if detail.status === 'avslagen' && detail.refusedGrund}
            <div class="flex justify-between border-t border-[var(--color-border)] py-1">
              <dt>{t('surveillance.action.refuse')}</dt>
              <dd>{t(`surveillance.grund.${detail.refusedGrund}`)}</dd>
            </div>
          {/if}
          {#if detail.upphavdAt}
            <div class="flex justify-between border-t border-[var(--color-border)] py-1">
              <dt>{t('surveillance.status.upphavd')}</dt>
              <dd class="font-[family-name:var(--font-mono)]">{formatMoment(detail.upphavdAt)}</dd>
            </div>
            {#if detail.upphavdGrund}
              <div class="flex justify-between border-t border-[var(--color-border)] py-1">
                <dt>{t('surveillance.action.upphav')}</dt>
                <dd>{t(`surveillance.upphavandegrund.${detail.upphavdGrund}`)}</dd>
              </div>
            {/if}
          {/if}
        </dl>

        {#if detail.needsRenewal}
          <p class="mb-3 border border-[var(--color-alert)] px-2 py-1 text-xs" role="status">
            {t('surveillance.field.valid')} — {formatMoment(detail.validUntil ?? null)}
          </p>
        {/if}

        <!-- Deciding a request: only shown while it is `begard`. The server
             alone tells the two decisions apart by capacity; this offers both
             buttons and lets `hak.grant`/`hak.refuse` refuse `wrong_capacity`
             when the session is not the domare. -->
        {#if detail.status === 'begard'}
          <section class="mb-3 border-t border-[var(--color-border)] pt-3">
            {#if confirmingGrant}
              <ConfirmDialog
                label={t('surveillance.action.grant')}
                question={t('surveillance.confirm.grant')}
                {busy}
                {failure}
                fieldLabels={FIELD_LABELS}
                confirm={() => void grant()}
                cancel={cancelConfirm}
              >
                  <label class="flex flex-col gap-1 text-xs">
                    {t('surveillance.field.courtRef')}
                    <input
                      bind:value={grantForm.courtRef}
                      maxlength="64"
                      class="border border-[var(--color-border)] px-2 py-1"
                    />
                  </label>
                  <label class="flex flex-col gap-1 text-xs">
                    {t('surveillance.field.valid')}
                    <select
                      bind:value={grantForm.validDays}
                      class="border border-[var(--color-border)] px-2 py-1"
                    >
                      {#each VALIDITY_DAYS as days (days)}
                        <option value={days}>{t('surveillance.field.validDays', { count: String(days) })}</option>
                      {/each}
                    </select>
                  </label>
              </ConfirmDialog>
            {:else if confirmingRefuse}
              <ConfirmDialog
                label={t('surveillance.action.refuse')}
                question={t('surveillance.confirm.refuse')}
                {busy}
                {failure}
                fieldLabels={FIELD_LABELS}
                confirm={() => void refuse()}
                cancel={cancelConfirm}
              >
                  <label class="flex flex-col gap-1 text-xs">
                    <span>{t('surveillance.field.grundChoose')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
                    <select
                      bind:value={refuseGrund}
                      required
                      aria-required="true"
                      class="border border-[var(--color-border)] px-2 py-1"
                    >
                      <option value="">{t('surveillance.field.grundChoose')}</option>
                      {#each GRUNDER as key (key)}
                        <option value={key}>{t(`surveillance.grund.${key}`)}</option>
                      {/each}
                    </select>
                  </label>
              </ConfirmDialog>
            {:else}
              <div class="flex gap-2">
                <button
                  type="button"
                  class="border border-[var(--color-border)] px-3 py-1 text-xs"
                  disabled={busy}
                  onclick={(event) => {
                    trigger = event.currentTarget;
                    confirmingGrant = true;
                    failure = null;
                    status = '';
                  }}
                >
                  {t('surveillance.action.grant')}
                </button>
                <button
                  type="button"
                  class="border border-[var(--color-border)] px-3 py-1 text-xs"
                  disabled={busy}
                  onclick={(event) => {
                    trigger = event.currentTarget;
                    confirmingRefuse = true;
                    refuseGrund = '';
                    failure = null;
                    status = '';
                  }}
                >
                  {t('surveillance.action.refuse')}
                </button>
              </div>
            {/if}
          </section>
        {/if}

        <!-- Observing: only meaningful once granted and live. -->
        {#if detail.status === 'beviljad'}
          <section class="mb-3 border-t border-[var(--color-border)] pt-3">
            <h3 class="mb-1 text-xs font-semibold">{t('surveillance.log.title')}</h3>

            {#if detail.live}
              {#if openSessionId !== null}
                <button
                  type="button"
                  class="border border-[var(--color-border)] px-3 py-1 text-xs"
                  disabled={busy}
                  onclick={() => void endSession()}
                >
                  {t('surveillance.action.endSession')}
                </button>
              {:else}
                <button
                  type="button"
                  class="border border-[var(--color-border)] px-3 py-1 text-xs"
                  disabled={busy}
                  onclick={() => void startSession()}
                >
                  {t('surveillance.action.startSession')}
                </button>
              {/if}

              <form
                class="mt-2 flex flex-wrap items-end gap-2"
                onsubmit={(event) => void logIntercept(event)}
              >
                <label class="flex flex-col gap-1 text-xs">
                  {t('surveillance.field.kind')}
                  <select
                    bind:value={interceptForm.kind}
                    class="border border-[var(--color-border)] px-2 py-1"
                  >
                    {#each INTERCEPT_KINDS as key (key)}
                      <option value={key}>{t(`surveillance.intercept.${key}`)}</option>
                    {/each}
                  </select>
                </label>
                <label class="flex flex-1 flex-col gap-1 text-xs">
                  {t('surveillance.field.summary')}
                  <input
                    bind:value={interceptForm.summary}
                    maxlength="500"
                    class="border border-[var(--color-border)] px-2 py-1"
                  />
                </label>
                <label class="flex flex-col gap-1 text-xs">
                  {t('surveillance.field.mediaRef')}
                  <input
                    bind:value={interceptForm.mediaRef}
                    maxlength="191"
                    class="border border-[var(--color-border)] px-2 py-1"
                  />
                </label>
                <button
                  type="submit"
                  class="border border-[var(--color-border)] px-3 py-1 text-xs"
                  disabled={busy}
                >
                  {t('surveillance.action.logIntercept')}
                </button>
              </form>
            {/if}

            {#if logAvailable}
              <div class="mt-3">
                <h4 class="mb-1 text-xs font-semibold">{t('surveillance.log.sessions')}</h4>
                {#if sessions.length === 0}
                  <p class="text-xs text-[var(--color-ink-muted)]">{t('surveillance.log.empty')}</p>
                {:else}
                  <ul class="text-xs">
                    {#each sessions as row (row.id)}
                      <li class="border-t border-[var(--color-border)] py-1">
                        {formatMoment(row.startedAt)}
                        {row.endedAt ? `– ${formatMoment(row.endedAt)}` : ''}
                      </li>
                    {/each}
                  </ul>
                {/if}

                <h4 class="mt-2 mb-1 text-xs font-semibold">{t('surveillance.log.intercepts')}</h4>
                {#if intercepts.length === 0}
                  <p class="text-xs text-[var(--color-ink-muted)]">{t('surveillance.log.empty')}</p>
                {:else}
                  <ul class="text-xs">
                    {#each intercepts as row (row.id)}
                      <li class="border-t border-[var(--color-border)] py-1">
                        <span class="font-semibold">
                          {t(`surveillance.intercept.${interceptKindSuffix(row.kind)}`)}
                        </span>
                        · {formatMoment(row.occurredAt)}
                        {#if row.summary}<p>{row.summary}</p>{/if}
                      </li>
                    {/each}
                  </ul>
                {/if}
              </div>
            {/if}
          </section>

          <!-- Early revocation, RB 27:23. -->
          {#if !detail.upphavdAt}
            <section class="border-t border-[var(--color-border)] pt-3">
              {#if confirmingUpphav}
                <ConfirmDialog
                  label={t('surveillance.action.upphav')}
                  question={t('surveillance.confirm.upphav')}
                  {busy}
                  {failure}
                  fieldLabels={FIELD_LABELS}
                  confirm={() => void upphav()}
                  cancel={cancelConfirm}
                >
                    <label class="flex flex-col gap-1 text-xs">
                      {t('surveillance.field.grundChoose')}
                      <select
                        bind:value={upphavGrund}
                        class="border border-[var(--color-border)] px-2 py-1"
                      >
                        <option value="">{t('surveillance.field.grundChoose')}</option>
                        {#each UPPHAVANDEGRUNDER as key (key)}
                          <option value={key}>{t(`surveillance.upphavandegrund.${key}`)}</option>
                        {/each}
                      </select>
                    </label>
                </ConfirmDialog>
              {:else}
                <button
                  type="button"
                  class="border border-[var(--color-border)] px-3 py-1 text-xs"
                  disabled={busy}
                  onclick={(event) => {
                    trigger = event.currentTarget;
                    confirmingUpphav = true;
                    upphavGrund = '';
                    failure = null;
                    status = '';
                  }}
                >
                  {t('surveillance.action.upphav')}
                </button>
              {/if}
            </section>
          {/if}
        {/if}
      {/if}
    </div>
  </div>
</div>
