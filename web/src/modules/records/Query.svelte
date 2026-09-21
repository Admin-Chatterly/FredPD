<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import LoadMore from '../shared/LoadMore.svelte';
  import { isStub, type Maybe, type Moment, type Restricted } from './types';

  /**
   * The unified query and its hot-file hits (spec 7.2).
   *
   * One box. An officer types a name, a plate, a VIN, a serial, a phone number
   * or an address, and the server decides which registers that could mean and
   * which of them this session may read. The registers each have their own tab
   * beside this one; what only this screen does is the thing an officer at a
   * roadside actually does — type what they have and be told what it touches.
   *
   * Four rules it renders rather than implements:
   *
   *   * **A hit comes back unconfirmed, and confirming it is a second
   *     deliberate act.** Finding a stolen-vehicle flag is a lead. The
   *     confirmation is a row in `fpd_hotfile_confirmations` bound to the query
   *     that raised it, and an officer who acts on an unconfirmed hit has done
   *     something a department may ask about afterwards. So the button says
   *     what it writes, and the outcome it writes includes "not confirmed" and
   *     "no answer from the holding agency" — a confirmation step with only one
   *     button is a rubber stamp.
   *   * **Which registers were searched is the server's answer**, sent back as
   *     `sources`. An officer who may run a plate but not a person gets the
   *     vehicle half and no hint that the other half exists, so this draws what
   *     came back and never says "nothing in the name index".
   *   * **A query into restricted data needs a reason or a case number**, and
   *     the refusal points at the box (3.5, 7.2). The boxes are part of this
   *     form rather than something the officer discovers from a refusal.
   *   * **Every query is logged, including the one that found nothing.** The
   *     log answers "who has been looking up their ex-partner", and this screen
   *     shows the officer their own history without asking for a permission
   *     they do not have — `mine` is the session's own, decided on the server.
   */

  interface Hit {
    hitType: string;
    hitId: number;
    /** The flag kind, firearm status, caution kind or efterlysning ground. */
    kind: string;
    recordType: string;
    recordId: number;
    confirmed: boolean;
  }

  interface Result {
    id: number;
    /** `person`, `vehicle` or `firearm` — which register answered. */
    kind: string;
    score: number;
    hits?: Hit[];
    // Whichever of the three registers this row came from. Only the columns a
    // ranked list draws are named here; the record pages own the rest.
    personNumber?: string | null;
    firstName?: string | null;
    middleName?: string | null;
    lastName?: string | null;
    plate?: string | null;
    model?: string | null;
    serial?: string | null;
    make?: string | null;
    classification?: string;
  }

  interface QueryResponse {
    queryId: number;
    type: string;
    derived: boolean;
    sources: string[];
    results: Maybe<Result>[];
    hits: number;
  }

  /**
   * A row of `fpd_query_log`, named the way `Repo.queryLog` selects it.
   *
   * There is **no officer name here and no column for one.** The select sends
   * `discordId` and `officerId` and joins nothing, and this screen asks only
   * for `mine` — so the officer reading it is the officer who ran them, and a
   * "by" column would be either their own name repeated or an account id on
   * every row. The agency-wide view that would need a name is the
   * misuse-investigation read behind `query.log.view`, and it is not this.
   */
  interface LogEntry {
    id: number;
    queryType: string;
    term: string;
    accessPoint: string | null;
    restricted: boolean | number;
    resultCount: number;
    hitCount: number;
    /** Confirmations bound to this query, and how many concluded `confirmed`. */
    confirmationCount: number;
    confirmedCount: number;
    reason: string | null;
    caseNumber: string | null;
    createdAt: Moment;
  }

  /** The six names of 7.2, plus the serial alias the spec spells out. */
  const TYPES = ['person', 'plate', 'vin', 'firearm', 'phone', 'address'];

  /** What a confirmation can conclude. A step with one button is a stamp. */
  const OUTCOMES = ['confirmed', 'not_confirmed', 'unable'];

  let term = $state('');
  let type = $state('');
  let authority = $state({ reason: '', caseNumber: '' });
  let response = $state<QueryResponse | null>(null);
  let log = $state<LogEntry[]>([]);
  let logCursor = $state<string | null>(null);

  function loadMoreLog(): void {
    void loadLog(false);
  }
  let showLog = $state(false);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);

  /** The hit being confirmed, and what the officer is concluding about it. */
  let confirming = $state<Hit | null>(null);
  let outcome = $state('confirmed');
  let detail = $state('');
  let reasonBox = $state<HTMLInputElement | null>(null);
  let trigger: HTMLButtonElement | null = null;

  /** What was just written, for the officer who cannot see the banner change. */
  let status = $state('');

  const REQUIRED_MARK = '*';

  const FIELD_LABELS: Record<string, string> = {
    term: 'query.field.term',
    type: 'query.field.type',
    reason: 'records.authority.reason',
    caseNumber: 'records.authority.caseNumber',
    limit: 'query.field.term',
    queryId: 'query.field.term',
    hitType: 'query.field.hit',
    hitId: 'query.field.hit',
    outcome: 'query.field.outcome',
    detail: 'query.field.detail',
    discordId: 'query.log.by',
  };

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  /**
   * True when the server refused for want of a reason (7.2).
   *
   * Drawn as an offer to run the search again with one, never as a count of
   * what was withheld: the number is not sent, and asking for it would be
   * asking the server to disclose exactly what it refused to.
   */
  const needsReason = $derived(
    failure?.err === 'invalid' && failure.fields?.reason === 'required',
  );

  /** A confirmation of `confirmed` has to say what it was confirmed against. */
  const detailMissing = $derived(
    outcome === 'confirmed' && !detail.trim() && !authority.caseNumber.trim(),
  );

  function cancelConfirm(): void {
    confirming = null;
    failure = null;
    trigger?.focus();
  }

  async function run(event?: SubmitEvent): Promise<void> {
    event?.preventDefault();
    busy = true;
    confirming = null;

    const answer = await nui.call<QueryResponse>('query.run', {
      term,
      type: type || undefined,
      reason: authority.reason || undefined,
      caseNumber: authority.caseNumber || undefined,
      limit: 25,
    });

    if (answer.ok) {
      response = answer.data;
      failure = null;
    } else {
      response = null;
      failure = answer;
    }

    busy = false;
  }

  async function confirm(): Promise<void> {
    const hit = confirming;
    if (!hit) return;

    busy = true;

    const answer = await nui.call('query.hit.confirm', {
      // Bound to the query that raised it, so the log can say afterwards
      // whether an officer acted on a confirmed record or on a lead.
      queryId: response?.queryId,
      hitType: hit.hitType,
      hitId: hit.hitId,
      outcome,
      caseNumber: authority.caseNumber || undefined,
      detail: detail || undefined,
    });

    if (answer.ok) {
      failure = null;
      detail = '';
      // Closed once the server has agreed, so a refusal keeps the officer's
      // outcome and detail rather than discarding both.
      confirming = null;
      status = t('query.confirmed', { hit: hitText(hit), outcome: t(`query.confirm.${outcome}`) });
      trigger?.focus();
      // Re-run rather than patching the row: whether a hit now counts as
      // confirmed is the server's answer, and it is the answer the next
      // officer will get.
      await run();
    } else {
      failure = answer;
      busy = false;
    }
  }

  async function loadLog(reset = true): Promise<void> {
    busy = true;

    // `mine` only. The agency-wide view is the misuse-investigation read and
    // sits behind `query.log.view`; asking for it here would refuse for most
    // officers and teach them the button is broken.
    const answer = await nui.call<{ entries: LogEntry[]; nextCursor?: string | null }>('query.log', {
      mine: true,
      limit: 25,
      cursor: reset ? undefined : (logCursor ?? undefined),
    });

    if (answer.ok) {
      const page = answer.data.entries ?? [];
      log = reset ? page : [...log, ...page];
      logCursor = answer.data.nextCursor ?? null;
      showLog = true;
      failure = null;
    } else {
      failure = answer;
    }

    busy = false;
  }

  /** A result row as one line: what an officer scans for. */
  function label(row: Result): string {
    if (row.kind === 'vehicle') return row.plate ?? '';
    if (row.kind === 'firearm') return row.serial ?? '';

    const given = [row.firstName, row.middleName].filter(Boolean).join(' ');
    const surname = row.lastName ?? '';

    if (surname && given) return `${surname}, ${given}`;

    return surname || given || row.personNumber || t('records.person.unnamed');
  }

  /** The second line: enough to tell two rows apart, and no more. */
  function detailOf(row: Result): string {
    if (row.kind === 'vehicle') return row.model ?? '';
    if (row.kind === 'firearm') return row.make ?? '';

    return row.personNumber ?? '';
  }

  /**
   * What a hit says, in words.
   *
   * `query.hit.<kind>` carries the sentence for the two efterlysning grounds
   * that mean "detain on sight" — those are written as instructions because
   * that is what they are. Everything else falls back to the hit type, which
   * names the register rather than the finding.
   */
  function hitText(hit: Hit): string {
    const specific = t(`query.hit.${hit.kind}`);

    return specific === `query.hit.${hit.kind}` ? t(`query.hit.${hit.hitType}`) : specific;
  }

  function stubContact(row: Restricted): string {
    return t('records.restricted.contact', { unit: t(`access.unit.${row.contact}`) });
  }
