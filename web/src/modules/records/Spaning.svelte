<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { SPANING_TARGETS } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import LoadMore from '../shared/LoadMore.svelte';
  import { isStub, type Maybe, type Restricted } from './types';

  /**
   * Spaningsuppdrag — the patrol lookout (spec 7.13).
   *
   * **This is not an efterlysning**, and the whole screen is built around the
   * difference. An efterlysning is a prosecutor's decision that somebody be
   * detained; a spaningsuppdrag is an officer saying *look for this van and
   * tell us*. Any officer may raise one, it may name a vehicle, and it always
   * expires.
   *
   * The rule worth reading is the banner. `Spaning.bannerFor` caps a lookout
   * at `alert` and only priority 1 reaches even that — nothing here can make a
   * lookout look like a decision to arrest. That cap is the module's
   * contribution to officer safety and it lives on the server, so this screen
   * draws `banner` rather than deriving it from `priority`: an officer shown a
   * red banner for every "have a look for this van" learns within a shift that
   * red banners are usually nothing, and then misses the one that was a person
   * with a knife.
   *
   * The form defaults to priority 3 for the same reason the schema does. The
   * expensive mistake is the loud one.
   */

  interface SpaningRow {
    id: number;
    number: string;
    targetKind: string;
    targetId?: number | null;
    description?: string | null;
    grund: string;
    priority: number;
    beatId?: number | null;
    areaNote?: string | null;
    fuId?: number | null;
    anmalanId?: number | null;
    issuedBy?: string | null;
    /** Epoch seconds, as `UNIX_TIMESTAMP` sends them. */
    issuedAt?: number | null;
    expiresAt?: number | null;
    resolvedAt?: number | null;
    resolvedBy?: string | null;
    resolvedGrund?: string | null;
    classification: string;
    version: number;
    /** `Spaning.isLive`, computed on the server. */
    live?: boolean;
    /** `Spaning.bannerFor`: `alert`, `notice` or `quiet`. Never derived here. */
    banner?: string;
    needsConfirmation?: boolean;
  }

  /** `intel/repo.lua`'s `associatesForPerson`, reached through the
   *  master-record link (0025) -- only ever attached when the target is a
   *  person and this session can read the intel register at all. */
  interface KnownAssociate {
    personId: number;
    name: string | null;
    alias: string | null;
    relationship: string | null;
    isConfirmed: boolean;
  }

  /** Why a lookout is raised, and why it is closed. Locale keys, never prose. */
  const GRUNDER = [
    'iakttagelse',
    'efterlyst_fordon',
    'stulet_fordon',
    'misstankt_fordon',
    'eftersokt_person',
    'annan',
  ];

  const AVSLUTSGRUNDER = ['gripen', 'omhandertaget', 'aterkallad', 'tiden_ute', 'annan'];

  const PRIORITIES = [1, 2, 3, 4];

  /** How long a lookout runs. Days, bounded by `SpaningCreate`'s ninety. */
  const VALIDITY_DAYS = [1, 7, 30, 90];

  const DAY = 86400;

  let rows = $state<Maybe<SpaningRow>[]>([]);
  let nextCursor = $state<string | null>(null);
  let detail = $state<SpaningRow | null>(null);
  let knownAssociates = $state<KnownAssociate[]>([]);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);
  let includeResolved = $state(false);
  let targetFilter = $state('');
  let openId = $state<number | null>(null);

  let raising = $state(false);
  let form = $state({
    targetKind: 'vehicle',
    targetId: '',
    description: '',
    grund: '',
    // Three, not one. The loud direction is the dangerous one.
    priority: 3,
    areaNote: '',
    validDays: 7,
  });

  let resolving = $state<SpaningRow | null>(null);
  let resolveGrund = $state('');
  let trigger: HTMLButtonElement | null = null;

  /** What just happened, for the officer who cannot see the row change. */
  let status = $state('');

  const REQUIRED_MARK = '*';

  const FIELD_LABELS: Record<string, string> = {
    targetKind: 'spaning.column.target',
    targetId: 'spaning.column.target',
    description: 'spaning.column.description',
    grund: 'spaning.column.grund',
    priority: 'spaning.column.priority',
    areaNote: 'spaning.column.area',
    validSeconds: 'spaning.field.valid',
    classification: 'records.person.field.classification',
    version: 'anmalan.column.version',
  };

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  /**
   * `other` names no record, so it takes no id.
   *
   * Mirrors `Spaning.validate`: an id alongside `other` would be an id into
   * nothing, and the banner would try to open a record that does not exist.
   */
  const takesTargetId = $derived(form.targetKind !== 'other');

  $effect(() => {
    if (!takesTargetId && form.targetId) form.targetId = '';
  });

  function cancelConfirm(): void {
    resolving = null;
    failure = null;
    trigger?.focus();
  }

  async function load(reset = true): Promise<void> {
    busy = true;

    const response = await nui.call<{ spaningsuppdrag: Maybe<SpaningRow>[]; nextCursor?: string | null }>(
      'spaning.list',
      {
        targetKind: targetFilter || undefined,
        includeResolved: includeResolved || undefined,
        limit: 50,
        cursor: reset ? undefined : (nextCursor ?? undefined),
      },
    );

    if (response.ok) {
      const page = response.data.spaningsuppdrag ?? [];
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

    const response = await nui.call<{ spaning: SpaningRow; knownAssociates?: KnownAssociate[] }>(
      'spaning.get',
      { id },
    );

    if (response.ok) {
      detail = response.data.spaning;
      knownAssociates = response.data.knownAssociates ?? [];
      openId = id;
      failure = null;
    } else {
      detail = null;
      knownAssociates = [];
      openId = null;
      failure = response;
    }

    busy = false;
  }

  async function raise(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    busy = true;

    const response = await nui.call('spaning.create', {
      targetKind: form.targetKind,
      targetId: takesTargetId ? Number(form.targetId) || undefined : undefined,
      description: form.description || undefined,
      grund: form.grund || undefined,
      priority: form.priority,
      areaNote: form.areaNote || undefined,
      validSeconds: form.validDays * DAY,
    });

    if (response.ok) {
      failure = null;
      raising = false;
      form.targetId = '';
      form.description = '';
      form.areaNote = '';
      await load();
    } else {
      failure = response;
      busy = false;
    }
  }

  async function resolve(): Promise<void> {
    const row = resolving;
    if (!row) return;

    busy = true;

    const response = await nui.call('spaning.resolve', {
      id: row.id,
      version: row.version,
      grund: resolveGrund || undefined,
    });

    if (response.ok) {
      failure = null;
      resolveGrund = '';
      // Closed once the server has agreed, not before: a stale `version` is
      // the likeliest refusal and closing first discarded the ground with it.
      resolving = null;
      status = t('spaning.closed', { number: row.number });
      trigger?.focus();
      // Neither read depends on the other, so they go together rather than
      // costing two round trips of bridge latency in series.
      await Promise.all([openId === row.id ? open(row.id) : Promise.resolve(), load()]);
    } else {
      failure = response;
      busy = false;
    }
  }

  /** What a lookout is for, as one line. */
  function targetText(row: SpaningRow): string {
    const kind = t(`spaning.target.${row.targetKind}`);

    if (row.description) return `${kind} — ${row.description}`;
    if (row.targetId) return `${kind} #${row.targetId}`;

    return kind;
  }

  function statusText(row: SpaningRow): string {
    if (row.resolvedAt) return t('spaning.status.resolved');
    if (row.live) return t('spaning.status.live');

    return t('spaning.status.expired');
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
      <input type="checkbox" bind:checked={includeResolved} />
      {t('spaning.filter.includeResolved')}
    </label>

    <label class="flex flex-col gap-1 text-xs">
      {t('spaning.column.target')}
      <select bind:value={targetFilter} class="border border-[var(--color-border)] px-2 py-1">
        <option value="">{t('form.any')}</option>
        {#each SPANING_TARGETS as target (target)}
          <option value={target}>{t(`spaning.target.${target}`)}</option>
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
      onclick={() => (raising = !raising)}
    >
      {t('spaning.action.create')}
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

  {#if raising}
    <form
      class="flex flex-wrap items-end gap-2 border border-[var(--color-border)] p-3"
      onsubmit={(event) => void raise(event)}
    >
      <label class="flex flex-col gap-1 text-xs">
        {t('spaning.column.target')}
        <select bind:value={form.targetKind} class="border border-[var(--color-border)] px-2 py-1">
          {#each SPANING_TARGETS as target (target)}
            <option value={target}>{t(`spaning.target.${target}`)}</option>
          {/each}
        </select>
      </label>

      {#if takesTargetId}
        <label class="flex flex-col gap-1 text-xs">
          {t('spaning.field.targetId')}
          <input
            bind:value={form.targetId}
            inputmode="numeric"
            class="w-24 border border-[var(--color-border)] px-2 py-1"
          />
        </label>
      {/if}

      <label class="flex flex-1 flex-col gap-1 text-xs">
        <!--
          A lookout has to be for *something*: a record to point at, or a
          description. "Silver estate, no plate seen, three occupants" is the
          commonest lookout there is and the case a foreign key cannot express,
          so the description is what carries it.
        -->
        {t('spaning.column.description')}
        <input
          bind:value={form.description}
          maxlength="500"
          class="border border-[var(--color-border)] px-2 py-1"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('spaning.column.grund')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
        <select
          bind:value={form.grund}
          required
          aria-required="true"
          class="border border-[var(--color-border)] px-2 py-1"
        >
          <option value="">{t('spaning.field.grundChoose')}</option>
          {#each GRUNDER as key (key)}
            <option value={key}>{t(`spaning.grund.${key}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        {t('spaning.column.priority')}
        <select bind:value={form.priority} class="border border-[var(--color-border)] px-2 py-1">
          {#each PRIORITIES as level (level)}
            <option value={level}>{t(`spaning.priority.${level}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        {t('spaning.column.area')}
        <input
          bind:value={form.areaNote}
          maxlength="191"
          class="w-48 border border-[var(--color-border)] px-2 py-1"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        {t('spaning.field.valid')}
        <select bind:value={form.validDays} class="border border-[var(--color-border)] px-2 py-1">
          {#each VALIDITY_DAYS as days (days)}
            <option value={days}>
              {days === 1
                ? t('spaning.field.validOneDay')
                : t('spaning.field.validDays', { count: String(days) })}
            </option>
          {/each}
        </select>
      </label>

      <!--
        Said before the lookout is raised, not discovered afterwards: priority
        1 interrupts every officer who runs this target with a banner and a
        confirmation step, and it is the only priority that does.
      -->
      {#if form.priority === 1}
        <p class="w-full text-xs text-[var(--color-caution)]">{t('spaning.priorityOneWarning')}</p>
      {/if}

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1 text-xs"
        disabled={busy}
      >
        {t('spaning.action.create')}
      </button>
    </form>
  {/if}

  {#if status}
    <p class="text-xs text-[var(--color-ink-muted)]" role="status">{status}</p>
  {/if}

  {#if resolving}
    <ConfirmDialog
      label={t('spaning.action.resolve')}
      question={t('spaning.confirm.resolve', { number: resolving.number })}
      {busy}
      {failure}
      fieldLabels={FIELD_LABELS}
      confirm={() => void resolve()}
      cancel={cancelConfirm}
    >
      <label class="mt-2 flex flex-col gap-1">
        <span>{t('spaning.field.avslutsgrund')}</span>
        <select bind:value={resolveGrund} class="w-64 border border-[var(--color-border)] px-2 py-1">
          <option value="">{t('spaning.field.avslutsgrundChoose')}</option>
          {#each AVSLUTSGRUNDER as key (key)}
            <option value={key}>{t(`spaning.avslutsgrund.${key}`)}</option>
          {/each}
        </select>
      </label>
    </ConfirmDialog>
  {/if}

  <div class="grid gap-4 md:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]">
    <div class="border border-[var(--color-border)]">
      {#if rows.length === 0}
        <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">{t('spaning.empty')}</p>
      {:else}
        <div class="overflow-x-auto">
          <table class="w-full text-xs">
            <thead class="bg-[var(--color-surface)]">
              <tr>
                <th class="px-2 py-1 text-left font-semibold">{t('spaning.column.number')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('spaning.column.target')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('spaning.column.priority')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('spaning.column.expires')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('tvang.column.status')}</th>
              </tr>
            </thead>
            <tbody>
              <!-- Keyed by index: a stub carries no id (4.5). -->
              {#each rows as row, index (index)}
                {#if isStub(row)}
                  <tr class="border-t border-[var(--color-border)]">
                    <td class="px-2 py-1 text-[var(--color-ink-muted)]" colspan="5">
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
                    <td class="px-2 py-1">{targetText(row)}</td>
                    <td class="px-2 py-1 whitespace-nowrap">
                      <!--
                        The short form in the grid. The full sentence
                        ("Priority 1 — banner and confirmation") is 275 px of
                        unbreakable text and pushed the Status column outside
                        the panel; it belongs in the select, where the officer
                        is choosing, and on the record below.
                      -->
                      {t(`spaning.priority.short.${row.priority}`)}
                      <!--
                        The banner level in words, from the server's own
                        `bannerFor`. Only `alert` is drawn in the alert colour,
                        and only priority 1 ever reaches it.
                      -->
                      {#if row.live && row.banner === 'alert'}
                        <span class="ml-1 text-[var(--color-alert)]">
                          {t('spaning.banner.alert')}
                        </span>
                      {/if}
                    </td>
                    <td class="px-2 py-1 font-[family-name:var(--font-mono)] whitespace-nowrap">
                      {formatMoment(row.expiresAt ?? null)}
                    </td>
                    <td class="px-2 py-1 whitespace-nowrap">
                      <span class:text-[var(--color-ink-muted)]={!row.live}>{statusText(row)}</span>
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
        <p class="text-xs text-[var(--color-ink-muted)]">{t('spaning.detail.none')}</p>
      {:else}
        <header class="mb-3">
          <h2 class="font-[family-name:var(--font-mono)] text-sm font-semibold">{detail.number}</h2>
          <p class="text-xs text-[var(--color-ink-muted)]">{targetText(detail)}</p>
        </header>

        <!--
          A lookout is not a warrant, and this says so on the record itself.
          The officer who finds the van is deciding what to do next, and the
          answer is to report the sighting rather than to make an arrest.
        -->
        <p class="mb-3 text-xs text-[var(--color-ink-muted)]">{t('spaning.notAnArrest')}</p>

        <dl class="mb-3 text-xs">
          <div class="flex justify-between border-t border-[var(--color-border)] py-1">
            <dt>{t('spaning.column.grund')}</dt>
            <dd>{t(`spaning.grund.${detail.grund}`)}</dd>
          </div>
          <div class="flex justify-between border-t border-[var(--color-border)] py-1">
            <dt>{t('spaning.column.priority')}</dt>
            <dd>{t(`spaning.priority.${detail.priority}`)}</dd>
          </div>
          {#if detail.areaNote}
            <div class="flex justify-between border-t border-[var(--color-border)] py-1">
              <dt>{t('spaning.column.area')}</dt>
              <dd>{detail.areaNote}</dd>
            </div>
          {/if}
          <div class="flex justify-between border-t border-[var(--color-border)] py-1">
            <dt>{t('spaning.column.issued')}</dt>
            <dd class="font-[family-name:var(--font-mono)]">
              {formatMoment(detail.issuedAt ?? null)}
            </dd>
          </div>
          <div class="flex justify-between border-t border-[var(--color-border)] py-1">
            <dt>{t('spaning.column.expires')}</dt>
            <dd class="font-[family-name:var(--font-mono)]">
              {formatMoment(detail.expiresAt ?? null)}
            </dd>
          </div>
          {#if detail.resolvedAt}
            <div class="flex justify-between border-t border-[var(--color-border)] py-1">
              <dt>{t('spaning.status.resolved')}</dt>
              <dd class="font-[family-name:var(--font-mono)]">
                {formatMoment(detail.resolvedAt)}
              </dd>
            </div>
          {/if}
        </dl>

        {#if detail.description}
          <section class="mb-3">
            <h3 class="mb-1 text-xs font-semibold">{t('spaning.column.description')}</h3>
            <p class="text-xs">{detail.description}</p>
          </section>
        {/if}

        {#if detail.targetKind === 'person' && knownAssociates.length > 0}
          <!--
            Only ever populated by the server for a person target this
            session can also read through the intel register (0025) -- an
            empty list here means either nothing was found or this session
            cannot see it, and the two are indistinguishable on purpose
            (invariant 4): the section simply does not appear.
          -->
          <section class="mb-3">
            <h3 class="mb-1 text-xs font-semibold">{t('spaning.knownAssociates')}</h3>
            <ul class="text-xs">
              {#each knownAssociates as associate (associate.personId)}
                <li class="border-t border-[var(--color-border)] py-1">
                  {associate.name ?? associate.alias ?? t('intel.person.unknown')}
                  {#if associate.relationship}
                    <span class="text-[var(--color-ink-muted)]"> — {associate.relationship}</span>
                  {/if}
                  <span class="text-[var(--color-ink-muted)]">
                    ({t(associate.isConfirmed ? 'intel.person.confirmed' : 'intel.person.suspected')})
                  </span>
                </li>
              {/each}
            </ul>
          </section>
        {/if}

        {#if !detail.resolvedAt}
          <button
            type="button"
            class="border border-[var(--color-border)] px-3 py-1 text-xs"
            disabled={busy}
            onclick={(event) => {
              trigger = event.currentTarget;
              resolving = detail;
              resolveGrund = '';
              failure = null;
              status = '';
            }}
          >
            {t('spaning.action.resolve')}
          </button>
        {:else if detail.resolvedGrund}
          <p class="text-xs text-[var(--color-ink-muted)]">
            {t(`spaning.avslutsgrund.${detail.resolvedGrund}`)}
          </p>
        {/if}
      {/if}
    </div>
  </div>
</div>
