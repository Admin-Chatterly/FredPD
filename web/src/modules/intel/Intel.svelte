<script lang="ts">
  import IntelLog from './IntelLog.svelte';
  import IntelPerson from './IntelPerson.svelte';
  import IntelOrg from './IntelOrg.svelte';
  import IntelCase from './IntelCase.svelte';
  import IntelBoard from './IntelBoard.svelte';
  import { t } from '../../lib/i18n';

  /**
   * The intelligence module (spec 10) — PD-Span, rebuilt on the server's own
   * database.
   *
   * Five tabs: the log, people, organizations, cases and the link diagram. The log is first
   * because it is what an officer opens the module to do; the other three
   * are each a self-contained master/detail screen with its own create,
   * update, delete and merge writes (spec 10, D3) — `intel.*` carries thirty
   * routes and every one of them is reachable from here or from `IntelLog`.
   */

  type Tab = 'log' | 'people' | 'orgs' | 'cases' | 'board';

  let tab = $state<Tab>('log');

  // The link diagram (10.6) opens a record on its own tab.
  let openPersonId = $state<number | null>(null);
  let openOrgId = $state<number | null>(null);

  const tabs: Tab[] = ['log', 'people', 'orgs', 'cases', 'board'];
</script>

<section class="flex min-h-0 flex-1 flex-col gap-4">
  <nav class="flex gap-1 border-b border-[var(--color-border)]">
    {#each tabs as name (name)}
      <button
        type="button"
        class="px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
        class:font-semibold={tab === name}
        onclick={() => {
          // A record the diagram opened is not reopened on every later visit.
          openPersonId = null;
          openOrgId = null;
          tab = name;
        }}
      >
        {t(`intel.tab.${name}`)}
      </button>
    {/each}
  </nav>

  {#if tab === 'log'}
    <IntelLog />
  {:else if tab === 'people'}
    <IntelPerson initialId={openPersonId} />
  {:else if tab === 'orgs'}
    <IntelOrg initialId={openOrgId} />
  {:else if tab === 'cases'}
    <IntelCase />
  {:else}
    <IntelBoard
      onOpenPerson={(id) => {
        openPersonId = id;
        tab = 'people';
      }}
      onOpenOrg={(id) => {
        openOrgId = id;
        tab = 'orgs';
      }}
    />
  {/if}
</section>
