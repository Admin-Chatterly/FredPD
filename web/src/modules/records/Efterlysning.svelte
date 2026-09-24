<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { EFTERLYSNING_GRUNDER } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import LoadMore from '../shared/LoadMore.svelte';
  import { isStub, type Maybe, type Restricted } from './types';
  import PersonPicker from '../shared/PersonPicker.svelte';

  /**
   * Efterlysning — wanted notices (spec 7.13).
   *
   * This is the Swedish equivalent of the arrest warrant, and the distinction
   * it exists to draw is the one an officer acts on at the roadside:
   *
   *   * **`detainOnSight` is the server's judgement, and only two grounds get
   *     it** — anhållen and häktad i sin frånvaro. Those are the rows the hit
   *     banner treats as officer-safety information. Somebody wanted for
   *     *delgivning*, to be served a document, is not somebody to arrest, and
   *     a missing person is wanted for their own sake. An interface that drew
   *     all three the same way would teach officers to arrest a missing
   *     person, and `Tvang.detainOnSight` exists precisely so it cannot.
   *   * **A notice with no expiry stands until it is cancelled.** That is the
   *     right default for a prosecutor's decision, which does not lapse
   *     because time passed, and the form says so rather than leaving an empty
   *     box that reads like a mistake.
   *
   * Cancelling asks for a ground of its own (`efterlysning.avlysningsgrund`),
   * because "taken into custody" and "withdrawn" are different facts about the
   * same person and the register is read months later.
   */

  interface EfterlysningRow {
    id: number;
    number: string;
    personId: number;
    personNumber?: string | null;
    grund: string;
    frihetId?: number | null;
    fuId?: number | null;
    note?: string | null;
    priority: number;
    issuedBy?: string | null;
    /** Epoch seconds, as `UNIX_TIMESTAMP` sends them. */
    issuedAt?: number | null;
    expiresAt?: number | null;
    cancelledAt?: number | null;
    cancelledBy?: string | null;
    cancelledGrund?: string | null;
    classification: string;
    version: number;
    /** `Tvang.isLive`, computed on the server for every row it sends. */
    live?: boolean;
    /** `Tvang.detainOnSight`. Two grounds out of six, and never inferred here. */
    detainOnSight?: boolean;
  }

  /** Why a notice is lifted. Locale keys, never prose (invariant 6). */
  const AVLYSNINGSGRUNDER = ['gripen', 'aterkallad', 'preskriberad', 'annan'];

  const PRIORITIES = [1, 2, 3, 4];

  /** What the expiry box offers, in days. Absent means "until cancelled". */
  const EXPIRY_DAYS = [7, 30, 90, 365];

  const DAY = 86400;

  let rows = $state<Maybe<EfterlysningRow>[]>([]);
  let nextCursor = $state<string | null>(null);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);
  let includeCancelled = $state(false);
  let grundFilter = $state('');

  let issuing = $state(false);
  let form = $state({
    personId: '',
    grund: '',
    priority: 3,
    note: '',
    /** Empty string is the default and means no expiry. */
    expiryDays: '',
  });

  /** The row being cancelled, and the ground the officer must give. */
  let cancelling = $state<EfterlysningRow | null>(null);
  let cancelGrund = $state('');
  let trigger: HTMLButtonElement | null = null;

  /** What just happened, for the officer who cannot see the row vanish. */
  let status = $state('');

  const REQUIRED_MARK = '*';

  const FIELD_LABELS: Record<string, string> = {
    personId: 'efterlysning.column.person',
    grund: 'efterlysning.column.grund',
    priority: 'efterlysning.column.priority',
    note: 'efterlysning.field.note',
    expiresInSeconds: 'efterlysning.column.expires',
    classification: 'records.person.field.classification',
    version: 'anmalan.column.version',
  };

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  function cancelConfirm(): void {
    cancelling = null;
    failure = null;
    trigger?.focus();
  }

  async function load(reset = true): Promise<void> {
    busy = true;

    const response = await nui.call<{
      efterlysningar: Maybe<EfterlysningRow>[];
      nextCursor?: string | null;
    }>('efterlysning.list', {
      grund: grundFilter || undefined,
      includeCancelled: includeCancelled || undefined,
      limit: 50,
      cursor: reset ? undefined : (nextCursor ?? undefined),
    });

    if (response.ok) {
      const page = response.data.efterlysningar ?? [];
      rows = reset ? page : [...rows, ...page];
      nextCursor = response.data.nextCursor ?? null;
      failure = null;
    } else {
      failure = response;
    }

    busy = false;
  }

  function loadMore(): void {
    void load(false);
  }

  async function issue(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    busy = true;

    const response = await nui.call('efterlysning.create', {
      personId: Number(form.personId) || undefined,
      grund: form.grund || undefined,
      priority: form.priority,
      note: form.note || undefined,
      // Absent, not zero: the schema's floor is an hour, and "no expiry" is
      // the field being missing rather than a value meaning nothing.
      expiresInSeconds: form.expiryDays ? Number(form.expiryDays) * DAY : undefined,
    });

    if (response.ok) {
      failure = null;
      issuing = false;
      form.personId = '';
      form.note = '';
      await load();
    } else {
      failure = response;
      busy = false;
    }
  }

  async function cancel(): Promise<void> {
    const row = cancelling;
    if (!row) return;

    busy = true;

    const response = await nui.call('efterlysning.cancel', {
      id: row.id,
      version: row.version,
      grund: cancelGrund || undefined,
    });

    if (response.ok) {
      failure = null;
      cancelGrund = '';
      // Closed only once the server has agreed. A stale `version` is the
      // likeliest refusal here — the version came from a list loaded before
      // this box opened — and closing first threw away the ground the officer
      // had just chosen along with the explanation.
      cancelling = null;
      // Said out loud, because the row simply disappears from the default
      // list: without this a keyboard officer is returned to the top of the
      // document with no evidence anything happened.
      status = t('efterlysning.lifted', { number: row.number });
      trigger?.focus();
      await load();
    } else {
      failure = response;
      busy = false;
    }
  }

  /** What a row says about itself: live, cancelled, or lapsed. */
  function statusText(row: EfterlysningRow): string {
    if (row.cancelledAt) return t('efterlysning.status.cancelled');
    if (row.live) return t('efterlysning.status.live');

    return t('efterlysning.status.expired');
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
      <input type="checkbox" bind:checked={includeCancelled} />
      {t('efterlysning.filter.includeCancelled')}
    </label>

    <label class="flex flex-col gap-1 text-xs">
      {t('efterlysning.column.grund')}
      <select bind:value={grundFilter} class="border border-[var(--color-border)] px-2 py-1">
        <option value="">{t('form.any')}</option>
        {#each EFTERLYSNING_GRUNDER as grund (grund)}
          <option value={grund}>{t(`efterlysning.grund.${grund}`)}</option>
        {/each}
      </select>
    </label>

    <button
      type="submit"
      class="border border-[var(--color-border)] px-3 py-1 text-xs"
      disabled={busy}
    >
      {t('form.search')}
    </button>

    <button
      type="button"
      class="border border-[var(--color-border)] px-3 py-1 text-xs"
      onclick={() => (issuing = !issuing)}
    >
      {t('efterlysning.action.create')}
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

  {#if issuing}
    <form
      class="flex flex-wrap items-end gap-2 border border-[var(--color-border)] p-3"
      onsubmit={(event) => void issue(event)}
    >
      <div class="flex w-64 flex-col gap-1 text-xs">
        <span id="efterlysning-person-label">{t('efterlysning.field.personId')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
        <PersonPicker bind:value={form.personId} labelledby="efterlysning-person-label" required />
      </div>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('efterlysning.column.grund')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
        <select
          bind:value={form.grund}
          required
          aria-required="true"
          class="border border-[var(--color-border)] px-2 py-1"
        >
          <option value="">{t('efterlysning.field.grundChoose')}</option>
          {#each EFTERLYSNING_GRUNDER as grund (grund)}
            <option value={grund}>{t(`efterlysning.grund.${grund}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        {t('efterlysning.column.priority')}
        <select bind:value={form.priority} class="border border-[var(--color-border)] px-2 py-1">
          {#each PRIORITIES as level (level)}
            <option value={level}>{t(`efterlysning.priority.${level}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        {t('efterlysning.column.expires')}
        <select bind:value={form.expiryDays} class="border border-[var(--color-border)] px-2 py-1">
          <!--
            The default, and it is not "none missing": a prosecutor's decision
            to detain somebody does not lapse because three months went by, so
            the notice stands until it is lifted.
          -->
          <option value="">{t('efterlysning.field.noExpiry')}</option>
          {#each EXPIRY_DAYS as days (days)}
            <option value={String(days)}>
              {t('efterlysning.field.expiryDays', { count: String(days) })}
            </option>
          {/each}
        </select>
      </label>

      <label class="flex flex-1 flex-col gap-1 text-xs">
        {t('efterlysning.field.note')}
        <input
          bind:value={form.note}
          maxlength="500"
          class="border border-[var(--color-border)] px-2 py-1"
        />
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1 text-xs"
        disabled={busy}
      >
        {t('efterlysning.action.create')}
      </button>
    </form>
  {/if}

  {#if status}
    <p class="text-xs text-[var(--color-ink-muted)]" role="status">{status}</p>
  {/if}

  {#if cancelling}
    <ConfirmDialog
      label={t('efterlysning.action.cancel')}
      question={t('efterlysning.confirm.cancel', { number: cancelling.number })}
      {busy}
      {failure}
      fieldLabels={FIELD_LABELS}
      confirm={() => void cancel()}
      cancel={cancelConfirm}
    >
      <label class="mt-2 flex flex-col gap-1">
        <span>{t('efterlysning.field.avlysningsgrund')}</span>
        <select
          bind:value={cancelGrund}
          class="w-64 border border-[var(--color-border)] px-2 py-1"
        >
          <option value="">{t('efterlysning.field.avlysningsgrundChoose')}</option>
          {#each AVLYSNINGSGRUNDER as key (key)}
            <option value={key}>{t(`efterlysning.avlysningsgrund.${key}`)}</option>
          {/each}
        </select>
      </label>
    </ConfirmDialog>
  {/if}

  <div class="border border-[var(--color-border)]">
    {#if rows.length === 0}
      <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">{t('efterlysning.empty')}</p>
    {:else}
      <div class="overflow-x-auto">
        <table class="w-full text-xs">
          <thead class="bg-[var(--color-surface)]">
            <tr>
              <th class="px-2 py-1 text-left font-semibold">{t('efterlysning.column.number')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('efterlysning.column.person')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('efterlysning.column.grund')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('efterlysning.column.issued')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('efterlysning.column.expires')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('tvang.column.status')}</th>
              <th class="px-2 py-1 text-left font-semibold"><span class="sr-only">{t('efterlysning.action.cancel')}</span></th>
            </tr>
          </thead>
          <tbody>
            <!-- Keyed by index: a stub carries no id (4.5). -->
            {#each rows as row, index (index)}
              {#if isStub(row)}
                <tr class="border-t border-[var(--color-border)]">
                  <td class="px-2 py-1 text-[var(--color-ink-muted)]" colspan="7">
                    {t('records.restricted.title')} — {stubContact(row)}
                  </td>
                </tr>
              {:else}
                <tr class="border-t border-[var(--color-border)]">
                  <td class="px-2 py-1 font-[family-name:var(--font-mono)] whitespace-nowrap">
                    {row.number}
                  </td>
                  <td class="px-2 py-1 font-[family-name:var(--font-mono)] whitespace-nowrap">
                    {row.personNumber ?? ''}
                  </td>
                  <td class="px-2 py-1">
                    {t(`efterlysning.grund.${row.grund}`)}
                    <!--
                      The line that changes what the officer does. Drawn from
                      the server's `detainOnSight` and never from the ground
                      read here: two of the six mean arrest and the other four
                      emphatically do not, and an officer who is told "wanted"
                      for all six will treat all six the same way.
                    -->
                    {#if row.live && row.detainOnSight}
                      <span class="ml-1 font-semibold text-[var(--color-alert)]">
                        {t('efterlysning.detainOnSight')}
                      </span>
                    {:else if row.live}
                      <span class="ml-1 text-[var(--color-ink-muted)]">
                        {t('efterlysning.notAnArrest')}
                      </span>
                    {/if}
                  </td>
                  <td class="px-2 py-1 font-[family-name:var(--font-mono)] whitespace-nowrap">
                    {formatMoment(row.issuedAt ?? null)}
                  </td>
                  <td class="px-2 py-1 font-[family-name:var(--font-mono)] whitespace-nowrap">
                    {row.expiresAt ? formatMoment(row.expiresAt) : t('efterlysning.field.noExpiry')}
                  </td>
                  <td class="px-2 py-1 whitespace-nowrap">
                    <span class:text-[var(--color-ink-muted)]={!row.live}>{statusText(row)}</span>
                  </td>
                  <td class="px-2 py-1 whitespace-nowrap">
                    {#if !row.cancelledAt}
                      <button
                        type="button"
                        class="border border-[var(--color-border)] px-2 py-0.5"
                        disabled={busy}
                        onclick={(event) => {
                          trigger = event.currentTarget;
                          cancelling = row;
                          cancelGrund = '';
                          failure = null;
                          status = '';
                        }}
                      >
                        {t('efterlysning.action.cancel')}
                      </button>
                    {:else if row.cancelledGrund}
                      <span class="text-[var(--color-ink-muted)]">
                        {t(`efterlysning.avlysningsgrund.${row.cancelledGrund}`)}
                      </span>
                    {/if}
                  </td>
                </tr>
              {/if}
            {/each}
          </tbody>
        </table>
      </div>
      <LoadMore {nextCursor} {busy} {loadMore} />
    {/if}
  </div>
</div>
