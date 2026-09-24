<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';

  /**
   * Picks offences from the agency's brottskatalog (7.10) by name or
   * citation, as a checklist -- for every screen that used to ask for charges
   * as a comma-typed list of internal ids.
   *
   * `selected` holds the catalogue ids. The server checks each against the
   * catalogue again (`brott.parseIds`, `brott.expandCharges`); this only
   * saves an officer from knowing them. A catalogue the session may not read
   * says so, rather than looking empty.
   */
  interface CatalogRow {
    id: number;
    code: string;
    labelKey: string;
    citation?: string | null;
  }

  interface Props {
    selected: number[];
    /** The caption of the group, e.g. "Charges". */
    legend: string;
    required?: boolean;
    disabled?: boolean;
  }

  let { selected = $bindable([]), legend, required = false, disabled = false }: Props = $props();

  /** What `brott.parseIds` accepts in one call. */
  const MAX = 25;

  const uid = $props.id();

  let catalog = $state<CatalogRow[]>([]);
  let refusal = $state<string | null>(null);
  let filter = $state('');
  let filterBox = $state<HTMLInputElement | null>(null);

  $effect(() => {
    void (async () => {
      const response = await nui.call<{ brott: CatalogRow[] }>('brott.list', {});
      if (response.ok) {
        catalog = response.data.brott ?? [];
        refusal = null;
      } else {
        refusal = response.err;
      }
    })();
  });

  // Where the officer starts typing, as soon as the checklist appears.
  $effect(() => {
    filterBox?.focus();
  });

  const shown = $derived.by(() => {
    const needle = filter.trim().toLowerCase();

    return catalog.filter(
      (row) =>
        selected.includes(row.id) ||
        needle === '' ||
        t(row.labelKey).toLowerCase().includes(needle) ||
        (row.citation ?? row.code).toLowerCase().includes(needle),
    );
  });

  function toggle(id: number): void {
    if (selected.includes(id)) {
      selected = selected.filter((value) => value !== id);
    } else if (selected.length < MAX) {
      selected = [...selected, id];
    }
  }

  /**
   * Enter filters; it never submits the form around this (a charging
   * decision's confirmation must not open because somebody pressed Enter in
   * a search box). With exactly one unticked match left, Enter ticks it.
   */
  function onFilterKeydown(event: KeyboardEvent): void {
    if (event.key !== 'Enter') return;

    event.preventDefault();
    const candidates = shown.filter((row) => !selected.includes(row.id));
    const only = candidates.length === 1 ? candidates[0] : undefined;
    if (only) toggle(only.id);
  }
</script>

<fieldset class="flex flex-col gap-1 border border-[var(--color-border)] px-2 py-1 text-xs">
  <legend class="px-1">
    {legend}
    {#if required}<span aria-hidden="true">*</span>{/if}
    <span class="text-[var(--color-ink-muted)]">— {t('picker.charges.count', { count: selected.length, max: MAX })}</span>
  </legend>

  {#if refusal}
    <p class="text-[var(--color-caution)]" role="alert">{t(`error.${refusal}`)}</p>
  {:else}
    <label class="flex flex-col gap-1" for={`${uid}-filter`}>
      <span>{t('picker.charges.filter')}</span>
    </label>
    <input
      id={`${uid}-filter`}
      type="search"
      class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
      bind:value={filter}
      bind:this={filterBox}
      onkeydown={onFilterKeydown}
      {disabled}
    />
    <div class="flex max-h-48 flex-col overflow-y-auto">
      {#each shown as row (row.id)}
        <label class="flex items-baseline gap-2 py-0.5">
          <input
            type="checkbox"
            checked={selected.includes(row.id)}
            onchange={() => toggle(row.id)}
            disabled={disabled || (!selected.includes(row.id) && selected.length >= MAX)}
          />
          <span class="font-[family-name:var(--font-mono)]">{row.citation ?? row.code}</span>
          <span>{t(row.labelKey)}</span>
        </label>
      {:else}
        <p class="text-[var(--color-ink-muted)]">{t('form.noMatches')}</p>
      {/each}
    </div>
  {/if}
</fieldset>
