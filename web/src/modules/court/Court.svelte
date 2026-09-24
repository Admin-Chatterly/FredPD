<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import { isStub, type Maybe, type Restricted } from '../records/types';
  import ChargePicker from '../shared/ChargePicker.svelte';

  /**
   * Åtal och dom — the prosecutor's charging decision and the court's
   * disposition (spec 7.20).
   *
   * `frihet.haktning` already covers the häktningsförhandling; this screen
   * starts where that module has nothing left to say: a redovisad
   * förundersökning, waiting on an åklagare to decide whether to väcka åtal
   * at all.
   *
   * Two decision-makers, drawn as two different actions in two different
   * places on the same detail panel — never as one form with a picker,
   * because offering both invites the officer to guess which one is theirs
   * to press. The server alone knows: `court.referral.decide` and
   * `court.disposition.enter` each refuse `wrong_capacity` on their own, and
   * a domare who also holds the read permission still cannot reach the
   * first one.
   *
   * The sentencing range (`straffskala`) is the server's own answer from
   * `Brott.gemensamStraffskala`, sent on `court.referral.get` — never
   * recomputed here, the same rule every other charge screen in this suite
   * follows.
   */

  interface Charge {
    id: number;
    brottId: number;
    stage: string;
    code: string;
    labelKey: string;
    balk: string | null;
    kapitel: number | null;
    paragraf: string | null;
  }

  interface Straffskala {
    boter: boolean;
    min: number;
    max: number | null;
  }

  interface AtalRow {
    id: number;
    number: string;
    fuId: number;
    beslut: string;
    beslutGrund?: string | null;
    decidedBy?: string | null;
    decidedAt?: number | null;
    disposition?: string | null;
    sentenceMonths?: number | null;
    sentenceLivstid?: boolean;
    dispositionNote?: string | null;
    dispositionBy?: string | null;
    dispositionAt?: number | null;
    classification: string;
    version: number;
    charges?: Charge[];
    straffskala?: Straffskala | null;
  }

  interface PendingFu {
    id: number;
    number: string;
    title: string;
  }

  const BESLUT_GRUNDER = ['otillrackliga_bevis', 'ej_brott', 'preskriberat', 'annan'];
  const DISPOSITIONS = ['guilty', 'not_guilty', 'dismissed', 'plea'];

  let rows = $state<Maybe<AtalRow>[]>([]);
  let pending = $state<PendingFu[]>([]);
  let detail = $state<AtalRow | null>(null);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);
  let beslutFilter = $state('');
  let showPending = $state(false);
  let openId = $state<number | null>(null);

  let deciding = $state<PendingFu | null>(null);
  let decideForm = $state({ beslut: 'atalad', beslutGrund: '', brottIds: [] as number[] });

  let confirmingDecide = $state(false);
  let confirmingDisposition = $state(false);
  let trigger: HTMLButtonElement | null = null;

  let status = $state('');

  let dispositionForm = $state({ disposition: 'guilty', sentenceMonths: 12, sentenceLivstid: false, note: '' });

  const REQUIRED_MARK = '*';

  const FIELD_LABELS: Record<string, string> = {
    _input: 'court.column.beslut',
    fuId: 'court.field.fuId',
    beslut: 'court.field.beslutChoose',
    beslutGrund: 'court.field.beslutGrundChoose',
    brottIds: 'court.field.brottIds',
    disposition: 'court.field.dispositionChoose',
    sentenceMonths: 'court.field.sentenceMonths',
    version: 'anmalan.column.version',
    classification: 'records.person.field.classification',
  };

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  function cancelConfirm(): void {
    confirmingDecide = false;
    confirmingDisposition = false;
    deciding = null;
    failure = null;
    trigger?.focus();
  }

  async function load(): Promise<void> {
    busy = true;

    const response = await nui.call<{ atal: Maybe<AtalRow>[] }>('court.referral.list', {
      beslut: beslutFilter || undefined,
      limit: 50,
    });

    if (response.ok) {
      rows = response.data.atal ?? [];
      failure = null;
    } else {
      failure = response;
    }

    busy = false;
  }

  async function loadPending(): Promise<void> {
    const response = await nui.call<{ forundersokningar: PendingFu[] }>('court.referral.pending', {});

    if (response.ok) {
      pending = response.data.forundersokningar ?? [];
      failure = null;
    } else {
      failure = response;
    }
  }

  async function open(id: number): Promise<void> {
    busy = true;
    confirmingDisposition = false;

    const response = await nui.call<{ atal: AtalRow }>('court.referral.get', { id });

    if (response.ok) {
      detail = response.data.atal;
      openId = id;
      failure = null;
    } else {
      detail = null;
      openId = null;
      failure = response;
    }

    busy = false;
  }

  async function decide(): Promise<void> {
    if (!deciding) return;

    busy = true;
    const fu = deciding;

    // Picked from the catalogue (ChargePicker), sent as the route takes them.
    const brottIds = decideForm.brottIds.map(String);

    const response = await nui.call<{ id: number; number: string }>('court.referral.decide', {
      fuId: fu.id,
      beslut: decideForm.beslut,
      beslutGrund: decideForm.beslut === 'ej_atal' ? decideForm.beslutGrund || undefined : undefined,
      brottIds: decideForm.beslut === 'atalad' ? brottIds : undefined,
    });

    if (response.ok) {
      failure = null;
      confirmingDecide = false;
      deciding = null;
      status =
        decideForm.beslut === 'atalad'
          ? t('court.charged', { number: response.data.number })
          : t('court.declined', { number: response.data.number });
      decideForm = { beslut: 'atalad', beslutGrund: '', brottIds: [] as number[] };
      await Promise.all([load(), loadPending(), open(response.data.id)]);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function enterDisposition(): Promise<void> {
    if (!detail) return;

    busy = true;
    const id = detail.id;
    const number = detail.number;

    const response = await nui.call('court.disposition.enter', {
      id,
      version: detail.version,
      disposition: dispositionForm.disposition,
      sentenceMonths: dispositionForm.sentenceLivstid ? undefined : dispositionForm.sentenceMonths,
      sentenceLivstid: dispositionForm.sentenceLivstid || undefined,
      note: dispositionForm.note || undefined,
    });

    if (response.ok) {
      failure = null;
      confirmingDisposition = false;
      status = t('court.disposed', { number });
      trigger?.focus();
      await Promise.all([open(id), load()]);
    } else {
      failure = response;
      busy = false;
    }
  }

  /** `Brott.gemensamStraffskala`'s answer, in months — the server's own figure. */
  function straffskalaText(skala: Straffskala | null | undefined): string {
    if (!skala) return t('court.straffskala.none');

    const max = skala.max === null ? '∞' : String(skala.max);

    return `${skala.min}–${max}`;
  }

  function stubContact(row: Restricted): string {
    return t('records.restricted.contact', { unit: t(`access.unit.${row.contact}`) });
  }

  void load();
  void loadPending();
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
      {t('court.column.beslut')}
      <select bind:value={beslutFilter} class="border border-[var(--color-border)] px-2 py-1">
        <option value="">{t('form.any')}</option>
        {#each ['atalad', 'ej_atal'] as key (key)}
          <option value={key}>{t(`court.beslut.${key}`)}</option>
        {/each}
      </select>
    </label>

    <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
      {t('form.search')}
    </button>

    <button
      type="button"
      class="border border-[var(--color-border)] px-3 py-1 text-xs"
      onclick={() => (showPending = !showPending)}
    >
      {t('court.pendingTitle')}
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

  {#if showPending}
    <div class="border border-[var(--color-border)] p-3">
      <h3 class="mb-2 text-xs font-semibold">{t('court.pendingTitle')}</h3>

      {#if pending.length === 0}
        <p class="text-xs text-[var(--color-ink-muted)]">{t('court.pendingEmpty')}</p>
      {:else}
        <ul class="flex flex-col gap-1 text-xs">
          {#each pending as fu (fu.id)}
            <li class="flex items-center justify-between border-t border-[var(--color-border)] py-1">
              <span>{fu.number} — {fu.title}</span>
              <button
                type="button"
                class="border border-[var(--color-border)] px-2 py-0.5"
                onclick={() => {
                  deciding = fu;
                  decideForm = { beslut: 'atalad', beslutGrund: '', brottIds: [] as number[] };
                  confirmingDecide = false;
                  failure = null;
                }}
              >
                {t('court.action.decide')}
              </button>
            </li>
          {/each}
        </ul>
      {/if}

      {#if deciding}
        <form
          class="mt-3 flex flex-wrap items-end gap-2 border-t border-[var(--color-border)] pt-3"
          onsubmit={(event) => {
            event.preventDefault();
            confirmingDecide = true;
            failure = null;
            status = '';
          }}
        >
          <p class="w-full text-xs text-[var(--color-ink-muted)]">
            {deciding.number} — {deciding.title}
          </p>

          <label class="flex flex-col gap-1 text-xs">
            {t('court.field.beslutChoose')}
            <select bind:value={decideForm.beslut} class="border border-[var(--color-border)] px-2 py-1">
              {#each ['atalad', 'ej_atal'] as key (key)}
                <option value={key}>{t(`court.beslut.${key}`)}</option>
              {/each}
            </select>
          </label>

          {#if decideForm.beslut === 'atalad'}
            <div class="min-w-64 flex-1">
              <ChargePicker
                bind:selected={decideForm.brottIds}
                legend={t('court.field.brottIds')}
                required
                disabled={busy}
              />
            </div>
          {:else}
            <label class="flex flex-col gap-1 text-xs">
              <span>{t('court.field.beslutGrundChoose')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
              <select
                bind:value={decideForm.beslutGrund}
                required
                aria-required="true"
                class="border border-[var(--color-border)] px-2 py-1"
              >
                <option value="">{t('court.field.beslutGrundChoose')}</option>
                {#each BESLUT_GRUNDER as key (key)}
                  <option value={key}>{t(`court.beslutGrund.${key}`)}</option>
                {/each}
              </select>
            </label>
          {/if}

          <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
            {t('court.action.decide')}
          </button>
        </form>

        {#if confirmingDecide}
          <div class="mt-2">
            <ConfirmDialog
              label={t('court.action.decide')}
              question={decideForm.beslut === 'atalad' ? t('court.confirm.charge') : t('court.confirm.decline')}
              {busy}
              {failure}
              fieldLabels={FIELD_LABELS}
              confirm={() => void decide()}
              cancel={cancelConfirm}
            />
          </div>
        {/if}
      {/if}
    </div>
  {/if}

  {#if status}
    <p class="text-xs text-[var(--color-ink-muted)]" role="status">{status}</p>
  {/if}

  <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
    <div class="border border-[var(--color-border)]">
      {#if rows.length === 0}
        <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">{t('court.empty')}</p>
      {:else}
        <div class="overflow-x-auto">
          <table class="w-full text-xs">
            <thead class="bg-[var(--color-surface)]">
              <tr>
                <th class="px-2 py-1 text-left font-semibold">{t('court.column.number')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('court.column.beslut')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('court.column.disposition')}</th>
              </tr>
            </thead>
            <tbody>
              <!-- Keyed by index: a stub carries no id (4.5). -->
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
                        class:font-semibold={openId === row.id}
                        onclick={() => void open(row.id)}
                      >
                        {row.number}
                      </button>
                    </td>
                    <td class="px-2 py-1">{t(`court.beslut.${row.beslut}`)}</td>
                    <td class="px-2 py-1">
                      {row.disposition ? t(`court.disposition.${row.disposition}`) : t('court.disposition.pending')}
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
        <p class="text-xs text-[var(--color-ink-muted)]">{t('court.detail.none')}</p>
      {:else}
        <header class="mb-3">
          <h2 class="font-[family-name:var(--font-mono)] text-sm font-semibold">
            {detail.number}
          </h2>
          <p class="text-xs text-[var(--color-ink-muted)]">
            {t(`court.beslut.${detail.beslut}`)}
          </p>
        </header>

        {#if detail.beslut === 'ej_atal' && detail.beslutGrund}
          <p class="mb-3 border border-[var(--color-border)] px-2 py-1 text-xs">
            {t(`court.beslutGrund.${detail.beslutGrund}`)}
          </p>
        {/if}

        {#if detail.charges && detail.charges.length > 0}
          <section class="mb-3">
            <h3 class="mb-1 text-xs font-semibold">{t('court.field.brottIds')}</h3>
            <ul class="text-xs">
              {#each detail.charges as charge (charge.id)}
                <li>{charge.code} — {t(charge.labelKey)}</li>
              {/each}
            </ul>
            <p class="mt-1 text-xs text-[var(--color-ink-muted)]">
              {t('court.straffskala.title')}: {straffskalaText(detail.straffskala)}
            </p>
          </section>
        {/if}

        {#if detail.beslut === 'atalad'}
          {#if detail.disposition}
            <dl class="mb-3 text-xs">
              <div class="flex justify-between border-t border-[var(--color-border)] py-1">
                <dt>{t('court.field.disposition')}</dt>
                <dd>{t(`court.disposition.${detail.disposition}`)}</dd>
              </div>
              {#if detail.sentenceLivstid}
                <div class="flex justify-between border-t border-[var(--color-border)] py-1">
                  <dt>{t('court.field.sentenceMonths')}</dt>
                  <dd>{t('court.field.sentenceLivstid')}</dd>
                </div>
              {:else if detail.sentenceMonths !== null && detail.sentenceMonths !== undefined}
                <div class="flex justify-between border-t border-[var(--color-border)] py-1">
                  <dt>{t('court.field.sentenceMonths')}</dt>
                  <dd>{detail.sentenceMonths}</dd>
                </div>
              {/if}
              <div class="flex justify-between border-t border-[var(--color-border)] py-1">
                <dt>{t('court.column.decided')}</dt>
                <dd class="font-[family-name:var(--font-mono)]">{formatMoment(detail.dispositionAt ?? null)}</dd>
              </div>
            </dl>
          {:else}
            <section class="border-t border-[var(--color-border)] pt-3">
              {#if confirmingDisposition}
                <ConfirmDialog
                  label={t('court.action.enterDisposition')}
                  question={t('court.confirm.enterDisposition')}
                  {busy}
                  {failure}
                  fieldLabels={FIELD_LABELS}
                  confirm={() => void enterDisposition()}
                  cancel={cancelConfirm}
                >
                    <label class="flex flex-col gap-1 text-xs">
                      {t('court.field.dispositionChoose')}
                      <select
                        bind:value={dispositionForm.disposition}
                        class="border border-[var(--color-border)] px-2 py-1"
                      >
                        {#each DISPOSITIONS as key (key)}
                          <option value={key}>{t(`court.disposition.${key}`)}</option>
                        {/each}
                      </select>
                    </label>
                    {#if dispositionForm.disposition === 'guilty' || dispositionForm.disposition === 'plea'}
                      <label class="flex items-center gap-1 text-xs">
                        <input type="checkbox" bind:checked={dispositionForm.sentenceLivstid} />
                        {t('court.field.sentenceLivstid')}
                      </label>
                      {#if !dispositionForm.sentenceLivstid}
                        <label class="flex flex-col gap-1 text-xs">
                          {t('court.field.sentenceMonths')}
                          <input
                            type="number"
                            bind:value={dispositionForm.sentenceMonths}
                            min="0"
                            max="216"
                            class="w-24 border border-[var(--color-border)] px-2 py-1"
                          />
                        </label>
                      {/if}
                    {/if}
                    <label class="flex flex-col gap-1 text-xs">
                      {t('court.field.note')}
                      <input
                        bind:value={dispositionForm.note}
                        maxlength="500"
                        class="border border-[var(--color-border)] px-2 py-1"
                      />
                    </label>
                </ConfirmDialog>
              {:else}
                <button
                  type="button"
                  class="border border-[var(--color-border)] px-3 py-1 text-xs"
                  disabled={busy}
                  onclick={(event) => {
                    trigger = event.currentTarget;
                    confirmingDisposition = true;
                    failure = null;
                    status = '';
                  }}
                >
                  {t('court.action.enterDisposition')}
                </button>
              {/if}
            </section>
          {/if}
        {:else}
          <p class="text-xs text-[var(--color-ink-muted)]">{t('court.notAtalad')}</p>
        {/if}
      {/if}
    </div>
  </div>
</div>
