<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import type { ErrorCode } from '@fredpd/schema';
  import type { RoleMapView } from '../../lib/types';

  /**
   * Discord role mapping (spec 4.3, 7.30).
   *
   * This is where permissions become configurable in game. Invariant 2 is
   * untouched: Discord roles remain the only source of access. What is editable
   * here is the mapping from a role to a permission group.
   */

  interface Props {
    agencyId: string;
  }

  const { agencyId }: Props = $props();

  let view = $state<RoleMapView | null>(null);
  let error = $state<ErrorCode | null>(null);
  let loading = $state(true);
  let busy = $state(false);

  let roleId = $state('');
  let roleName = $state('');
  let groupKey = $state('');

  async function load(): Promise<void> {
    const response = await nui.call<RoleMapView>('admin.rolemap.list', { agencyId });

    if (response.ok) {
      view = response.data;
      error = null;
      groupKey ||= response.data.groups[0]?.key ?? '';
    } else {
      error = response.err;
    }

    loading = false;
  }

  $effect(() => {
    void load();
  });

  async function add(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy) return;

    busy = true;

    const response = await nui.call('admin.rolemap.create', {
      discordRoleId: roleId.trim(),
      discordRoleName: roleName.trim() || undefined,
      groupKey,
      agencyId,
    });

    if (response.ok) {
      roleId = '';
      roleName = '';
      await load();
    } else {
      error = response.err;
    }

    busy = false;
  }

  async function remove(id: number): Promise<void> {
    if (busy) return;
    busy = true;

    const response = await nui.call('admin.rolemap.delete', { id });

    if (response.ok) {
      await load();
    } else {
      error = response.err;
    }

    busy = false;
  }
</script>

<section class="flex min-h-0 flex-col gap-4">
  <header>
    <h1 class="text-base font-semibold">{t('admin.roleMap.title')}</h1>
    <p class="mt-1 max-w-prose text-xs text-[var(--color-ink-muted)]">
      {t('admin.roleMap.intro')}
    </p>
  </header>

  {#if view}
    <!-- How current the underlying Discord data is. A mapping edited against a
         stale snapshot is still correct, but what it grants today may not be. -->
    <p class="text-xs text-[var(--color-ink-muted)]">
      {#if view.snapshotAgeSeconds === null}
        {t('admin.roleMap.snapshotMissing')}
      {:else}
        {t('admin.roleMap.snapshotAge', { seconds: view.snapshotAgeSeconds })}
      {/if}
    </p>
  {/if}

  {#if error}
    <p class="border border-[var(--color-border)] px-3 py-2 text-sm">{t(`error.${error}`)}</p>
  {/if}

  {#if loading}
    <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
  {:else if view}
    <div class="overflow-x-auto border border-[var(--color-border)]">
      <table class="w-full border-collapse text-xs">
        <thead>
          <tr class="border-b border-[var(--color-border)] text-left">
            <th class="px-3 py-2 font-semibold">{t('admin.roleMap.roleName')}</th>
            <th class="px-3 py-2 font-semibold">{t('admin.roleMap.roleId')}</th>
            <th class="px-3 py-2 font-semibold">{t('admin.roleMap.group')}</th>
            <th class="px-3 py-2"></th>
          </tr>
        </thead>
        <tbody>
          {#each view.mappings as mapping (mapping.id)}
            <tr class="border-b border-[var(--color-border)] last:border-b-0">
              <td class="px-3 py-2">{mapping.discordRoleName ?? '—'}</td>
              <td class="px-3 py-2 font-[family-name:var(--font-mono)]">{mapping.discordRoleId}</td>
              <td class="px-3 py-2">{mapping.groupName}</td>
              <td class="px-3 py-2 text-right">
                <button
                  type="button"
                  class="border border-[var(--color-border)] px-2 py-1 hover:bg-[var(--color-surface)]"
                  disabled={busy}
                  onclick={() => remove(mapping.id)}
                >
                  {t('admin.roleMap.remove')}
                </button>
              </td>
            </tr>
          {:else}
            <tr>
              <td class="px-3 py-3 text-[var(--color-ink-muted)]" colspan="4">
                {t('admin.roleMap.empty')}
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>

    <form class="flex flex-wrap items-end gap-3" onsubmit={add}>
      <label class="flex flex-col gap-1 text-xs">
        <span>{t('admin.roleMap.roleId')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={roleId}
          inputmode="numeric"
          required
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('admin.roleMap.roleName')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={roleName}
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('admin.roleMap.group')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={groupKey}
        >
          {#each view.groups as group (group.key)}
            <option value={group.key}>{group.name}</option>
          {/each}
        </select>
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
        disabled={busy}
      >
        {t('admin.roleMap.add')}
      </button>
    </form>
  {/if}
</section>
