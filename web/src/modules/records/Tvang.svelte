<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { TVANG_KINDS, TVANG_TARGETS } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import LoadMore from '../shared/LoadMore.svelte';
  import { isStub, type Maybe, type Restricted } from './types';
  import PersonPicker from '../shared/PersonPicker.svelte';
  import VehiclePicker from '../shared/VehiclePicker.svelte';

  /**
   * Tvångsmedel — coercive measures under RB 27–28 (spec 7.12).
   *
   * A husrannsakan is a decision to enter somebody's home, and this screen is
   * where one is taken, carried out and revoked. Three things follow from that
   * and they are the whole design:
   *
   *   * **Liveness is the server's answer and is never recomputed here.**
   *     `tvang.list` and `tvang.get` send `live`, and `get` also sends
   *     `notLiveBecause` — `upphavd`, `not_yet` or `expired`. The same
   *     `Tvang.isValid` answers `HasSearchWarrant`, which is what `ox_doorlock`
   *     asks before it opens a door. A second implementation in a browser would
   *     be the one nobody tested, and it would disagree with the door.
   *   * **The window is drawn as two timestamps, not as a countdown.** These
   *     routes send no `remaining`, so a countdown would be this workstation's
   *     clock doing arithmetic on a validity it does not own. The custody
   *     screen ticks because the server sends it something to tick; this one
   *     has nothing of the sort and says what it knows instead.
   *   * **Who may decide what is a capacity, not a rank.** The server derives
   *     it from the session's permissions and refuses with `wrong_capacity` on
   *     the `kind` field — a kroppsbesiktning needs at least a prosecutor. That
   *     refusal reads as "that decision is not yours to take", never as a
   *     Discord role problem (invariant 4, spec 6.4).
   *
   * What the screen *does* decide is which target kinds to offer for a chosen
   * measure, and that mirrors `Tvang.validate` rather than replacing it: a
   * husrannsakan is directed at a place and a kroppsvisitation at a person. The
   * server still refuses anything this gets wrong; offering the impossible
   * option would just be a form whose only outcome is a refusal.
   */

  interface TvangRow {
    id: number;
    number: string;
    kind: string;
    targetKind: string;
    targetId: number;
    targetLabel?: string | null;
    fuId?: number | null;
    decidedBy?: string | null;
    deciderKind: string;
    grund: string;
    scope?: string | null;
    /** Epoch seconds, as `UNIX_TIMESTAMP` sends them. */
    validFrom?: number | null;
    validUntil?: number | null;
    verkstalldAt?: number | null;
    verkstalldBy?: string | null;
    verkstalldNote?: string | null;
    upphavdAt?: number | null;
    upphavdBy?: string | null;
    classification: string;
    version: number;
    /** `Tvang.isValid`, computed on the server for every row it sends. */
    live?: boolean;
    /** Why not, on `tvang.get` only: `upphavd`, `not_yet`, `expired`. */
    notLiveBecause?: string | null;
  }

  /**
   * Which targets each measure may be directed at.
   *
   * Mirrors the two rules in `Tvang.validate`. A husrannsakan pointed at a
   * person is how a decision to search a flat ends up authorising a search of
   * whoever is standing in it, and a kroppsvisitation pointed at an address is
   * the same mistake facing the other way.
   */
  const TARGETS_FOR: Record<string, readonly string[]> = {
    husrannsakan_reell: ['address', 'vehicle'],
    husrannsakan_personell: ['address', 'vehicle'],
    kroppsvisitation: ['person'],
    kroppsbesiktning: ['person'],
    beslag: TVANG_TARGETS,
  };

  /** The grounds RB gives for these measures. Locale keys, never prose. */
  const GRUNDER = [
    'skalig_misstanke',
    'sannolika_skal',
    'eftersokande_person',
    'sakra_bevis',
    'fara_i_drojsmal',
    'annan',
  ];

  /** How long a measure may run. Hours, bounded by `TvangDecide`'s schema. */
  const VALIDITY_HOURS = [24, 72, 168, 720];

  const HOUR = 3600;

  let rows = $state<Maybe<TvangRow>[]>([]);
  let nextCursor = $state<string | null>(null);
  let detail = $state<TvangRow | null>(null);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);
  let liveOnly = $state(true);
  let kindFilter = $state('');
  let openId = $state<number | null>(null);

  /** The revocation dialog, and the button that opened it (6.4). */
  let confirmingUpphav = $state(false);
  let trigger: HTMLButtonElement | null = null;

  /** What just happened, for the officer who cannot see the list change. */
  let status = $state('');

  let verkstallNote = $state('');

  /** The decide form. Open only when the officer asks for it. */
  let deciding = $state(false);
  let form = $state({
    kind: TVANG_KINDS[0] as string,
    targetKind: 'address',
    targetId: '',
    targetLabel: '',
    grund: '',
    scope: '',
    validHours: 168,
  });

  const REQUIRED_MARK = '*';

  /** Which field a rejected code belongs to (spec 3.5). */
  const FIELD_LABELS: Record<string, string> = {
    kind: 'tvang.column.kind',
    targetKind: 'tvang.column.target',
    targetId: 'tvang.column.target',
    grund: 'tvang.field.grund',
    scope: 'tvang.column.scope',
    classification: 'records.person.field.classification',
    status: 'tvang.column.status',
    version: 'anmalan.column.version',
    validSeconds: 'tvang.field.valid',
  };

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  /** The targets the chosen measure may be aimed at. */
  const targetOptions = $derived(TARGETS_FOR[form.kind] ?? TVANG_TARGETS);

  /**
   * Keeps the target kind honest when the measure changes.
   *
   * Picking kroppsbesiktning after filling in an address would otherwise leave
   * `address` selected and send a request the server refuses with
   * `not_a_person` — a refusal the officer earned by changing one field.
   */
  $effect(() => {
    if (!targetOptions.includes(form.targetKind)) {
      form.targetKind = targetOptions[0] ?? 'person';
    }
  });

  function cancelConfirm(): void {
    confirmingUpphav = false;
    failure = null;
    trigger?.focus();
  }

  async function load(reset = true): Promise<void> {
    busy = true;

    const response = await nui.call<{ tvangsmedel: Maybe<TvangRow>[]; nextCursor?: string | null }>(
      'tvang.list',
      {
        kind: kindFilter || undefined,
        liveOnly: liveOnly || undefined,
        limit: 50,
        cursor: reset ? undefined : (nextCursor ?? undefined),
      },
    );

    if (response.ok) {
      const page = response.data.tvangsmedel ?? [];
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

  async function open(id: number): Promise<void> {
    busy = true;
    confirmingUpphav = false;
    verkstallNote = '';

    const response = await nui.call<{ tvangsmedel: TvangRow }>('tvang.get', { id });

    if (response.ok) {
      detail = response.data.tvangsmedel;
      openId = id;
      failure = null;
    } else {
      detail = null;
      openId = null;
      failure = response;
    }

    busy = false;
  }

  async function decide(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    busy = true;

    const response = await nui.call<{ id: number }>('tvang.decide', {
      kind: form.kind,
      targetKind: form.targetKind,
      targetId: Number(form.targetId) || undefined,
      targetLabel: form.targetLabel || undefined,
      grund: form.grund || undefined,
      scope: form.scope || undefined,
      validSeconds: form.validHours * HOUR,
    });

    if (response.ok) {
      failure = null;
      deciding = false;
      form.targetId = '';
      form.targetLabel = '';
      form.scope = '';
      await Promise.all([load(), open(response.data.id)]);
    } else {
      failure = response;
      busy = false;
    }
  }

  /**
   * Records that a measure was carried out.
   *
   * Not a state change: RB allows a husrannsakan to be resumed, so the measure
   * stays valid afterwards. A second press is not an error either — the server
   * keeps the first execution as the recorded one and says `alreadyRecorded`.
   */
  async function verkstall(): Promise<void> {
    if (!detail) return;

    busy = true;
    const id = detail.id;

    const response = await nui.call('tvang.verkstall', {
      id,
      note: verkstallNote || undefined,
    });

    if (response.ok) {
      failure = null;
      verkstallNote = '';
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

    const response = await nui.call('tvang.upphav', { id, version: detail.version });

    if (response.ok) {
      failure = null;
      // Closed once the server has agreed. `version` came from a read that
      // may be minutes old, so `conflict` is the likeliest answer of all here
      // and it belongs in the dialog rather than behind it.
      confirmingUpphav = false;
      status = t('tvang.revoked', { number });
      trigger?.focus();
      // Neither read depends on the other.
      await Promise.all([open(id), load()]);
    } else {
      failure = response;
      busy = false;
    }
  }

  /**
   * What a row's status says, in the server's own word.
   *
   * `live` is a boolean on every row; `notLiveBecause` arrives only on the
   * detail read, so a list row that is not live says just that rather than
   * guessing at a reason it was not sent.
   */
  function statusText(row: TvangRow): string {
    if (row.live) return t('tvang.status.live');
    if (row.notLiveBecause) return t(`tvang.status.${row.notLiveBecause}`);

    return t('tvang.status.notLive');
  }

  /** The target as a line: the label the decision carried, or the record's id. */
  function targetText(row: TvangRow): string {
    const kind = t(`tvang.target.${row.targetKind}`);

    return row.targetLabel ? `${kind} — ${row.targetLabel}` : `${kind} #${row.targetId}`;
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
      {t('tvang.column.kind')}
      <select bind:value={kindFilter} class="border border-[var(--color-border)] px-2 py-1">
        <option value="">{t('form.any')}</option>
        {#each TVANG_KINDS as kind (kind)}
          <option value={kind}>{t(`tvang.kind.${kind}`)}</option>
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
      onclick={() => (deciding = !deciding)}
    >
      {t('tvang.action.decide')}
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

  {#if deciding}
    <!--
      Deciding a measure. The ground and the scope sit together because they
      are what a court reads afterwards: the ground is why, and the scope is
      how far — "the kitchen and the outbuilding", not "the property".
    -->
    <form
      class="flex flex-wrap items-end gap-2 border border-[var(--color-border)] p-3"
      onsubmit={(event) => void decide(event)}
    >
      <label class="flex flex-col gap-1 text-xs">
        {t('tvang.column.kind')}
        <select bind:value={form.kind} class="border border-[var(--color-border)] px-2 py-1">
          {#each TVANG_KINDS as kind (kind)}
            <option value={kind}>{t(`tvang.kind.${kind}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        {t('tvang.column.target')}
        <!-- A new kind clears the record: a person's id is not a vehicle's. -->
        <select
          bind:value={form.targetKind}
          onchange={() => (form.targetId = '')}
          class="border border-[var(--color-border)] px-2 py-1"
        >
          {#each targetOptions as target (target)}
            <option value={target}>{t(`tvang.target.${target}`)}</option>
          {/each}
        </select>
      </label>

      {#if form.targetKind === 'person' || form.targetKind === 'vehicle'}
        <div class="flex w-64 flex-col gap-1 text-xs">
          <span id="tvang-target-label">{t('tvang.field.targetId')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
          {#if form.targetKind === 'person'}
            <PersonPicker bind:value={form.targetId} labelledby="tvang-target-label" required />
          {:else}
            <VehiclePicker bind:value={form.targetId} labelledby="tvang-target-label" required />
          {/if}
        </div>
      {:else}
        <label class="flex flex-col gap-1 text-xs">
          <span>{t('tvang.field.targetId')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
          <input
            bind:value={form.targetId}
            inputmode="numeric"
            required
            aria-required="true"
            class="w-24 border border-[var(--color-border)] px-2 py-1"
          />
        </label>
      {/if}

      <label class="flex flex-col gap-1 text-xs">
        {t('tvang.field.targetLabel')}
        <input
          bind:value={form.targetLabel}
          maxlength="191"
          class="w-56 border border-[var(--color-border)] px-2 py-1"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('tvang.field.grund')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
        <select
          bind:value={form.grund}
          required
          aria-required="true"
          class="border border-[var(--color-border)] px-2 py-1"
        >
          <option value="">{t('tvang.field.grundChoose')}</option>
          {#each GRUNDER as key (key)}
            <option value={key}>{t(`tvang.grund.${key}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        {t('tvang.field.valid')}
        <select
          bind:value={form.validHours}
          class="border border-[var(--color-border)] px-2 py-1"
        >
          {#each VALIDITY_HOURS as hours (hours)}
            <!--
              Past three days the figure is read as days: "720 h" is a month
              and nobody reads it as one.
            -->
            <option value={hours}>
              {hours % 24 === 0 && hours > 72
                ? t('tvang.field.validDays', { count: String(hours / 24) })
                : t('tvang.field.validHours', { count: String(hours) })}
            </option>
          {/each}
        </select>
      </label>

      <label class="flex flex-1 flex-col gap-1 text-xs">
        {t('tvang.column.scope')}
        <input
          bind:value={form.scope}
          maxlength="500"
          class="border border-[var(--color-border)] px-2 py-1"
        />
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1 text-xs"
        disabled={busy}
      >
        {t('tvang.action.decide')}
      </button>
    </form>
  {/if}

  {#if status}
    <p class="text-xs text-[var(--color-ink-muted)]" role="status">{status}</p>
  {/if}

  <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
    <div class="border border-[var(--color-border)]">
      {#if rows.length === 0}
        <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">{t('tvang.empty')}</p>
      {:else}
        <div class="overflow-x-auto">
          <table class="w-full text-xs">
            <thead class="bg-[var(--color-surface)]">
              <tr>
                <th class="px-2 py-1 text-left font-semibold">{t('tvang.column.number')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('tvang.column.kind')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('tvang.column.target')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('tvang.column.status')}</th>
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
                    <td class="px-2 py-1">{t(`tvang.kind.${row.kind}`)}</td>
                    <td class="px-2 py-1">{targetText(row)}</td>
                    <td class="px-2 py-1 whitespace-nowrap">
                      <!--
                        A measure that no longer authorises anything is not
                        merely greyer: an officer reading this list is deciding
                        whether they may enter, and colour alone is not a
                        signal every officer receives (6.2).
                      -->
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
        <LoadMore {nextCursor} {busy} {loadMore} />
      {/if}
    </div>

    <div class="border border-[var(--color-border)] p-3">
      {#if !detail}
        <p class="text-xs text-[var(--color-ink-muted)]">{t('tvang.detail.none')}</p>
      {:else}
        <header class="mb-3">
          <h2 class="font-[family-name:var(--font-mono)] text-sm font-semibold">
            {detail.number}
          </h2>
          <p class="text-xs text-[var(--color-ink-muted)]">
            {t(`tvang.kind.${detail.kind}`)} · {targetText(detail)}
          </p>
        </header>

        {#if !detail.live}
          <!--
            Says which way it stopped being valid. "Not valid" covers a measure
            that has lapsed, one that has not started, and one a prosecutor
            revoked an hour ago — and the third is the one an officer standing
            at a door needs to be told about plainly.
          -->
          <p class="mb-3 border border-[var(--color-alert)] px-2 py-1 text-xs" role="alert">
            {t('tvang.notLive', { reason: statusText(detail) })}
          </p>
        {/if}

        <dl class="mb-3 text-xs">
          <div class="flex justify-between border-t border-[var(--color-border)] py-1">
            <dt>{t('tvang.column.status')}</dt>
            <dd>{statusText(detail)}</dd>
          </div>
          <div class="flex justify-between border-t border-[var(--color-border)] py-1">
            <dt>{t('tvang.field.grund')}</dt>
            <dd>{t(`tvang.grund.${detail.grund}`)}</dd>
          </div>
          <div class="flex justify-between border-t border-[var(--color-border)] py-1">
            <dt>{t('tvang.column.decided')}</dt>
            <dd>{t(`tvang.decider.${detail.deciderKind}`)}</dd>
          </div>
          <div class="flex justify-between border-t border-[var(--color-border)] py-1">
            <dt>{t('tvang.field.validFrom')}</dt>
            <dd class="font-[family-name:var(--font-mono)]">{formatMoment(detail.validFrom ?? null)}</dd>
          </div>
          <div class="flex justify-between border-t border-[var(--color-border)] py-1">
            <dt>{t('tvang.column.valid')}</dt>
            <dd class="font-[family-name:var(--font-mono)]">{formatMoment(detail.validUntil ?? null)}</dd>
          </div>
          {#if detail.upphavdAt}
            <div class="flex justify-between border-t border-[var(--color-border)] py-1">
              <dt>{t('tvang.field.upphavd')}</dt>
              <dd class="font-[family-name:var(--font-mono)]">{formatMoment(detail.upphavdAt)}</dd>
            </div>
          {/if}
        </dl>

        {#if detail.scope}
          <section class="mb-3">
            <h3 class="mb-1 text-xs font-semibold">{t('tvang.column.scope')}</h3>
            <p class="text-xs">{detail.scope}</p>
          </section>
        {/if}

        <!-- Verkställighet -->
        <section class="mb-3 border-t border-[var(--color-border)] pt-3">
          <h3 class="mb-1 text-xs font-semibold">{t('tvang.section.verkstallighet')}</h3>

          {#if detail.verkstalldAt}
            <p class="text-xs">
              {t('tvang.verkstalld', { at: formatMoment(detail.verkstalldAt) })}
            </p>
            {#if detail.verkstalldNote}
              <p class="text-xs text-[var(--color-ink-muted)]">{detail.verkstalldNote}</p>
            {/if}
          {:else}
            <p class="text-xs text-[var(--color-ink-muted)]">{t('tvang.notVerkstalld')}</p>

            <form
              class="mt-2 flex flex-wrap items-end gap-2"
              onsubmit={(event) => {
                event.preventDefault();
                void verkstall();
              }}
            >
              <label class="flex flex-1 flex-col gap-1 text-xs">
                {t('tvang.field.note')}
                <input
                  bind:value={verkstallNote}
                  maxlength="500"
                  class="border border-[var(--color-border)] px-2 py-1"
                />
              </label>
              <button
                type="submit"
                class="border border-[var(--color-border)] px-3 py-1 text-xs"
                disabled={busy}
              >
                {t('tvang.action.verkstall')}
              </button>
            </form>
          {/if}
        </section>

        <!-- Revocation -->
        {#if !detail.upphavdAt}
          <section class="border-t border-[var(--color-border)] pt-3">
            {#if confirmingUpphav}
              <ConfirmDialog
                label={t('tvang.action.upphav')}
                question={t('tvang.confirm.upphav')}
                {busy}
                {failure}
                fieldLabels={FIELD_LABELS}
                confirm={() => void upphav()}
                cancel={cancelConfirm}
              />
            {:else}
              <button
                type="button"
                class="border border-[var(--color-border)] px-3 py-1 text-xs"
                disabled={busy}
                onclick={(event) => {
                  trigger = event.currentTarget;
                  confirmingUpphav = true;
                  failure = null;
                  status = '';
                }}
              >
                {t('tvang.action.upphav')}
              </button>
            {/if}
          </section>
        {/if}
      {/if}
    </div>
  </div>
</div>
