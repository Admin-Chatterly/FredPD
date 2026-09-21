<script lang="ts">
  import IntelLog from './IntelLog.svelte';
  import IntelPerson from './IntelPerson.svelte';
  import IntelOrg from './IntelOrg.svelte';
  import IntelCase from './IntelCase.svelte';
  import { t } from '../../lib/i18n';

  /**
   * The intelligence module (spec 10) — PD-Span, rebuilt on the server's own
   * database.
   *
   * Four tabs: the log, people, organizations and cases. The log is first
   * because it is what an officer opens the module to do; the other three
   * are each a self-contained master/detail screen with its own create,
   * update, delete and merge writes (spec 10, D3) — `intel.*` carries thirty
   * routes and every one of them is reachable from here or from `IntelLog`.
   */

  type Tab = 'log' | 'people' | 'orgs' | 'cases';

  let tab = $state<Tab>('log');

  const tabs: Tab[] = ['log', 'people', 'orgs', 'cases'];
</script>

<section class="flex min-h-0 flex-1 flex-col gap-4">
  <nav class="flex gap-1 border-b border-[var(--color-border)]">
    {#each tabs as name (name)}
      <button
        type="button"
        class="px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
        class:font-semibold={tab === name}
        onclick={() => (tab = name)}
      >
        {t(`intel.tab.${name}`)}
      </button>
    {/each}
  </nav>

  {#if tab === 'log'}
    <IntelLog />
  {:else if tab === 'people'}
    <IntelPerson />
  {:else if tab === 'orgs'}
    <IntelOrg />
  {:else}
    <IntelCase />
  {/if}
</section>
