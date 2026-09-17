<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { INTEL_CONFIDENCE, INTEL_SOURCES } from '@fredpd/schema';
  import type { ErrorCode } from '@fredpd/schema';
  import type { IntelNote, IntelTag } from '../../lib/types';

  /**
   * The intelligence log (spec 10): everything logged, newest first, filtered
   * by tag.
   *
   * A note can attach to a person, an organisation, a case, any combination, or
   * nothing at all — the last is how a tip is recorded before anyone knows who
   * it concerns, and the composer defaults to it.
   */

  let notes = $state<IntelNote[]>([]);
  let tags = $state<IntelTag[]>([]);
  let activeTag = $state<string | null>(null);
  let error = $state<ErrorCode | null>(null);
  let loading = $state(true);
  let busy = $state(false);

  let body = $state('');
  let tagInput = $state('');
  let source = $state('');
  let confidence = $state('medium');

  async function load(): Promise<void> {
    const [noteResponse, tagResponse] = await Promise.all([
      nui.call<{ notes: IntelNote[] }>('intel.note.list', activeTag ? { tag: activeTag } : {}),
      nui.call<{ tags: IntelTag[] }>('intel.tags'),
    ]);

    if (noteResponse.ok) {
      notes = noteResponse.data.notes;
      error = null;
    } else {
      error = noteResponse.err;
    }

    if (tagResponse.ok) tags = tagResponse.data.tags;
    loading = false;
  }

  $effect(() => {
    // Re-runs when the tag filter changes: reading it here is the dependency.
    void activeTag;
    void load();
  });

  async function post(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy || body.trim() === '') return;

    busy = true;

    const response = await nui.call('intel.note.create', {
      body: body.trim(),
      tags: tagInput
        .split(',')
        .map((tag) => tag.trim())
        .filter(Boolean),
      source: source || undefined,
      confidence,
    });

    if (response.ok) {
      body = '';
      tagInput = '';
      source = '';
      await load();
    } else {
      error = response.err;
    }

    busy = false;
  }

  /** The server sends the author's Discord id; a callsign needs the roster. */
  function when(value: string): string {
    return value.replace('T', ' ').slice(0, 16);
  }
</script>

<section class="flex min-h-0 flex-col gap-4">
  <!-- Tag bar. Tags live on intelligence rather than on people, so every tag
       filter in the module goes through here. -->
  <div class="flex flex-wrap items-center gap-1.5">
    <button
      type="button"
      class="border border-[var(--color-border)] px-2 py-0.5 text-xs hover:bg-[var(--color-surface)]"
      class:font-semibold={activeTag === null}
      onclick={() => (activeTag = null)}
    >
      {t('intel.log.allTags')}
    </button>

    {#each tags as tag (tag.tag)}
      <button
        type="button"
        class="border border-[var(--color-border)] px-2 py-0.5 text-xs hover:bg-[var(--color-surface)]"
        class:font-semibold={activeTag === tag.tag}
        onclick={() => (activeTag = activeTag === tag.tag ? null : tag.tag)}
      >
        {tag.tag}
        <span class="text-[var(--color-ink-muted)]">{tag.uses}</span>
      </button>
    {/each}
  </div>

  <!-- Composer -->
  <form class="flex flex-col gap-2 border border-[var(--color-border)] p-3" onsubmit={post}>
    <label class="flex flex-col gap-1 text-xs">
      <span>{t('intel.log.body')}</span>
      <textarea
        class="min-h-20 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
        bind:value={body}
        placeholder={t('intel.log.bodyPlaceholder')}
        required
      ></textarea>
    </label>

    <div class="flex flex-wrap items-end gap-3">
      <label class="flex flex-col gap-1 text-xs">
        <span>{t('intel.log.tags')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={tagInput}
          placeholder={t('intel.log.tagsPlaceholder')}
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('intel.log.source')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={source}
        >
          <option value="">{t('intel.source.none')}</option>
          {#each INTEL_SOURCES as value (value)}
            <option {value}>{t(`intel.source.${value}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('intel.log.confidence')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={confidence}
        >
          {#each INTEL_CONFIDENCE as value (value)}
            <option {value}>{t(`intel.confidence.${value}`)}</option>
          {/each}
        </select>
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
        disabled={busy}
      >
        {t('intel.log.post')}
      </button>
    </div>
  </form>

  {#if error}
    <p class="border border-[var(--color-border)] px-3 py-2 text-sm">{t(`error.${error}`)}</p>
  {/if}

  {#if loading}
    <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
  {:else if notes.length === 0}
    <p class="text-sm text-[var(--color-ink-muted)]">{t('intel.log.empty')}</p>
  {:else}
    <ol class="flex flex-col gap-2">
      {#each notes as note (note.id)}
        <li class="border border-[var(--color-border)] p-3">
          <p class="text-sm whitespace-pre-wrap">{note.body}</p>

          <div class="mt-2 flex flex-wrap items-center gap-3 text-xs text-[var(--color-ink-muted)]">
            <span>{when(note.createdAt)}</span>

            <!-- A protected source is withheld, not the intelligence itself.
                 Saying so is better than an empty field that looks like an
                 oversight (spec 10.6). -->
            {#if note.sourceProtected}
              <span>{t('intel.source.protected')}</span>
            {:else if note.source}
              <span>{t(`intel.source.${note.source}`)}</span>
            {/if}

            <span>{t(`intel.confidence.${note.confidence}`)}</span>

            {#each note.tags as tag (tag)}
              <button
                type="button"
                class="border border-[var(--color-border)] px-1.5 hover:bg-[var(--color-surface)]"
                onclick={() => (activeTag = tag)}
              >
                {tag}
              </button>
            {/each}
          </div>
        </li>
      {/each}
    </ol>
  {/if}
</section>
