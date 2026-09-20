<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { fieldList, type Failure } from '../shared/failure';
  import type { Moment } from './types';

  /**
   * Brottskatalogen — the offence catalogue and BrB 26's arithmetic (spec 7.10).
   *
   * Two things live here, and the second is the reason it is a screen rather
   * than a reference table:
   *
   *   * **The catalogue**, versioned. An offence is never edited in place: a
   *     change supersedes the row and every record keeps the version it was
   *     charged under, so a report from March still reads the way the statute
   *     read in March. The history is `brott.versions`.
   *   * **The gemensam straffskala** (BrB 26:2). Charge somebody with three
   *     offences and the range is not the sum of three ranges — the maximum
   *     rises by a bounded amount above the severest single one, and the
   *     minimum is the severest minimum. That is the figure an officer reads
   *     off the screen and repeats to a prosecutor, so it is computed on the
   *     server against rows the server fetched. Nothing here adds months.
   *
   * **There is no editor, deliberately.** `brott.create`, `brott.version` and
   * `brott.retire` exist and are behind `admin.brott.edit`, but an offence's
   * name is a *locale key* (invariant 6) — a new offence needs a key in both
   * `en.json` and `sv.json`, which is a deploy and not a form. A create screen
   * here could only offer keys that already exist, which is to say offences
   * that already exist. The catalogue is seeded and changed with the code.
   */

  interface Brott {
    id: number;
    code: string;
    version: number;
    balk?: string | null;
    kapitel?: number | null;
    paragraf?: number | null;
    stycke?: number | null;
    labelKey: string;
    descriptionKey?: string | null;
    grad: string;
    boter: boolean;
    fangelseMinMonths?: number | null;
    fangelseMaxMonths?: number | null;
    forsok: boolean;
    forberedelse: boolean;
    preskriptionYears?: number | null;
    supersededAt?: Moment;
    createdAt?: Moment;
    /** Derived on the server — one definition of `BrB 8:1`, and busted tests it. */
    citation?: string | null;
  }

  interface Straffskala {
    boter: boolean;
    min: number;
    max: number | null;
  }

  let catalogue = $state<Brott[]>([]);
  let versions = $state<Brott[]>([]);
  let versionsOf = $state<string | null>(null);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);
  let filter = $state('');

  /**
   * The charges being priced, as ids — with duplicates.
   *
   * Three counts of one offence is three entries, because BrB 26:2 is computed
   * over counts rather than over distinct offences. `brott.straffskala` keeps
   * them for the same reason.
   */
  let charges = $state<number[]>([]);
  let gemensam = $state<Straffskala | null>(null);

  const FIELD_LABELS: Record<string, string> = {
    code: 'brott.column.code',
    brottIds: 'brott.charges.title',
  };

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  /** Filtered in the browser: `brott.list` takes no filter and sends the lot. */
  const shown = $derived(
    catalogue.filter((row) => {
      const needle = filter.trim().toLowerCase();
      if (!needle) return true;

      return (
        (row.citation ?? '').toLowerCase().includes(needle) ||
        row.code.toLowerCase().includes(needle) ||
        t(row.labelKey).toLowerCase().includes(needle)
      );
    }),
  );

  /** The charge list as offences and counts, which is how it reads. */
  const counted = $derived(
    charges.reduce<{ row: Brott; count: number }[]>((out, id) => {
      const existing = out.find((entry) => entry.row.id === id);
      if (existing) {
        existing.count += 1;

        return out;
      }

      const row = catalogue.find((entry) => entry.id === id);
      if (row) out.push({ row, count: 1 });

      return out;
    }, []),
  );

  async function load(): Promise<void> {
    busy = true;

    const response = await nui.call<{ brott: Brott[] }>('brott.list', {});

    if (response.ok) {
      catalogue = response.data.brott ?? [];
      failure = null;
    } else {
      failure = response;
    }

    busy = false;
  }

  async function showVersions(code: string): Promise<void> {
    busy = true;

    const response = await nui.call<{ versions: Brott[] }>('brott.versions', { code });

    if (response.ok) {
      versions = response.data.versions ?? [];
      versionsOf = code;
      failure = null;
    } else {
      versions = [];
      versionsOf = null;
      failure = response;
    }

    busy = false;
  }

  async function price(): Promise<void> {
    if (charges.length === 0) {
      gemensam = null;

      return;
    }

    busy = true;

    const response = await nui.call<{ straffskala: Straffskala }>('brott.straffskala', {
      // Strings, as the schema asks: the ids are sent as a bounded list of
      // short strings rather than as numbers.
      brottIds: charges.map((id) => String(id)),
    });

    if (response.ok) {
      gemensam = response.data.straffskala;
      failure = null;
    } else {
      gemensam = null;
      failure = response;
    }

    busy = false;
  }

  function addCharge(id: number): void {
    charges = [...charges, id];
    void price();
  }

  function removeCharge(id: number): void {
    const at = charges.lastIndexOf(id);
    if (at === -1) return;

    charges = [...charges.slice(0, at), ...charges.slice(at + 1)];
    void price();
  }

  /** A span in the words BrB 26 uses. Months become years where they divide. */
  function span(skala: Straffskala): string {
    if (skala.max === null) return t('brott.straffskala.livstid');

    const max = months(skala.max);

    return skala.min > 0
      ? t('brott.straffskala.atLeast', { min: months(skala.min), max })
      : t('brott.straffskala.upTo', { max });
  }

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

  /** The row's own span, for the catalogue list. */
  function rowSpan(row: Brott): string {
    const parts: string[] = [];

    if (row.boter) parts.push(t('brott.straffskala.boter'));

    if (row.fangelseMaxMonths !== null && row.fangelseMaxMonths !== undefined) {
      parts.push(span({ boter: row.boter, min: row.fangelseMinMonths ?? 0, max: row.fangelseMaxMonths }));
    }

    return parts.join(' · ');
  }

  void load();
