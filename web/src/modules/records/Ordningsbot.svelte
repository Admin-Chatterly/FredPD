<script lang="ts">
  import PrintMenu from '../documents/PrintMenu.svelte';
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import { isStub, type Maybe, type Restricted } from './types';
  import PersonPicker from '../shared/PersonPicker.svelte';
  import VehiclePicker from '../shared/VehiclePicker.svelte';
  import { onIntent, peekIntent, takeIntent } from '../../lib/intent';
  import TariffEditor from './TariffEditor.svelte';
  import { tariffName, type LicenceStanding, type Tariff } from './tariff';

  /**
   * Ordningsbot: on-the-spot fines against a versioned tariff (spec 7.11).
   *
   * `Tariff.amount` on a citation is read from the one tariff row it cites
   * (an immutable version, the same shape `fpd_brott` and `fpd_atal_brott`
   * use) -- never re-looked-up against whatever the current tariff says, so a
   * citation keeps the amount it was actually issued under.
   */

  interface Citation {
    id: number;
    number: string;
    tariffId: number;
    personId?: number | null;
    vehicleId?: number | null;
    issuedAt: number;
    issuedBy: string;
    status: string;
    dueAt: number;
    /** Derived on the server, never stored (0024): `status` split into
     * `unpaid`/`overdue` while it is `issued`, unchanged otherwise. */
    paymentStatus: string;
    /** When a bill was sent through esx_billing (0031); null when none was. */
    billedAt?: number | null;
    voidReasonKey?: string | null;
    version: number;
    tariff?: Tariff;
  }

  const STATUSES = ['issued', 'paid', 'contested', 'void'];
  const VOID_REASONS = ['issued_in_error', 'identity_mistake', 'duplicate', 'other'];

  const FIELD_LABELS: Record<string, string> = {
    tariffId: 'ordningsbot.field.tariff',
    personId: 'ordningsbot.field.person',
    vehicleId: 'ordningsbot.field.vehicle',
    voidReasonKey: 'ordningsbot.voidReason.label',
  };

  let tariffs = $state<Tariff[]>([]);
  /** From the server: whether this session may edit the tariff (0036). */
  let mayEdit = $state(false);
  let licenceOn = $state(false);
  let editingTariff = $state(false);
  /** What the last fine did to the named person's licence, when it added points. */
  let licenceNote = $state<LicenceStanding | null>(null);
  let rows = $state<Maybe<Citation>[]>([]);
  let detail = $state<Citation | null>(null);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);
  let statusFilter = $state('');
  let status = $state('');

  let issueForm = $state({ tariffId: '', personId: '', vehicleId: '' });

  /**
   * "Issue a fine" from a query row (lib/intent.ts): the form opens holding
   * that person or vehicle, named, and the officer only picks the fine.
   */
  let subjectLabel = $state<string | null>(null);

  function followIntent(): void {
    const intent = peekIntent();
    if (!intent || intent.tab !== 'ordningsbot' || !(intent.personId || intent.vehicleId)) return;

    takeIntent();
    issueForm = {
      tariffId: '',
      personId: intent.personId ? String(intent.personId) : '',
      vehicleId: intent.vehicleId ? String(intent.vehicleId) : '',
    };
    subjectLabel = intent.subjectLabel ?? null;
  }

  $effect(() => {
    followIntent();
    return onIntent(() => followIntent());
  });
  let voidReasonKey = $state(VOID_REASONS[0]);
  let confirmingVoid = $state(false);
  let trigger: HTMLButtonElement | null = null;

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  async function loadTariffs(): Promise<void> {
    const response = await nui.call<{ tariffs: Tariff[]; mayEdit?: boolean; licence?: boolean }>(
      'ordningsbot.tariff.list',
      {},
    );
    if (response.ok) {
      tariffs = response.data.tariffs ?? [];
      mayEdit = response.data.mayEdit === true;
      licenceOn = response.data.licence === true;
    }
  }

  async function load(): Promise<void> {
    busy = true;

    const response = await nui.call<{ citations: Maybe<Citation>[] }>('ordningsbot.list', {
      status: statusFilter || undefined,
      limit: 100,
    });

    if (response.ok) {
      rows = response.data.citations ?? [];
      failure = null;
    } else {
      failure = response;
    }

    busy = false;
  }

  async function open(id: number): Promise<void> {
    busy = true;
    // What the last fine did to a licence belongs to the moment it was
    // issued: opening any citation, or reopening one after a void or a
    // contest, clears it. `issue` sets it again after its own open.
    licenceNote = null;

    const response = await nui.call<{ citation: Citation }>('ordningsbot.get', { id });

    if (response.ok) {
      detail = response.data.citation;
      failure = null;
    } else {
      detail = null;
      failure = response;
    }

    busy = false;
  }

  async function issue(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    const tariffId = Number.parseInt(issueForm.tariffId, 10);
    if (!Number.isFinite(tariffId)) return;

    busy = true;
    const personId = issueForm.personId ? Number.parseInt(issueForm.personId, 10) : undefined;
    const vehicleId = issueForm.vehicleId ? Number.parseInt(issueForm.vehicleId, 10) : undefined;

    const response = await nui.call<{ id: number; number: string; licence?: LicenceStanding | null }>('ordningsbot.issue', {
      tariffId,
      personId,
      vehicleId,
    });

    if (response.ok) {
      failure = null;
      status = t('ordningsbot.issued', { number: response.data.number });
      issueForm = { tariffId: '', personId: '', vehicleId: '' };
      await Promise.all([load(), open(response.data.id)]);
      licenceNote = response.data.licence ?? null;
    } else {
      failure = response;
    }

    busy = false;
  }

  async function markPaid(): Promise<void> {
    if (!detail) return;

    busy = true;
    const response = await nui.call('ordningsbot.pay', { id: detail.id, version: detail.version });

    if (response.ok) {
      failure = null;
      await Promise.all([open(detail.id), load()]);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function markContested(): Promise<void> {
    if (!detail) return;

    busy = true;
    const response = await nui.call('ordningsbot.contest', { id: detail.id, version: detail.version });

    if (response.ok) {
      failure = null;
      await Promise.all([open(detail.id), load()]);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function voidCitation(): Promise<void> {
    if (!detail) return;

    busy = true;
    const id = detail.id;

    const response = await nui.call('ordningsbot.void', { id, version: detail.version, voidReasonKey });

    if (response.ok) {
      failure = null;
      confirmingVoid = false;
      trigger?.focus();
      await Promise.all([open(id), load()]);
    } else {
      failure = response;
      busy = false;
    }
  }

  function cancelConfirm(): void {
    confirmingVoid = false;
    failure = null;
    trigger?.focus();
  }

  function stubContact(row: Restricted): string {
    return t('records.restricted.contact', { unit: t(`access.unit.${row.contact}`) });
  }

  void loadTariffs();
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
    <label class="flex flex-col gap-1 text-xs">
      {t('ordningsbot.field.status')}
      <select bind:value={statusFilter} class="border border-[var(--color-border)] px-2 py-1">
        <option value="">{t('form.any')}</option>
        {#each STATUSES as key (key)}
          <option value={key}>{t(`ordningsbot.status.${key}`)}</option>
        {/each}
      </select>
    </label>
    <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
      {t('form.search')}
    </button>
    {#if mayEdit}
      <button
        type="button"
        class="ml-auto border border-[var(--color-border)] px-3 py-1 text-xs focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
        aria-expanded={editingTariff}
        aria-controls="tariff-editor"
        onclick={() => (editingTariff = !editingTariff)}
      >
        {editingTariff ? t('ordningsbot.tariffEditor.close') : t('ordningsbot.tariffEditor.open')}
      </button>
    {/if}
  </form>

  {#if mayEdit && editingTariff}
    <TariffEditor {tariffs} licence={licenceOn} onChanged={loadTariffs} />
  {/if}

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

  <form class="flex flex-wrap items-end gap-2 border border-[var(--color-border)] p-3" onsubmit={issue}>
    <label class="flex flex-col gap-1 text-xs">
      <span>{t('ordningsbot.field.tariff')} <span aria-hidden="true">*</span></span>
      <select bind:value={issueForm.tariffId} required class="border border-[var(--color-border)] px-2 py-1">
        <option value="">{t('ordningsbot.field.tariff')}</option>
        {#each tariffs as tariff (tariff.id)}
          <option value={String(tariff.id)}>
            {licenceOn && (tariff.licencePoints ?? 0) > 0
              ? t('ordningsbot.tariffOption.withPoints', {
                  name: tariffName(tariff),
                  amount: tariff.amount,
                  points: tariff.licencePoints ?? 0,
                })
              : t('ordningsbot.tariffOption.plain', { name: tariffName(tariff), amount: tariff.amount })}
          </option>
        {/each}
      </select>
    </label>
    <div class="flex w-64 flex-col gap-1 text-xs">
      <span id="ordningsbot-person-label">{t('ordningsbot.field.person')}</span>
      <PersonPicker
        bind:value={issueForm.personId}
        initialLabel={issueForm.personId ? subjectLabel : null}
        labelledby="ordningsbot-person-label"
      />
    </div>
    <div class="flex w-56 flex-col gap-1 text-xs">
      <span id="ordningsbot-vehicle-label">{t('ordningsbot.field.vehicle')}</span>
      <VehiclePicker
        bind:value={issueForm.vehicleId}
        initialLabel={issueForm.vehicleId ? subjectLabel : null}
        labelledby="ordningsbot-vehicle-label"
      />
    </div>
    <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
      {t('ordningsbot.action.issue')}
    </button>
  </form>

  {#if status}
    <div role="status" class="text-xs">
      <p class="text-[var(--color-ink-muted)]">{status}</p>
      {#if licenceNote}
        <p class:font-semibold={licenceNote.standing !== 'valid'} class:text-[var(--color-caution)]={licenceNote.standing !== 'valid'}>
          {t(`ordningsbot.licence.${licenceNote.standing}`, { points: licenceNote.points, threshold: licenceNote.threshold })}
        </p>
      {/if}
    </div>
  {/if}

  <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
    <div class="border border-[var(--color-border)]">
      {#if rows.length === 0}
        <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">{t('ordningsbot.empty')}</p>
      {:else}
        <table class="w-full text-xs">
          <thead class="bg-[var(--color-surface)]">
            <tr>
              <th class="px-2 py-1 text-left font-semibold">{t('ordningsbot.field.number')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('ordningsbot.field.status')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('ordningsbot.field.payment')}</th>
            </tr>
          </thead>
          <tbody>
            {#each rows as row, index (index)}
              {#if isStub(row)}
                <tr class="border-t border-[var(--color-border)]">
                  <td class="px-2 py-1 text-[var(--color-ink-muted)]" colspan="3">
                    {t('records.restricted.title')} — {stubContact(row)}
                  </td>
                </tr>
              {:else}
                <tr class="border-t border-[var(--color-border)]">
                  <td class="px-2 py-1 font-[family-name:var(--font-mono)] whitespace-nowrap">
                    <button
                      type="button"
                      class="underline-offset-2 hover:underline"
                      class:font-semibold={detail?.id === row.id}
                      onclick={() => void open(row.id)}
                    >
                      {row.number}
                    </button>
                  </td>
                  <td class="px-2 py-1">{t(`ordningsbot.status.${row.status}`)}</td>
                  <td class="px-2 py-1">
                    {#if row.paymentStatus === 'unpaid' || row.paymentStatus === 'overdue'}
                      <span
                        class:text-[var(--color-alert)]={row.paymentStatus === 'overdue'}
                        class:font-semibold={row.paymentStatus === 'overdue'}
                      >
                        {t(`ordningsbot.payment.${row.paymentStatus}`)}
                      </span>
                    {/if}
                  </td>
                </tr>
              {/if}
            {/each}
          </tbody>
        </table>
      {/if}
    </div>

    <div class="border border-[var(--color-border)] p-3">
      {#if !detail}
        <p class="text-xs text-[var(--color-ink-muted)]">{t('ordningsbot.detail.none')}</p>
      {:else}
        <header class="mb-3">
          <h2 class="font-[family-name:var(--font-mono)] text-sm font-semibold">{detail.number}</h2>
          <p class="text-xs text-[var(--color-ink-muted)]">
            {t(`ordningsbot.status.${detail.status}`)} · {formatMoment(detail.issuedAt)}
          </p>
        </header>

        <!-- A copy of this record, on paper or as a PDF (7.28). -->
        <PrintMenu kind="citation" id={detail.id} />

        {#if detail.tariff}
          <p class="mb-3 text-xs">
            {t('ordningsbot.tariffOption.plain', { name: tariffName(detail.tariff), amount: detail.tariff.amount })}
            {#if licenceOn && (detail.tariff.licencePoints ?? 0) > 0}
              · {t('ordningsbot.points', { points: detail.tariff.licencePoints ?? 0 })}
            {/if}
          </p>
        {/if}

        {#if detail.status === 'issued'}
          <p
            class="mb-3 text-xs"
            class:text-[var(--color-alert)]={detail.paymentStatus === 'overdue'}
            class:font-semibold={detail.paymentStatus === 'overdue'}
          >
            {t(`ordningsbot.payment.${detail.paymentStatus}`)} · {t('ordningsbot.field.dueAt')}: {formatMoment(detail.dueAt)}
          </p>
        {/if}

        {#if detail.status === 'issued' && detail.billedAt}
          <!--
            A billed citation marks itself paid when the bill is, so the
            officer does not have to. Said here, beside the "mark paid"
            button, so nobody presses it for a fine already in hand.
          -->
          <p class="mb-3 text-xs text-[var(--color-ink-muted)]">
            {t('ordningsbot.billSent', { at: formatMoment(detail.billedAt) })}
          </p>
        {/if}

        {#if detail.status === 'void' && detail.voidReasonKey}
          <p class="mb-3 border border-[var(--color-border)] px-2 py-1 text-xs">
            {t(`ordningsbot.voidReason.${detail.voidReasonKey}`)}
          </p>
        {/if}

        {#if detail.status === 'issued'}
          <div class="flex flex-wrap gap-2 border-t border-[var(--color-border)] pt-3">
            <button type="button" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy} onclick={() => void markPaid()}>
              {t('ordningsbot.action.pay')}
            </button>
            <button type="button" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy} onclick={() => void markContested()}>
              {t('ordningsbot.action.contest')}
            </button>
            <button
              type="button"
              class="border border-[var(--color-border)] px-3 py-1 text-xs"
              disabled={busy}
              onclick={(event) => {
                trigger = event.currentTarget;
                voidReasonKey = VOID_REASONS[0];
                confirmingVoid = true;
                failure = null;
              }}
            >
              {t('ordningsbot.action.void')}
            </button>
          </div>
        {/if}

        {#if confirmingVoid}
          <div class="mt-3">
            <ConfirmDialog
              label={t('ordningsbot.action.void')}
              question={t('ordningsbot.confirm.void')}
              {busy}
              {failure}
              fieldLabels={FIELD_LABELS}
              confirm={() => void voidCitation()}
              cancel={cancelConfirm}
            >
              <label class="flex flex-col gap-1 text-xs">
                {t('ordningsbot.voidReason.label')}
                <select bind:value={voidReasonKey} class="border border-[var(--color-border)] px-2 py-1">
                  {#each VOID_REASONS as key (key)}
                    <option value={key}>{t(`ordningsbot.voidReason.${key}`)}</option>
                  {/each}
                </select>
              </label>
            </ConfirmDialog>
          </div>
        {/if}
      {/if}
    </div>
  </div>
</div>
