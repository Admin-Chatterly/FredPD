<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { ANMALAN_STATUSES } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import LoadMore from '../shared/LoadMore.svelte';
  import { isStub, type Maybe, type Restricted } from './types';

  /**
   * Anmälan — the offence report and its approval workflow (spec 7.7).
   *
   * Its own component rather than a fourth branch inside `Records.svelte`,
   * which is already 2 800 lines over three registers. The `cad/` module is
   * split the same way and for the same reason: a screen nobody can hold in
   * their head is a screen where a rendering decision gets made twice.
   *
   * Four things the server decides that this screen renders rather than
   * second-guesses:
   *
   *   * **Which actions are offered comes from the server's `may` block**, not
   *     from a permission this screen knows about. An officer who may not
   *     approve still sees the button and is refused by the server, and the
   *     refusal is drawn (invariant 4, spec 6.4). What the screen does *not* do
   *     is offer an action the record's status makes impossible — submitting an
   *     approved anmälan is not a permissions question, it is a locked record.
   *   * **`ownReport` is the one refusal worth explaining up front.** An author
   *     cannot approve their own anmälan and no permission reaches that rule,
   *     so an officer refused with a bare "forbidden" concludes their role is
   *     wrong and asks for a grant that would not help. The note renders beside
   *     the button, *and* the refusal itself is translated rather than left as
   *     `status — own_report` under a message about Discord roles.
   *   * **A record the reader may not open arrives as a stub with no `id`**
   *     (4.5). It is drawn as the module's restricted row, carrying the unit to
   *     contact — which is the only part of it an officer can act on.
   *   * **The straffskala is the server's arithmetic** (BrB 26:2). It arrives
   *     computed. A second implementation here would be the one nobody tested,
   *     and it is the figure an officer repeats to a prosecutor.
   */

  interface AnmalanRow {
    id: number;
    number: string;
    title: string;
    status: string;
    createdBy: string;
    createdAt?: string;
    occurredPlace?: string | null;
    /** The supervisor's reason, on a report that came back. */
    returnedNote?: string | null;
    fuId?: number | null;
    version: number;
  }

  interface Charge {
    id: number;
    code: string;
    labelKey: string;
    citation?: string | null;
    grad: string;
    stage: string;
    personId?: number | null;
  }

  interface Straffskala {
    boter: boolean;
    min: number;
    max: number | null;
  }

  interface Detail {
    anmalan: AnmalanRow;
    brott: Charge[];
    personer: { personId: number; roll: string; personNumber: string }[];
    supplements: Maybe<AnmalanRow>[];
    straffskala?: Straffskala | null;
    aklagareIndicated?: boolean;
    /**
     * What the session may do, decided on the server.
     *
     * Not inferred here from a Discord id: `Session` deliberately carries none,
     * and "what a session may do is the server's answer" is the rule the whole
     * codebase is built on. `ownReport` is separate from `approve` because the
     * screen says different things about them — one is a role question and the
     * other is a rule no grant reaches.
     */
    may?: {
      approve?: boolean;
      submit?: boolean;
      edit?: boolean;
      ownReport?: boolean;
    };
  }

  let rows = $state<Maybe<AnmalanRow>[]>([]);
  let nextCursor = $state<string | null>(null);
  let detail = $state<Detail | null>(null);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);
  let statusFilter = $state<string>('');
  let mine = $state(false);
  let returnNote = $state('');
  let openId = $state<number | null>(null);

  /**
   * A confirmation step on the two transitions 6.4 names.
   *
   * Approving is an electronic signature that locks the record permanently
   * (7.7) — amendment afterwards is only by tilläggsuppgift. Returning bounces
   * the report out of the supervisor's queue. Both are the "legal or
   * destructive" actions 6.4 requires a verb-labelled dialog for.
   */
  let confirming = $state<'approve' | 'atersand' | null>(null);

  /**
   * Which field a rejected code belongs to.
   *
   * Without this the panel prints a bare `status — own_report` under "Your
   * Discord roles do not grant access to this", which is the exact message this
   * component exists to avoid producing.
   */
  const FIELD_LABELS: Record<string, string> = {
    status: 'anmalan.column.status',
    version: 'anmalan.column.version',
  };

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  /**
   * The own-report refusal, read as itself rather than as a permission problem.
   *
   * `forbidden` + `status: own_report` is the server saying "a second person
   * has to look at this", not "your roles are wrong", and the generic envelope
   * renderer cannot tell the two apart.
   */
  const ownReportRefusal = $derived(
    failure?.err === 'forbidden' && failure.fields?.status === 'own_report',
  );

  const lockedRefusal = $derived(
    failure?.err === 'conflict' && failure.fields?.status === 'locked',
  );

  /**
   * Which workflow actions the record's status allows.
   *
   * Mirrors `Anmalan.nextStatus` on the server. Not a second source of truth:
   * the server refuses anything this gets wrong, and this exists so the screen
   * does not offer a button whose only outcome is a refusal nobody can act on.
   */
  const canSubmit = $derived(
    detail?.anmalan.status === 'utkast' || detail?.anmalan.status === 'atersand',
  );
  const canReview = $derived(detail?.anmalan.status === 'inlamnad');
  const isLocked = $derived(detail?.anmalan.status === 'godkand');
  const isOwnReport = $derived(Boolean(detail?.may?.ownReport));

  function stubContact(row: Restricted): string {
    return t('records.restricted.contact', { unit: t(`access.unit.${row.contact}`) });
  }

  async function load(reset = true): Promise<void> {
    busy = true;

    const response = await nui.call<{ anmalningar: Maybe<AnmalanRow>[]; nextCursor?: string | null }>(
      'anmalan.list',
      {
        status: statusFilter || undefined,
        mine: mine || undefined,
        limit: 50,
        cursor: reset ? undefined : (nextCursor ?? undefined),
      },
    );

    if (response.ok) {
      const page = response.data.anmalningar ?? [];
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

    // Cleared before the fetch, not after: a reason typed against one report
    // must not be carried to the next one and sent with its return.
    returnNote = '';
    confirming = null;

    const response = await nui.call<Detail>('anmalan.get', { id });

    if (response.ok) {
      detail = response.data;
      openId = id;
      failure = null;
    } else {
      detail = null;
      openId = null;
      failure = response;
    }

    busy = false;
  }

  /** Runs a workflow transition and reloads both the record and the list. */
  async function transition(route: string, extra: Record<string, unknown> = {}): Promise<void> {
    if (!detail) return;

    busy = true;
    confirming = null;

    const id = detail.anmalan.id;

    const response = await nui.call('anmalan.' + route, {
      id,
      version: detail.anmalan.version,
      ...extra,
    });

    if (response.ok) {
      failure = null;
      await open(id);
      await load();
    } else {
      failure = response;
      busy = false;
    }
  }

  /** Months as the span a straffskala is written in. */
  function span(skala: Straffskala): string {
    if (skala.max === null) return t('brott.straffskala.livstid');

    const max = months(skala.max);

    if (skala.min > 0) {
      return t('brott.straffskala.atLeast', { min: months(skala.min), max });
    }

    return t('brott.straffskala.upTo', { max });
  }

  /**
   * A month count as words, in whichever unit reads cleanly.
   *
   * `t()` has no plural machinery — it substitutes `{name}` and nothing else —
   * so the singular is a key of its own, chosen here. That is not pedantry
   * about "1 months": a straffskala of one month is the floor of a great many
   * offences in brottsbalken, so it is one of the strings an officer reads
   * most often.
   *
   * Swedish `år` happens to be invariant, and it still gets its own key. A
   * translator who sees `year` and `years` collapsed into one entry has to
   * work out whether that was a decision about Swedish or a missing string.
   */
  function months(value: number): string {
    if (value >= 12 && value % 12 === 0) {
      const years = value / 12;

      return t(years === 1 ? 'brott.straffskala.year' : 'brott.straffskala.years', {
        count: String(years),
      });
    }

    return t(value === 1 ? 'brott.straffskala.month' : 'brott.straffskala.months', {
      count: String(value),
    });
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
    <label class="flex flex-col gap-1 text-xs">
      {t('anmalan.column.status')}
      <select bind:value={statusFilter} class="border border-[var(--color-border)] px-2 py-1">
        <option value="">{t('form.any')}</option>
        {#each ANMALAN_STATUSES as status (status)}
          <option value={status}>{t(`anmalan.status.${status}`)}</option>
        {/each}
      </select>
    </label>

    <label class="flex items-center gap-1 text-xs">
      <input type="checkbox" bind:checked={mine} />
      {t('anmalan.filter.mine')}
    </label>

    <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
      {t('form.search')}
    </button>
  </form>

  {#if failure}
    <!--
      The refusal, read as itself. Two of them mean something the generic
      envelope renderer cannot express, and both are cases where the wrong
      message sends an officer to ask for a permission that would not help.
    -->
    <div class="border border-[var(--color-alert)] px-3 py-2 text-sm" role="alert">
      {#if ownReportRefusal}
        <p>{t('anmalan.ownReport')}</p>
      {:else if lockedRefusal}
        <p>{t('anmalan.locked')}</p>
      {:else}
        <p>{t(`error.${failure.err}`)}</p>
        {#if messages.length > 0}
          <ul class="mt-1 text-xs text-[var(--color-ink-muted)]">
            {#each messages as message (message.name)}
              <li>{message.label} — {message.reason}</li>
            {/each}
          </ul>
        {/if}
      {/if}
    </div>
  {/if}

  <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)]">
    <!-- The list -->
    <div class="border border-[var(--color-border)]">
      {#if rows.length === 0}
        <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">{t('anmalan.empty')}</p>
      {:else}
        <table class="w-full text-xs">
          <thead class="bg-[var(--color-surface)]">
            <tr>
              <th class="px-2 py-1 text-left font-semibold">{t('anmalan.column.number')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('anmalan.column.title')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('anmalan.column.status')}</th>
            </tr>
          </thead>
          <tbody>
            <!--
              Keyed by index, not by id: a stub carries no id (4.5), so two
              restricted rows in one result would collide on `undefined` and
              Svelte would refuse to render the list at all. The three registers
              key the same way.
            -->
            {#each rows as row, index (index)}
              {#if isStub(row)}
                <tr class="border-t border-[var(--color-border)]">
                  <td class="px-2 py-1 text-[var(--color-ink-muted)]" colspan="3">
                    {t('records.restricted.title')} — {stubContact(row)}
                  </td>
                </tr>
              {:else}
                <tr class="border-t border-[var(--color-border)]">
                  <td class="px-2 py-1 font-[family-name:var(--font-mono)]">
                    <button
                      type="button"
                      class="underline-offset-2 hover:underline"
                      class:font-semibold={openId === row.id}
                      onclick={() => void open(row.id)}
                    >
                      {row.number}
                    </button>
                  </td>
                  <td class="px-2 py-1">{row.title}</td>
                  <td class="px-2 py-1">{t(`anmalan.status.${row.status}`)}</td>
                </tr>
              {/if}
            {/each}
          </tbody>
        </table>
        <LoadMore {nextCursor} {busy} {loadMore} />
      {/if}
    </div>

    <!-- The record -->
    <div class="border border-[var(--color-border)] p-3">
      {#if !detail}
        <p class="text-xs text-[var(--color-ink-muted)]">{t('anmalan.detail.none')}</p>
      {:else}
        <header class="mb-3">
          <h2 class="text-sm font-semibold">{detail.anmalan.title}</h2>
          <p class="font-[family-name:var(--font-mono)] text-xs text-[var(--color-ink-muted)]">
            {detail.anmalan.number} · {t(`anmalan.status.${detail.anmalan.status}`)}
          </p>
        </header>

        {#if isLocked}
          <p class="mb-3 border border-[var(--color-border)] px-2 py-1 text-xs">
            {t('anmalan.locked')}
          </p>
        {/if}

        {#if detail.anmalan.status === 'atersand'}
          <!--
            The supervisor's reason, which is the entire point of "återsänd MED
            kommentar" (7.7). The server has always sent it; without this the
            officer whose report came back could not read the comment they were
            sent.
          -->
          <div class="mb-3 border border-[var(--color-caution)] px-2 py-1 text-xs">
            <p class="font-semibold">{t('anmalan.returnedHeading')}</p>
            <p class="mt-0.5">
              {detail.anmalan.returnedNote || t('anmalan.returnedNoReason')}
            </p>
          </div>
        {/if}

        <!-- Charges, and the span they carry together -->
        <section class="mb-3">
          <h3 class="mb-1 text-xs font-semibold">{t('anmalan.section.brott')}</h3>
          {#if detail.brott.length === 0}
            <p class="text-xs text-[var(--color-ink-muted)]">{t('anmalan.brott.empty')}</p>
          {:else}
            <ul class="text-xs">
              {#each detail.brott as charge (charge.id)}
                <li class="border-t border-[var(--color-border)] py-1">
                  <span class="font-[family-name:var(--font-mono)]">
                    {charge.citation ?? charge.code}
                  </span>
                  — {t(charge.labelKey)}
                  <span class="text-[var(--color-ink-muted)]">
                    ({t(`brott.grad.${charge.grad}`)}{#if charge.stage !== 'fullbordat'}, {t(
                        `anmalan.stage.${charge.stage}`,
                      )}{/if})
                  </span>
                </li>
              {/each}
            </ul>

            {#if detail.straffskala}
              <p class="mt-2 text-xs">
                <span class="font-semibold">{t('brott.column.straffskala')}:</span>
                {span(detail.straffskala)}
                {#if detail.straffskala.boter}
                  · {t('brott.straffskala.boter')}
                {/if}
              </p>
            {/if}

            {#if detail.aklagareIndicated}
              <p class="mt-1 text-xs text-[var(--color-ink-muted)]">
                {t('anmalan.aklagareIndicated')}
              </p>
            {/if}
          {/if}
        </section>

        <!-- People -->
        <section class="mb-3">
          <h3 class="mb-1 text-xs font-semibold">{t('anmalan.section.personer')}</h3>
          {#if detail.personer.length === 0}
            <p class="text-xs text-[var(--color-ink-muted)]">{t('anmalan.personer.empty')}</p>
          {:else}
            <ul class="text-xs">
              {#each detail.personer as person (`${person.personId}-${person.roll}`)}
                <li class="py-0.5">
                  <span class="font-[family-name:var(--font-mono)]">{person.personNumber}</span>
                  — {t(`anmalan.roll.${person.roll}`)}
                </li>
              {/each}
            </ul>
          {/if}
        </section>

        <!-- The workflow -->
        <section class="border-t border-[var(--color-border)] pt-3">
          {#if canSubmit}
            <button
              type="button"
              class="border border-[var(--color-border)] px-3 py-1 text-xs"
              disabled={busy}
              onclick={() => void transition('submit')}
            >
              {t('anmalan.action.submit')}
            </button>
          {/if}

          {#if canReview}
            <div class="flex flex-col gap-2">
              <!--
                The reason field comes BEFORE the buttons, so the tab order
                reaches it before the action that consumes it (6.4, keyboard
                first). It was below them, which put Return one tab stop ahead
                of the box explaining it.
              -->
              <label class="flex flex-col gap-1 text-xs">
                {t('anmalan.action.atersandNote')}
                <textarea
                  bind:value={returnNote}
                  rows="2"
                  class="border border-[var(--color-border)] px-2 py-1"
                ></textarea>
              </label>

              <!--
                6.4: a dialog for a legal action, with a verb label. Approving
                is an electronic signature and locks the record permanently
                (7.7); there is no undo, only a tilläggsuppgift.
              -->
              {#if confirming === 'approve'}
                <div class="border border-[var(--color-border)] px-2 py-2 text-xs">
                  <p>{t('anmalan.confirm.approve')}</p>
                  <div class="mt-2 flex gap-2">
                    <button
                      type="button"
                      class="border border-[var(--color-border)] px-3 py-1"
                      disabled={busy}
                      onclick={() => void transition('approve')}
                    >
                      {t('anmalan.action.approve')}
                    </button>
                    <button
                      type="button"
                      class="border border-[var(--color-border)] px-3 py-1"
                      onclick={() => (confirming = null)}
                    >
                      {t('form.cancel')}
                    </button>
                  </div>
                </div>
              {:else if confirming === 'atersand'}
                <div class="border border-[var(--color-border)] px-2 py-2 text-xs">
                  <p>{t('anmalan.confirm.atersand')}</p>
                  <div class="mt-2 flex gap-2">
                    <button
                      type="button"
                      class="border border-[var(--color-border)] px-3 py-1"
                      disabled={busy}
                      onclick={() =>
                        void transition('atersand', { note: returnNote || undefined })}
                    >
                      {t('anmalan.action.atersand')}
                    </button>
                    <button
                      type="button"
                      class="border border-[var(--color-border)] px-3 py-1"
                      onclick={() => (confirming = null)}
                    >
                      {t('form.cancel')}
                    </button>
                  </div>
                </div>
              {:else}
                <div class="flex gap-2">
                  <button
                    type="button"
                    class="border border-[var(--color-border)] px-3 py-1 text-xs"
                    disabled={busy}
                    onclick={() => (confirming = 'approve')}
                  >
                    {t('anmalan.action.approve')}
                  </button>
                  <button
                    type="button"
                    class="border border-[var(--color-border)] px-3 py-1 text-xs"
                    disabled={busy}
                    onclick={() => (confirming = 'atersand')}
                  >
                    {t('anmalan.action.atersand')}
                  </button>
                </div>
              {/if}

              <!--
                Rendered before the attempt, not only after. An officer refused
                with a bare "forbidden" assumes their role is wrong and goes to
                ask for a grant that would not help: no permission reaches this
                rule.
              -->
              {#if isOwnReport}
                <p class="text-xs text-[var(--color-caution)]">{t('anmalan.ownReport')}</p>
              {/if}
            </div>
          {/if}
        </section>

        {#if detail.supplements.length > 0}
          <section class="mt-3 border-t border-[var(--color-border)] pt-3">
            <h3 class="mb-1 text-xs font-semibold">{t('anmalan.section.supplements')}</h3>
            <ul class="text-xs">
              {#each detail.supplements as supplement, index (index)}
                <li class="py-0.5">
                  {#if isStub(supplement)}
                    <span class="text-[var(--color-ink-muted)]">
                      {t('records.restricted.title')} — {stubContact(supplement)}
                    </span>
                  {:else}
                    <button
                      type="button"
                      class="font-[family-name:var(--font-mono)] underline-offset-2 hover:underline"
                      onclick={() => void open(supplement.id)}
                    >
                      {supplement.number}
                    </button>
                    — {supplement.title}
                  {/if}
                </li>
              {/each}
            </ul>
          </section>
        {/if}
      {/if}
    </div>
  </div>
</div>
