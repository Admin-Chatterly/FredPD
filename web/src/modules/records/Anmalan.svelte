<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { ANMALAN_STATUSES } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';

  /**
   * Anmälan — the offence report and its approval workflow (spec 7.7).
   *
   * Its own component rather than a fourth branch inside `Records.svelte`,
   * which is already 2 800 lines over three registers. The `cad/` module is
   * split the same way and for the same reason: a screen nobody can hold in
   * their head is a screen where a rendering decision gets made twice.
   *
   * Three things the server decides that this screen renders rather than
   * second-guesses:
   *
   *   * **Which actions are offered comes from the record's own status**, not
   *     from a permission this screen knows about. An officer who may not
   *     approve still sees the button and is refused by the server, and the
   *     refusal is drawn (invariant 4, spec 6.4). What this screen does *not*
   *     do is offer an action the status makes impossible — submitting an
   *     approved anmälan is not a permissions question, it is a locked record.
   *   * **`ownReport` is the one refusal worth explaining up front.** An
   *     author cannot approve their own anmälan, no permission reaches that
   *     rule, and an officer who is refused with a bare "forbidden" will assume
   *     their role is wrong and go and ask for a grant that would not help. So
   *     the note is rendered beside the button rather than only after the
   *     attempt.
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
    fuId?: number | null;
    version: number;
    restricted?: boolean;
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
    supplements: AnmalanRow[];
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

  let rows = $state<AnmalanRow[]>([]);
  let detail = $state<Detail | null>(null);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);
  let statusFilter = $state<string>('');
  let mine = $state(false);
  let returnNote = $state('');

  const messages = $derived(fieldList(failure, {}));

  /**
   * Which workflow actions the record's status allows.
   *
   * Mirrors `Anmalan.nextStatus` on the server. Not a second source of truth:
   * the server refuses anything this gets wrong, and this exists so the screen
   * does not offer a button whose only outcome is a refusal the officer cannot
   * act on.
   */
  const canSubmit = $derived(
    detail?.anmalan.status === 'utkast' || detail?.anmalan.status === 'atersand',
  );
  const canReview = $derived(detail?.anmalan.status === 'inlamnad');
  const isLocked = $derived(detail?.anmalan.status === 'godkand');

  /**
   * The author cannot approve their own, whatever they hold. The server says
   * so; this only draws it.
   */
  const isOwnReport = $derived(Boolean(detail?.may?.ownReport));

  async function load(): Promise<void> {
    busy = true;

    const response = await nui.call<{ anmalningar: AnmalanRow[] }>('anmalan.list', {
      status: statusFilter || undefined,
      mine: mine || undefined,
      limit: 50,
    });

    if (response.ok) {
      rows = response.data.anmalningar ?? [];
      failure = null;
    } else {
      failure = response;
    }

    busy = false;
  }

  async function open(id: number): Promise<void> {
    busy = true;

    const response = await nui.call<Detail>('anmalan.get', { id });

    if (response.ok) {
      detail = response.data;
      failure = null;
    } else {
      // A stub the reader may be told about, or a record they may not. Both
      // arrive as a refusal and both are drawn as one.
      detail = null;
      failure = response;
    }

    busy = false;
  }

  /** Runs a workflow transition and reloads both the record and the list. */
  async function transition(route: string, extra: Record<string, unknown> = {}): Promise<void> {
    if (!detail) return;

    busy = true;

    const response = await nui.call('anmalan.' + route, {
      id: detail.anmalan.id,
      version: detail.anmalan.version,
      ...extra,
    });

    if (response.ok) {
      failure = null;
      returnNote = '';
      await open(detail.anmalan.id);
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

  function months(value: number): string {
    if (value >= 12 && value % 12 === 0) {
      return t('brott.straffskala.years', { count: String(value / 12) });
    }

    return t('brott.straffskala.months', { count: String(value) });
  }

  void load();
</script>

<div class="flex min-h-0 flex-col gap-3">
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
    <div class="border border-[var(--color-alert)] px-3 py-2 text-sm">
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

  <div class="grid min-h-0 gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)]">
    <!-- The list -->
    <div class="min-h-0 overflow-auto border border-[var(--color-border)]">
      {#if rows.length === 0}
        <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">{t('anmalan.empty')}</p>
      {:else}
        <table class="w-full text-xs">
          <thead class="sticky top-0 bg-[var(--color-surface)]">
            <tr>
              <th class="px-2 py-1 text-left font-semibold">{t('anmalan.column.number')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('anmalan.column.title')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('anmalan.column.status')}</th>
            </tr>
          </thead>
          <tbody>
            {#each rows as row (row.id)}
              <tr class="border-t border-[var(--color-border)]">
                <td class="px-2 py-1 font-mono">
                  {#if row.restricted}
                    <span class="text-[var(--color-ink-muted)]">{t('access.restrictedRecord')}</span>
                  {:else}
                    <button type="button" class="underline" onclick={() => void open(row.id)}>
                      {row.number}
                    </button>
                  {/if}
                </td>
                <td class="px-2 py-1">{row.restricted ? '—' : row.title}</td>
                <td class="px-2 py-1">
                  {row.restricted ? '—' : t(`anmalan.status.${row.status}`)}
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
      {/if}
    </div>

    <!-- The record -->
    <div class="min-h-0 overflow-auto border border-[var(--color-border)] p-3">
      {#if !detail}
        <p class="text-xs text-[var(--color-ink-muted)]">{t('anmalan.detail.none')}</p>
      {:else}
        <header class="mb-3">
          <h3 class="text-base font-semibold">{detail.anmalan.title}</h3>
          <p class="font-mono text-xs text-[var(--color-ink-muted)]">
            {detail.anmalan.number} · {t(`anmalan.status.${detail.anmalan.status}`)}
          </p>
        </header>

        {#if isLocked}
          <p class="mb-3 border border-[var(--color-border)] px-2 py-1 text-xs">
            {t('anmalan.locked')}
          </p>
        {/if}

        {#if detail.anmalan.status === 'atersand'}
          <p class="mb-3 border border-[var(--color-caution)] px-2 py-1 text-xs">
            {t('anmalan.status.atersand')}
          </p>
        {/if}

        <!-- Charges, and the span they carry together -->
        <section class="mb-3">
          <h4 class="mb-1 text-xs font-semibold">{t('anmalan.section.brott')}</h4>
          {#if detail.brott.length === 0}
            <p class="text-xs text-[var(--color-ink-muted)]">{t('brott.empty')}</p>
          {:else}
            <ul class="text-xs">
              {#each detail.brott as charge (charge.id)}
                <li class="border-t border-[var(--color-border)] py-1">
                  <span class="font-mono">{charge.citation ?? charge.code}</span>
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
          <h4 class="mb-1 text-xs font-semibold">{t('anmalan.section.personer')}</h4>
          {#if detail.personer.length === 0}
            <p class="text-xs text-[var(--color-ink-muted)]">—</p>
          {:else}
            <ul class="text-xs">
              {#each detail.personer as person (`${person.personId}-${person.roll}`)}
                <li class="py-0.5">
                  <span class="font-mono">{person.personNumber}</span>
                  — {t(`anmalan.roll.${person.roll}`)}
                </li>
              {/each}
            </ul>
          {/if}
        </section>

        <!-- The workflow -->
        <section class="flex flex-wrap items-start gap-2 border-t border-[var(--color-border)] pt-3">
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
            <div class="flex flex-col gap-1">
              <div class="flex gap-2">
                <button
                  type="button"
                  class="border border-[var(--color-border)] px-3 py-1 text-xs"
                  disabled={busy}
                  onclick={() => void transition('approve')}
                >
                  {t('anmalan.action.approve')}
                </button>
                <button
                  type="button"
                  class="border border-[var(--color-border)] px-3 py-1 text-xs"
                  disabled={busy}
                  onclick={() => void transition('atersand', { note: returnNote || undefined })}
                >
                  {t('anmalan.action.atersand')}
                </button>
              </div>

              <!--
                Rendered before the attempt, not after. An officer refused with
                a bare "forbidden" assumes their role is wrong and goes to ask
                for a grant that would not help: no permission reaches this rule.
              -->
              {#if isOwnReport}
                <p class="text-xs text-[var(--color-caution)]">{t('anmalan.ownReport')}</p>
              {/if}

              <label class="flex flex-col gap-1 text-xs">
                {t('anmalan.action.atersand')}
                <textarea
                  bind:value={returnNote}
                  rows="2"
                  class="border border-[var(--color-border)] px-2 py-1"
                ></textarea>
              </label>
            </div>
          {/if}
        </section>

        {#if detail.supplements.length > 0}
          <section class="mt-3 border-t border-[var(--color-border)] pt-3">
            <h4 class="mb-1 text-xs font-semibold">{t('anmalan.section.supplements')}</h4>
            <ul class="text-xs">
              {#each detail.supplements as supplement (supplement.id)}
                <li class="py-0.5">
                  <button type="button" class="font-mono underline" onclick={() => void open(supplement.id)}>
                    {supplement.number}
                  </button>
                  — {supplement.title}
                </li>
              {/each}
            </ul>
          </section>
        {/if}
      {/if}
    </div>
  </div>
</div>
