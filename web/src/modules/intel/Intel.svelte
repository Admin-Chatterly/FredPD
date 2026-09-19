<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import type { ErrorCode } from '@fredpd/schema';
  import type { IntelCase, IntelOrg, IntelPerson } from '../../lib/types';
  import IntelLog from './IntelLog.svelte';

  /**
   * The intelligence module (spec 10) — PD-Span, rebuilt on the server's own
   * database.
   *
   * Four views: the log, people, organizations and cases. The log is first
   * because it is what an officer opens the module to do.
   */

  type Tab = 'log' | 'people' | 'orgs' | 'cases';

  let tab = $state<Tab>('log');

  let persons = $state<IntelPerson[]>([]);
  let orgs = $state<IntelOrg[]>([]);
  let cases = $state<IntelCase[]>([]);
  let error = $state<ErrorCode | null>(null);
  let loading = $state(false);

  /**
   * Loads whichever list the current tab needs. The log loads itself, because
   * it also owns the tag bar and the composer.
   */
  $effect(() => {
    const current = tab;
    if (current === 'log') return;

    let cancelled = false;
    loading = true;

    void (async () => {
      const route = { people: 'intel.person.list', orgs: 'intel.org.list', cases: 'intel.case.list' }[
        current
      ];

      const response = await nui.call<Record<string, unknown>>(route, {});
      if (cancelled) return;

      if (response.ok) {
        error = null;
        if (current === 'people') persons = response.data['persons'] as IntelPerson[];
        if (current === 'orgs') orgs = response.data['orgs'] as IntelOrg[];
        if (current === 'cases') cases = response.data['cases'] as IntelCase[];
      } else {
        error = response.err;
      }

      loading = false;
    })();

    return () => {
      cancelled = true;
    };
  });

  const tabs: Tab[] = ['log', 'people', 'orgs', 'cases'];
</script>

<section class="flex min-h-0 flex-col gap-4">
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
  {:else if error}
    <p class="text-sm">{t(`error.${error}`)}</p>
  {:else if loading}
    <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
  {:else if tab === 'people'}
    {#if persons.length === 0}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('intel.person.empty')}</p>
    {:else}
      <ul class="flex flex-col">
        {#each persons as person (person.id)}
          <li class="border-b border-[var(--color-border)] py-2 last:border-b-0">
            <div class="flex items-baseline justify-between gap-3">
              <span class="text-sm">
                <!-- A person may have neither a name nor an alias: that is a
                     description in the register, not a broken row (spec 10). -->
                {person.name ?? person.alias ?? t('intel.person.unknown')}
              </span>
              <span class="text-xs text-[var(--color-ink-muted)]">
                {t(`intel.personStatus.${person.status}`)}
              </span>
            </div>

            {#if person.description}
              <p class="mt-0.5 text-xs text-[var(--color-ink-muted)]">{person.description}</p>
            {/if}

            <div class="mt-1 flex flex-wrap gap-3 text-xs text-[var(--color-ink-muted)]">
              <span>{t('intel.person.noteCount', { count: person.noteCount ?? 0 })}</span>
              {#if person.plates}
                <span>{person.plates}</span>
              {/if}
            </div>
          </li>
        {/each}
      </ul>
    {/if}
  {:else if tab === 'orgs'}
    {#if orgs.length === 0}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('intel.org.empty')}</p>
    {:else}
      <ul class="flex flex-col">
        {#each orgs as org (org.id)}
          <li class="border-b border-[var(--color-border)] py-2 last:border-b-0">
            <div class="flex items-baseline justify-between gap-3">
              <span class="text-sm">{org.name}</span>
              <span class="text-xs text-[var(--color-ink-muted)]">
                {t(`intel.orgStatus.${org.status}`)}
              </span>
            </div>

            <div class="mt-0.5 flex flex-wrap gap-3 text-xs text-[var(--color-ink-muted)]">
              {#if org.type}
                <span>{t(`intel.orgType.${org.type}`)}</span>
              {/if}
              {#if org.territory}
                <span>{org.territory}</span>
              {/if}
              <span>{t('intel.org.members', { count: org.memberCount ?? 0 })}</span>
            </div>
          </li>
        {/each}
      </ul>
    {/if}
  {:else if cases.length === 0}
    <p class="text-sm text-[var(--color-ink-muted)]">{t('intel.case.empty')}</p>
  {:else}
    <ul class="flex flex-col">
      {#each cases as record (record.id)}
        <li class="border-b border-[var(--color-border)] py-2 last:border-b-0">
          <div class="flex items-baseline justify-between gap-3">
            <span class="text-sm">{record.title}</span>
            <span class="text-xs text-[var(--color-ink-muted)]">
              {t(`intel.caseStatus.${record.status}`)}
            </span>
          </div>

          {#if record.description}
            <p class="mt-0.5 text-xs text-[var(--color-ink-muted)]">{record.description}</p>
          {/if}

          <p class="mt-1 text-xs text-[var(--color-ink-muted)]">
            {t('intel.case.linked', {
              people: record.personCount ?? 0,
              orgs: record.orgCount ?? 0,
            })}
          </p>
        </li>
      {/each}
    </ul>
  {/if}
</section>
