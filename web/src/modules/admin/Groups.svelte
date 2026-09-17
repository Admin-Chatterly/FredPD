<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { fieldList, type Failure } from '../shared/failure';
  import type { GroupRow, PermissionRow } from './types';

  /**
   * The permission group editor (spec 4.3, 7.30).
   *
   * A group is a bundle of permission keys, and a Discord role grants a group
   * (invariant 2). This screen edits the bundles; `RoleMap` maps the roles onto
   * them. Together they are the whole permission model, which is why both
   * routes behind this page are marked sensitive on the server and refuse to
   * answer from a stale Discord snapshot.
   *
   * Two flags arrive with the data and are drawn exactly as they came:
   * `editable` says whether this session holds everything the group grants, and
   * `grantable` says whether it could hand out a given key at all. Neither is
   * computed here — an administrator cannot grant what they do not hold, and
   * the server refuses the write whatever this screen shows (invariant 4).
   */

  const FIELD_LABELS: Record<string, string> = {
    key: 'admin.groups.key',
    name: 'admin.groups.name',
    inherits: 'admin.groups.inherits',
    description: 'admin.groups.description',
    permissions: 'admin.groups.permissions',
    _input: 'admin.groups.title',
  };

  let groups = $state<GroupRow[]>([]);
  let permissions = $state<PermissionRow[]>([]);

  let selectedKey = $state<string | null>(null);
  let draft = $state({ name: '', inherits: '', description: '', permissions: [] as string[] });

  let newKey = $state('');
  let newName = $state('');
  let newInherits = $state('');
  let newDescription = $state('');

  let confirmDelete = $state<string | null>(null);
  let failure = $state<Failure | null>(null);
  let loading = $state(true);
  let busy = $state(false);

  async function load(): Promise<void> {
    const [groupResponse, permissionResponse] = await Promise.all([
      nui.call<{ groups: GroupRow[] }>('admin.group.list'),
      nui.call<{ permissions: PermissionRow[] }>('admin.permission.list'),
    ]);

    if (groupResponse.ok) {
      groups = groupResponse.data.groups;
      failure = null;
    } else {
      failure = groupResponse;
    }

    if (permissionResponse.ok) permissions = permissionResponse.data.permissions;

    loading = false;
  }

  $effect(() => {
    void load();
  });

  /**
   * Copies the group into the draft. Editing a copy rather than the row means a
   * reload after a refused save puts the real group back, instead of leaving
   * the screen showing an edit the server never accepted.
   */
  function select(group: GroupRow): void {
    selectedKey = group.key;
    confirmDelete = null;
    draft = {
      name: group.name,
      inherits: group.inherits ?? '',
      description: group.description ?? '',
      permissions: [...group.permissions],
    };
  }

  async function submit(route: string, input: Record<string, unknown>): Promise<boolean> {
    if (busy) return false;
    busy = true;

    const response = await nui.call(route, input);

    if (response.ok) {
      failure = null;
      await load();
    } else {
      failure = response;
    }

    busy = false;
    return response.ok;
  }

  async function save(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!selected) return;

    await submit('admin.group.update', {
      key: selected.key,
      name: draft.name,
      // An empty string clears the inheritance; the server reads it that way.
      inherits: draft.inherits,
      description: draft.description,
      permissions: draft.permissions,
    });
  }

  async function create(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    const done = await submit('admin.group.create', {
      key: newKey.trim(),
      name: newName.trim(),
      inherits: newInherits || undefined,
      description: newDescription.trim() || undefined,
      // A new group starts empty and is filled in from the editor, so one
      // screen is responsible for what a bundle grants.
      permissions: [],
    });

    if (done) {
      newKey = '';
      newName = '';
      newDescription = '';
    }
  }

  async function remove(key: string): Promise<void> {
    confirmDelete = null;

    const done = await submit('admin.group.delete', { key });
    if (done && selectedKey === key) selectedKey = null;
  }

  function toggle(key: string): void {
    draft.permissions = draft.permissions.includes(key)
      ? draft.permissions.filter((candidate) => candidate !== key)
      : [...draft.permissions, key];
  }

  const selected = $derived(groups.find((group) => group.key === selectedKey) ?? null);
  const messages = $derived(fieldList(failure, FIELD_LABELS));

  /**
   * The catalogue sectioned by the first segment of each key. A plain object
   * rather than a Map: this grouping is rebuilt from `permissions` every time
   * and never escapes the derivation, so there is nothing here for a reactive
   * collection to observe.
   */
  const areas = $derived.by(() => {
    const byArea: Record<string, PermissionRow[]> = {};

    for (const row of permissions) {
      (byArea[row.area] ??= []).push(row);
    }

    return Object.entries(byArea).map(([area, rows]) => ({ area, rows }));
  });