</script>

<div class="flex flex-col gap-3">
  <form
    class="flex flex-wrap items-end gap-2"
    onsubmit={(event) => event.preventDefault()}
  >
    <label class="flex flex-col gap-1 text-xs">
      {t('brott.filter.term')}
      <input
        bind:value={filter}
        placeholder={t('brott.filter.placeholder')}
        class="w-80 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
      />
    </label>
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

  <div class="grid gap-4 md:grid-cols-[minmax(0,1.5fr)_minmax(0,1fr)]">
    <div class="border border-[var(--color-border)]">
      {#if shown.length === 0}
        <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">{t('brott.empty')}</p>
      {:else}
        <div class="overflow-x-auto">
          <table class="w-full text-xs">
            <thead class="bg-[var(--color-surface)]">
              <tr>
                <th class="px-2 py-1 text-left font-semibold">{t('brott.column.citation')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('brott.column.rubrik')}</th>
                <th class="px-2 py-1 text-left font-semibold">{t('brott.column.grad')}</th>
                <th class="px-2 py-1 text-left font-semibold">
                  {t('brott.column.straffskala')}
                </th>
                <th class="px-2 py-1 text-left font-semibold">
                  <span class="sr-only">{t('brott.charges.add')}</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {#each shown as row (row.id)}
                <tr class="border-t border-[var(--color-border)]">
                  <td class="px-2 py-1 font-[family-name:var(--font-mono)] whitespace-nowrap">
                    <button
                      type="button"
                      class="underline-offset-2 hover:underline"
                      onclick={() => void showVersions(row.code)}
                    >
                      {row.citation ?? row.code}
                    </button>
                  </td>
                  <td class="px-2 py-1">
                    {t(row.labelKey)}
                    <!--
                      What BrB 23 makes punishable at an earlier stage. Not
                      every offence has an attempt, and charging one that does
                      not is `stage_unavailable` on the anmälan.
                    -->
                    {#if row.forsok || row.forberedelse}
                      <span class="text-[var(--color-ink-muted)]">
                        ({[
                          row.forsok ? t('anmalan.stage.forsok') : '',
                          row.forberedelse ? t('anmalan.stage.forberedelse') : '',
                        ]
                          .filter(Boolean)
                          .join(', ')})
                      </span>
                    {/if}
                  </td>
                  <td class="px-2 py-1 whitespace-nowrap">{t(`brott.grad.${row.grad}`)}</td>
                  <td class="px-2 py-1">{rowSpan(row)}</td>
                  <td class="px-2 py-1 whitespace-nowrap">
                    <button
                      type="button"
                      class="border border-[var(--color-border)] px-2 py-0.5"
                      disabled={busy}
                      onclick={() => addCharge(row.id)}
                    >
                      {t('brott.charges.add')}
                    </button>
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      {/if}
    </div>

    <div class="flex flex-col gap-3">
      <!-- BrB 26:2 -->
      <section class="border border-[var(--color-border)] p-3">
        <h2 class="mb-1 text-xs font-semibold">{t('brott.charges.title')}</h2>

        {#if counted.length === 0}
          <p class="text-xs text-[var(--color-ink-muted)]">{t('brott.charges.empty')}</p>
        {:else}
          <ul class="text-xs">
            {#each counted as entry (entry.row.id)}
              <li
                class="flex items-baseline justify-between gap-2 border-t border-[var(--color-border)] py-1"
              >
                <span>
                  <span class="font-[family-name:var(--font-mono)]">
                    {entry.row.citation ?? entry.row.code}
                  </span>
                  — {t(entry.row.labelKey)}
                  {#if entry.count > 1}
                    <span class="text-[var(--color-ink-muted)]">
                      × {entry.count}
                    </span>
                  {/if}
                </span>
                <button
                  type="button"
                  class="border border-[var(--color-border)] px-2 py-0.5"
                  onclick={() => removeCharge(entry.row.id)}
                >
                  {t('brott.charges.remove')}
                </button>
              </li>
            {/each}
          </ul>

          {#if gemensam}
            <!--
              The server's arithmetic, not a sum computed here. Three counts do
              not make three times the range: BrB 26:2 raises the maximum by a
              bounded amount above the severest single offence, and this is the
              figure repeated to a prosecutor.
            -->
            <p class="mt-2 border-t border-[var(--color-border)] pt-2 text-xs">
              <span class="font-semibold">{t('brott.column.straffskala')}:</span>
              {span(gemensam)}
              {#if gemensam.boter}
                · {t('brott.straffskala.boter')}
              {/if}
            </p>
          {/if}
        {/if}
      </section>

      <!-- The history of one offence -->
      {#if versionsOf}
        <section class="border border-[var(--color-border)] p-3">
          <h2 class="mb-1 text-xs font-semibold">
            {t('brott.versions.title', { code: versionsOf })}
          </h2>

          <!--
            Never edited in place: a change supersedes the row, and a record
            keeps the version it was charged under — so a report from March
            still reads the way the statute read in March.
          -->
          <ul class="text-xs">
            {#each versions as version (version.id)}
              <li class="border-t border-[var(--color-border)] py-1">
                <div class="flex justify-between gap-2">
                  <span>{t('brott.versions.version', { version: String(version.version) })}</span>
                  <span class="font-[family-name:var(--font-mono)] whitespace-nowrap">
                    {version.supersededAt
                      ? t('brott.versions.until', { at: formatMoment(version.supersededAt) })
                      : t('brott.versions.current')}
                  </span>
                </div>
                <p class="text-[var(--color-ink-muted)]">
                  {t(version.labelKey)} — {rowSpan(version)}
                </p>
              </li>
            {/each}
          </ul>
        </section>
      {/if}
    </div>
  </div>
</div>