</script>

<div class="flex flex-col gap-3">
  <form class="flex flex-wrap items-end gap-2" onsubmit={(event) => void run(event)}>
    <label class="flex flex-col gap-1 text-xs">
      <span>{t('query.field.term')} <span aria-hidden="true">{REQUIRED_MARK}</span></span>
      <input
        bind:value={term}
        required
        aria-required="true"
        maxlength="191"
        placeholder={t('query.field.termPlaceholder')}
        class="w-80 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
      />
    </label>

    <label class="flex flex-col gap-1 text-xs">
      {t('query.field.type')}
      <!--
        Absent means "work it out from what was typed", which is the ordinary
        case: a plate looks like a plate. The list is here for the term that
        could be two things — a number that is both a phone and a serial.
      -->
      <select bind:value={type} class="border border-[var(--color-border)] px-2 py-1">
        <option value="">{t('query.field.typeDerive')}</option>
        {#each TYPES as name (name)}
          <option value={name}>{t(`query.type.${name}`)}</option>
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
      disabled={busy}
      onclick={() => void loadLog()}
    >
      {t('query.action.log')}
    </button>
  </form>

  <fieldset class="flex flex-wrap items-end gap-3 border border-[var(--color-border)] p-3">
    <legend class="px-1 text-xs font-semibold">{t('records.authority.title')}</legend>

    <p class="w-full text-xs text-[var(--color-ink-muted)]">{t('records.authority.intro')}</p>

    <label class="flex flex-col gap-1 text-xs">
      <span>{t('records.authority.reason')}</span>
      <input
        bind:this={reasonBox}
        bind:value={authority.reason}
        maxlength="255"
        placeholder={t('records.authority.reasonPlaceholder')}
        class="w-72 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
        class:border-[var(--color-alert)]={needsReason}
      />
    </label>

    <label class="flex flex-col gap-1 text-xs">
      <span>{t('records.authority.caseNumber')}</span>
      <input
        bind:value={authority.caseNumber}
        maxlength="32"
        class="w-48 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
      />
    </label>
  </fieldset>

  {#if failure}
    <div class="border border-[var(--color-alert)] px-3 py-2 text-sm" role="alert">
      <p>{t(`error.${failure.err}`)}</p>
      {#if needsReason}
        <!--
          The one refusal an officer can act on immediately, so it offers the
          action rather than only naming the field. Never a count of what was
          withheld: the number is not sent, and asking for it would be asking
          the server to disclose what it refused.
        -->
        <p class="mt-1 text-xs">{t('query.needsReason')}</p>
        <button
          type="button"
          class="mt-1 border border-[var(--color-border)] px-2 py-0.5 text-xs"
          onclick={() => reasonBox?.focus()}
        >
          {t('query.action.giveReason')}
        </button>
      {:else if messages.length > 0}
        <ul class="mt-1 text-xs text-[var(--color-ink-muted)]">
          {#each messages as message (message.name)}
            <li>{message.label} — {message.reason}</li>
          {/each}
        </ul>
      {/if}
    </div>
  {/if}

  {#if status}
    <p class="text-xs text-[var(--color-ink-muted)]" role="status">{status}</p>
  {/if}

  {#if confirming}
    <ConfirmDialog
      label={t('query.action.confirm')}
      question={t('query.confirm.intro', { hit: hitText(confirming) })}
      {busy}
      {failure}
      fieldLabels={FIELD_LABELS}
      confirm={() => void confirm()}
      cancel={cancelConfirm}
    >
      <label class="mt-2 flex flex-col gap-1">
        <span>{t('query.field.outcome')}</span>
        <select bind:value={outcome} class="w-64 border border-[var(--color-border)] px-2 py-1">
          {#each OUTCOMES as key (key)}
            <option value={key}>{t(`query.confirm.${key}`)}</option>
          {/each}
        </select>
      </label>

      <label class="mt-2 flex flex-col gap-1">
        <span>{t('query.field.detail')}</span>
        <input
          bind:value={detail}
          maxlength="512"
          class="border border-[var(--color-border)] px-2 py-1"
          class:border-[var(--color-alert)]={detailMissing}
        />
        {#if detailMissing}
          <!--
            "It came back confirmed" is not an answer to "confirmed against
            what?". The server requires one of the two, so the screen says so
            beside the box rather than letting the refusal arrive afterwards.
          -->
          <span class="text-[var(--color-alert)]">{t('query.confirm.needsDetail')}</span>
        {/if}
      </label>
    </ConfirmDialog>
  {/if}

  {#if response}
    <p class="text-xs text-[var(--color-ink-muted)]">
      <!--
        Which registers answered, from the server's `sources`. An officer who
        may not run a name index is not told that one exists.
      -->
      {t('query.ran', {
        type: t(`query.type.${response.type}`),
        sources: response.sources.map((source) => t(`query.source.${source}`)).join(' · '),
      })}
    </p>

    {#if response.results.length === 0}
      <p class="border border-[var(--color-border)] px-3 py-2 text-xs text-[var(--color-ink-muted)]">
        {t('query.empty')}
      </p>
    {:else}
      <ul class="border border-[var(--color-border)]">
        <!-- Keyed by index: a stub carries no id (4.5). -->
        {#each response.results as row, index (index)}
          <li class="border-b border-[var(--color-border)] px-3 py-2 last:border-b-0">
            {#if isStub(row)}
              <p class="text-xs text-[var(--color-ink-muted)]">
                {t('records.restricted.title')} — {stubContact(row)}
              </p>
            {:else}
              <div class="flex flex-wrap items-baseline justify-between gap-2">
                <span class="font-[family-name:var(--font-mono)] text-sm">{label(row)}</span>
                <span class="text-xs text-[var(--color-ink-muted)]">
                  {t(`query.source.${row.kind}`)}
                  {#if detailOf(row)}
                    · {detailOf(row)}
                  {/if}
                </span>
              </div>

              {#each row.hits ?? [] as hit (hit.hitType + hit.hitId)}
                <!--
                  The banner. Everything that reaches this list has already been
                  judged worth interrupting somebody for on the server — the
                  four efterlysning grounds that are not "detain on sight"
                  never become a hit, and a lookout only does at priority 1.
                  What is left for the screen is the distinction between a lead
                  and a confirmed one, in words as well as in colour (6.2).
                -->
                <div
                  class="mt-1 flex flex-wrap items-center gap-2 border px-2 py-1 text-xs"
                  class:border-[var(--color-alert)]={!hit.confirmed}
                  class:border-[var(--color-clear)]={hit.confirmed}
                  role="alert"
                >
                  <span class="font-semibold">{hitText(hit)}</span>
                  <span class="text-[var(--color-ink-muted)]">
                    {t(hit.confirmed ? 'query.status.confirmed' : 'query.status.unconfirmed')}
                  </span>

                  {#if !hit.confirmed}
                    <button
                      type="button"
                      class="border border-[var(--color-border)] px-2 py-0.5"
                      disabled={busy}
                      onclick={(event) => {
                        trigger = event.currentTarget;
                        confirming = hit;
                        outcome = 'confirmed';
                        detail = '';
                        failure = null;
                        status = '';
                      }}
                    >
                      {t('query.action.confirm')}
                    </button>
                  {/if}
                </div>
              {/each}
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
  {/if}

  {#if showLog}
    <section class="border border-[var(--color-border)]">
      <h2 class="border-b border-[var(--color-border)] px-3 py-2 text-xs font-semibold">
        {t('query.log.title')}
      </h2>

      {#if log.length === 0}
        <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">{t('query.log.empty')}</p>
      {:else}
        <div class="overflow-x-auto">
          <table class="w-full text-xs">
            <thead class="bg-[var(--color-surface)]">
              <tr>
                <th class="px-2 py-1 text-left font-semibold">{t('query.log.at')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('query.log.type')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('query.log.term')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('query.log.results')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('query.log.acted')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('records.authority.reason')}</th>
              </tr>
            </thead>
            <tbody>
              {#each log as entry (entry.id)}
                <tr class="border-t border-[var(--color-border)]">
                  <td class="px-2 py-1 font-[family-name:var(--font-mono)] whitespace-nowrap">
                    {formatMoment(entry.createdAt)}
                  </td>
                  <td class="px-2 py-1">{t(`query.type.${entry.queryType}`)}</td>
                  <td class="px-2 py-1 font-[family-name:var(--font-mono)]">{entry.term}</td>
                  <td class="px-2 py-1 whitespace-nowrap">
                    {t('query.log.counts', {
                      results: String(entry.resultCount),
                      hits: String(entry.hitCount),
                    })}
                  </td>
                  <td class="px-2 py-1 whitespace-nowrap">
                    <!--
                      Whether a hit this query raised was ever confirmed. The
                      absence is the point: acting on an unconfirmed hit is
                      something a department may ask about later, and the log
                      is where the question gets answered.
                    -->
                    {#if entry.hitCount > 0}
                      {t('query.log.confirmations', {
                        confirmed: String(entry.confirmedCount),
                        total: String(entry.confirmationCount),
                      })}
                    {/if}
                  </td>
                  <td class="px-2 py-1">{entry.reason ?? entry.caseNumber ?? ''}</td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
        <LoadMore nextCursor={logCursor} {busy} loadMore={loadMoreLog} />
      {/if}
    </section>
  {/if}
</div>
