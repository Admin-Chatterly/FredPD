<script generics="T" lang="ts">
  import { t } from '../../lib/i18n';

  /**
   * A search-as-you-type box for attaching an *existing* record to another
   * one -- naming a vehicle's owner, linking a person into a case, picking
   * the organization a membership belongs to. Every one of those was a bare
   * numeric id box before this: an officer had to already know the id of the
   * record they meant, copied from another screen, to fill in a form field.
   *
   * This component owns none of that knowledge. It debounces what is typed,
   * hands it to the `search` the caller supplied, and draws whatever comes
   * back -- which route that calls, what it searches, and what a result
   * looks like are entirely the caller's (a vehicle picker searches
   * `vehicle.search` and shows the plate and model; a person picker searches
   * `person.search` or `intel.search` and shows a name). `onSelect` is the
   * only thing it decides on the caller's behalf: which of the results the
   * officer meant.
   *
   * Access is still the server's, same as any other search screen (invariant
   * 4): this draws only what `search` returns, and a record withheld by
   * access control there is a record this never shows.
   */

  interface Props {
    placeholder?: string;
    /** Runs on every debounced keystroke, including an empty term -- whether
     *  that means "browse everything" or "nothing to search yet" is the
     *  caller's route to decide, not this component's. */
    search: (term: string) => Promise<T[]>;
    /** The line an officer reads to tell one result from the next. */
    label: (item: T) => string;
    /** A second, muted line -- "the owner, model, plate etc" the officer
     *  typed part of, so a match reads as a match rather than a coincidence. */
    detail?: (item: T) => string | null | undefined;
    getKey: (item: T) => string | number;
    onSelect: (item: T) => void;
    disabled?: boolean;
    /** Milliseconds of silence before a keystroke actually searches. */
    debounceMs?: number;
    /** The label of whatever is currently chosen elsewhere in the caller's
     *  form, if anything -- drawn as a confirmation line under the box, so
     *  picking a result (which clears the search text) does not read as
     *  "nothing chosen" the moment the dropdown closes. */
    selectedLabel?: string | null;
    /** Clears the caller's own selection. Omitted, the confirmation line
     *  carries no clear button -- some callers have nothing to reset it to. */
    onClear?: () => void;
  }

  let {
    placeholder = '',
    search,
    label,
    detail,
    getKey,
    onSelect,
    disabled = false,
    debounceMs = 250,
    selectedLabel = null,
    onClear,
  }: Props = $props();

  let term = $state('');
  let results = $state<T[]>([]);
  let open = $state(false);
  let busy = $state(false);
  let highlighted = $state(-1);

  let timer: ReturnType<typeof setTimeout> | undefined;
  // Bumped on every call so a slow answer to an earlier keystroke cannot
  // overwrite a faster answer to a later one -- the standard type-ahead race.
  let requestId = 0;

  async function runSearch(): Promise<void> {
    const id = ++requestId;
    busy = true;

    const found = await search(term);
    if (id !== requestId) return;

    results = found;
    highlighted = found.length > 0 ? 0 : -1;
    open = true;
    busy = false;
  }

  function onInput(): void {
    clearTimeout(timer);
    timer = setTimeout(() => void runSearch(), debounceMs);
  }

  function choose(item: T): void {
    onSelect(item);
    term = '';
    results = [];
    open = false;
    highlighted = -1;
  }

  function onKeydown(event: KeyboardEvent): void {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      if (!open && results.length > 0) {
        open = true;
        return;
      }
      highlighted = Math.min(highlighted + 1, results.length - 1);
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      highlighted = Math.max(highlighted - 1, 0);
    } else if (event.key === 'Enter') {
      // Always stopped, whether or not there is a result to choose: this box
      // is for searching, and a caller almost always sits it inside a larger
      // form (registering a vehicle, adding an associate) whose own Enter
      // submits that form -- which "confirm this search" must not trigger.
      event.preventDefault();

      const picked = open && highlighted >= 0 ? results[highlighted] : undefined;
      if (picked) choose(picked);
    } else if (event.key === 'Escape' && open) {
      // Closes the list, not the whole interface: stopped here the same way
      // `ConfirmDialog` stops it, so `main.ts`'s window-level Escape handler
      // never sees this one.
      event.stopPropagation();
      event.preventDefault();
      open = false;
    }
  }
</script>

<div class="relative">
  <input
    type="text"
    role="combobox"
    aria-expanded={open}
    aria-autocomplete="list"
    aria-controls="entity-picker-listbox"
    class="w-full border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
    {placeholder}
    {disabled}
    bind:value={term}
    oninput={onInput}
    onfocus={() => {
      if (results.length > 0) open = true;
    }}
    onkeydown={onKeydown}
    onblur={() => (open = false)}
  />

  {#if open}
    <ul
      id="entity-picker-listbox"
      role="listbox"
      class="absolute z-10 mt-0.5 max-h-48 w-full overflow-y-auto border border-[var(--color-border)] bg-[var(--color-panel)] text-xs"
    >
      {#if busy}
        <li class="px-2 py-1 text-[var(--color-ink-muted)]">{t('form.searching')}</li>
      {:else if results.length === 0}
        <li class="px-2 py-1 text-[var(--color-ink-muted)]">{t('form.noMatches')}</li>
      {:else}
        {#each results as item, index (getKey(item))}
          <li role="option" aria-selected={index === highlighted}>
            <button
              type="button"
              class="block w-full px-2 py-1 text-left hover:bg-[var(--color-surface)]"
              class:bg-[var(--color-surface)]={index === highlighted}
              onmousedown={(event) => event.preventDefault()}
              onclick={() => choose(item)}
            >
              <span class="block">{label(item)}</span>
              {#if detail?.(item)}
                <span class="block text-[var(--color-ink-muted)]">{detail(item)}</span>
              {/if}
            </button>
          </li>
        {/each}
      {/if}
    </ul>
  {/if}

  {#if selectedLabel}
    <p class="mt-0.5 text-[var(--color-ink-muted)]">
      {t('form.selected', { value: selectedLabel })}
      {#if onClear}
        <button type="button" class="underline" onclick={onClear}>
          {t('form.clearSelection')}
        </button>
      {/if}
    </p>
  {/if}
</div>