</script>

<section class="flex min-h-0 flex-col gap-4">
  <header>
    <h1 class="text-base font-semibold">{t('admin.groups.title')}</h1>
    <p class="mt-1 max-w-prose text-xs text-[var(--color-ink-muted)]">{t('admin.groups.intro')}</p>
  </header>

  {#if failure}
    <div class="border border-[var(--color-border)] px-3 py-2 text-sm">
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

  {#if loading}
    <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
  {:else}
    <div class="overflow-x-auto border border-[var(--color-border)]">
      <table class="w-full border-collapse text-xs">
        <thead>
          <tr class="border-b border-[var(--color-border)] text-left">
            <th class="px-3 py-2 font-semibold">{t('admin.groups.key')}</th>
            <th class="px-3 py-2 font-semibold">{t('admin.groups.name')}</th>
            <th class="px-3 py-2 font-semibold">{t('admin.groups.inherits')}</th>
            <th class="px-3 py-2 font-semibold">{t('admin.groups.column.own')}</th>
            <th class="px-3 py-2 font-semibold">{t('admin.groups.column.effective')}</th>
            <th class="px-3 py-2 font-semibold">{t('admin.groups.column.roles')}</th>
            <th class="px-3 py-2"></th>
          </tr>
        </thead>
        <tbody>
          {#each groups as group (group.key)}
            <tr class="border-b border-[var(--color-border)] last:border-b-0">
              <td class="px-3 py-2">
                <button
                  type="button"
                  class="font-[family-name:var(--font-mono)] underline-offset-2 hover:underline"
                  class:font-semibold={selectedKey === group.key}
                  onclick={() => select(group)}
                >
                  {group.key}
                </button>
              </td>
              <td class="px-3 py-2">{group.name}</td>
              <td class="px-3 py-2 font-[family-name:var(--font-mono)]">{group.inherits ?? ''}</td>
              <td class="px-3 py-2">{group.permissions.length}</td>
              <td class="px-3 py-2">{group.effective.length}</td>
              <td class="px-3 py-2">{group.roleMapCount}</td>
              <td class="px-3 py-2 text-right">
                {#if group.locked}
                  <span class="text-[var(--color-ink-muted)]">{t('admin.groups.locked')}</span>
                {:else if confirmDelete === group.key}
                  <span class="mr-2 text-[var(--color-ink-muted)]">
                    {t('admin.groups.deleteConfirm')}
                  </span>
                  <button
                    type="button"
                    class="border border-[var(--color-border)] px-2 py-1 hover:bg-[var(--color-surface)]"
                    disabled={busy}
                    onclick={() => remove(group.key)}
                  >
                    {t('admin.groups.delete')}
                  </button>
                  <button
                    type="button"
                    class="ml-1 border border-[var(--color-border)] px-2 py-1 hover:bg-[var(--color-surface)]"
                    onclick={() => (confirmDelete = null)}
                  >
                    {t('form.cancel')}
                  </button>
                {:else}
                  <button
                    type="button"
                    class="border border-[var(--color-border)] px-2 py-1 hover:bg-[var(--color-surface)]"
                    onclick={() => (confirmDelete = group.key)}
                  >
                    {t('admin.groups.delete')}
                  </button>
                {/if}
              </td>
            </tr>
          {:else}
            <tr>
              <td class="px-3 py-3 text-[var(--color-ink-muted)]" colspan="7">
                {t('admin.groups.empty')}
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>

    {#if selected}
      <form class="flex flex-col gap-3 border border-[var(--color-border)] p-3" onsubmit={save}>
        <header class="flex flex-wrap items-baseline justify-between gap-3">
          <h2 class="text-sm font-semibold font-[family-name:var(--font-mono)]">{selected.key}</h2>
          {#if !selected.editable}
            <!-- The session does not itself hold everything this bundle grants,
                 so it may not author it. The server said so; the write would be
                 refused either way. -->
            <span class="text-xs text-[var(--color-ink-muted)]">
              {t('admin.groups.notEditable')}
            </span>
          {/if}
        </header>

        <div class="flex flex-wrap items-end gap-3">
          <label class="flex flex-col gap-1 text-xs">
            <span>{t('admin.groups.name')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={draft.name}
              disabled={!selected.editable || selected.locked}
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('admin.groups.inherits')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={draft.inherits}
              disabled={!selected.editable}
            >
              <option value="">{t('admin.groups.inheritsNone')}</option>
              {#each groups as group (group.key)}
                {#if group.key !== selectedKey}
                  <option value={group.key}>{group.name}</option>
                {/if}
              {/each}
            </select>
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('admin.groups.description')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={draft.description}
              disabled={!selected.editable}
            />
          </label>

          <button
            type="submit"
            class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
            disabled={busy}
          >
            {t('admin.groups.save')}
          </button>
        </div>

        <div>
          <h3 class="text-xs font-semibold">{t('admin.groups.permissions')}</h3>
          <p class="mt-0.5 text-xs text-[var(--color-ink-muted)]">
            {t('admin.groups.permissionsIntro')}
          </p>

          <div class="mt-2 flex flex-col gap-3">
            {#each areas as section (section.area)}
              <div>
                <p class="text-xs font-semibold font-[family-name:var(--font-mono)]">
                  {section.area}
                </p>
                <div class="mt-1 flex flex-wrap gap-x-4 gap-y-1">
                  {#each section.rows as row (row.key)}
                    <label class="flex items-center gap-1.5 text-xs">
                      <input
                        type="checkbox"
                        checked={draft.permissions.includes(row.key)}
                        disabled={!row.grantable || !selected.editable}
                        onchange={() => toggle(row.key)}
                      />
                      <span class="font-[family-name:var(--font-mono)]">{row.key}</span>
                    </label>
                  {/each}
                </div>
              </div>
            {/each}
          </div>
        </div>

        <!-- What the group actually grants once inheritance is expanded. Read
             only: it is derived on the server from the bundles above it. -->
        <div>
          <h3 class="text-xs font-semibold">{t('admin.groups.effective')}</h3>
          <p class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs font-[family-name:var(--font-mono)] text-[var(--color-ink-muted)]">
            {#each selected.effective as key (key)}
              <span>{key}</span>
            {/each}
          </p>
        </div>
      </form>
    {/if}

    <form class="flex flex-wrap items-end gap-3" onsubmit={create}>
      <p class="w-full text-xs font-semibold">{t('admin.groups.new')}</p>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('admin.groups.key')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={newKey}
          placeholder={t('admin.groups.keyPlaceholder')}
          required
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('admin.groups.name')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={newName}
          required
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('admin.groups.inherits')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={newInherits}
        >
          <option value="">{t('admin.groups.inheritsNone')}</option>
          {#each groups as group (group.key)}
            <option value={group.key}>{group.name}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('admin.groups.description')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={newDescription}
        />
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
        disabled={busy}
      >
        {t('admin.groups.create')}
      </button>
    </form>
  {/if}
</section>
