<script lang="ts">
  import { t } from '../../lib/i18n';
  import { personName } from '../shared/names';
  import type { LabCandidate } from './types';

  /**
   * The people a candidate match points at (8.1.3): a lead to follow up and
   * confirm with a fresh reference sample, never an identification -- and
   * the wording says so every time it is drawn.
   */
  interface Props {
    candidates?: LabCandidate[] | undefined;
    withheld?: number | undefined;
  }

  let { candidates = [], withheld = 0 }: Props = $props();
</script>

{#if candidates.length > 0 || withheld > 0}
  <div class="mt-1 border border-[var(--color-caution)] px-2 py-1 text-xs">
    <p class="font-semibold">{t('lab.candidate.title')}</p>
    {#each candidates as person (person.id)}
      <p>
        {personName(person) || '—'}
        <span class="font-[family-name:var(--font-mono)]">({person.personNumber})</span>
      </p>
    {/each}
    {#if withheld > 0}
      <p class="text-[var(--color-ink-muted)]">{t('lab.candidate.withheld', { count: withheld })}</p>
    {/if}
    <p class="text-[var(--color-ink-muted)]">{t('lab.candidate.confirm')}</p>
  </div>
{/if}
