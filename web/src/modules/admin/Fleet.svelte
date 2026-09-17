<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { fieldList, type Failure } from '../shared/failure';
  import type { FleetEntry } from './types';

  /**
   * The motor pool fleet editor (spec 7.31, migration 0003).
   *
   * What a department keeps asking for is "the air unit is the people with the
   * Air Support role", so a vehicle carries two gates: a permission group and a
   * Discord role. Either one opens it, and a vehicle with neither is drawable by
   * anyone who may draw at all. The rule is evaluated on the server when the
   * vehicle is drawn; this screen only configures it (invariant 4).
   *
   * The name shown to officers is a locale key, not a written-out vehicle name:
   * the motor pool menu is translated like everything else (invariant 6), so the
   * editor stores the key and renders it through the same table.
   */

  const FIELD_LABELS: Record<string, string> = {
    model: 'admin.fleet.model',
    labelKey: 'admin.fleet.labelKey',
    permission: 'admin.fleet.permission',
    certification: 'admin.fleet.certification',
    requiredGroup: 'admin.fleet.requiredGroup',
    requiredDiscordRole: 'admin.fleet.requiredDiscordRole',
    livery: 'admin.fleet.livery',
    sortOrder: 'admin.fleet.sortOrder',
    _input: 'admin.fleet.title',
  };

  /**
   * What the two forms hold.
   *
   * The number boxes are `number | null` because that is what `bind:value` on
   * `<input type="number">` produces: a cleared box is null, not zero and not
   * an empty string. Both are turned into something the route accepts in
   * `body()` below — null must never reach the wire, where it is neither a
   * value nor an absent field.
   */
  interface Entry {
    model: string;
    labelKey: string;
    permission: string;
    certification: string;
    requiredGroup: string;
    requiredDiscordRole: string;
    /** The livery index, or null for "no livery". */
    livery: number | null;
    sortOrder: number | null;
    enabled: boolean;
  }

  const EMPTY: Entry = {
    model: '',
    labelKey: '',
    permission: '',
    certification: '',
    requiredGroup: '',
    requiredDiscordRole: '',
    livery: null,
    sortOrder: 0,
    enabled: true,
  };

  let fleet = $state<FleetEntry[]>([]);
  let groups = $state<string[]>([]);

  let selectedId = $state<number | null>(null);
  let draft = $state({ ...EMPTY });
  let addition = $state({ ...EMPTY });

  let confirmRemove = $state<number | null>(null);
  let failure = $state<Failure | null>(null);
  let loading = $state(true);
  let busy = $state(false);

  async function load(): Promise<void> {
    const response = await nui.call<{ fleet: FleetEntry[]; groups: string[] }>(
      'garage.fleet.manage',
    );

    if (response.ok) {
      fleet = response.data.fleet;
      groups = response.data.groups;
      failure = null;
    } else {
      failure = response;
    }

    loading = false;
  }

  $effect(() => {
    void load();
  });

  function select(entry: FleetEntry): void {
    selectedId = entry.id;
    confirmRemove = null;
    draft = {
      model: entry.model,
      labelKey: entry.labelKey,
      // An empty box is how a gate is cleared, so null arrives as '' and goes
      // back as '' — the server tells the two apart from an absent field.
      permission: entry.permission ?? '',
      certification: entry.certification ?? '',
      requiredGroup: entry.requiredGroup ?? '',
      requiredDiscordRole: entry.requiredDiscordRole ?? '',
      livery: entry.livery,
      sortOrder: entry.sortOrder,
      enabled: entry.enabled,
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

  /**
   * The shape both writes send.
   *
   * Every field is present on every write, because the server tells an empty
   * field from an absent one: an empty string clears a gate, while a key that
   * is not there leaves the column alone. That is why the two blanks are sent
   * as values rather than dropped:
   *
   * - `livery` blank means "no livery", and travels as the sentinel `-1` the
   *   schema declares and `Repo.updateFleet` writes as `NULLIF(?, -1)`. Sending
   *   nothing instead left the old livery on the vehicle, so a livery could be
   *   set from this screen but never cleared.
   * - `sortOrder` blank would travel as JSON null, which is neither a number
   *   the validator accepts nor an absent key, and on an add it silently became
   *   the column default. The box is `required`, and this is the floor under it.
   */
  function body(entry: Entry): Record<string, unknown> {
    return {
      model: entry.model.trim(),
      labelKey: entry.labelKey.trim(),
      permission: entry.permission.trim(),
      certification: entry.certification.trim(),
      requiredGroup: entry.requiredGroup,
      requiredDiscordRole: entry.requiredDiscordRole.trim(),
      livery: entry.livery ?? -1,
      sortOrder: entry.sortOrder ?? 0,
      enabled: entry.enabled,
    };
  }

  async function save(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (selectedId === null) return;

    await submit('garage.fleet.update', { id: selectedId, ...body(draft) });
  }

  async function add(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    const done = await submit('garage.fleet.add', body(addition));
    if (done) addition = { ...EMPTY };
  }

  async function remove(id: number): Promise<void> {
    confirmRemove = null;

    const done = await submit('garage.fleet.remove', { id });
    if (done && selectedId === id) selectedId = null;
  }

  const messages = $derived(fieldList(failure, FIELD_LABELS));
</script>

<section class="flex min-h-0 flex-col gap-4">
  <header>
    <h1 class="text-base font-semibold">{t('admin.fleet.title')}</h1>
    <p class="mt-1 max-w-prose text-xs text-[var(--color-ink-muted)]">{t('admin.fleet.intro')}</p>
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
            <th class="px-3 py-2 font-semibold">{t('admin.fleet.model')}</th>
            <th class="px-3 py-2 font-semibold">{t('admin.fleet.vehicle')}</th>
            <th class="px-3 py-2 font-semibold">{t('admin.fleet.permission')}</th>
            <th class="px-3 py-2 font-semibold">{t('admin.fleet.certification')}</th>
            <th class="px-3 py-2 font-semibold">{t('admin.fleet.requiredGroup')}</th>
            <th class="px-3 py-2 font-semibold">{t('admin.fleet.requiredDiscordRole')}</th>
            <th class="px-3 py-2 font-semibold">{t('admin.fleet.livery')}</th>
            <th class="px-3 py-2 font-semibold">{t('admin.fleet.sortOrder')}</th>
            <th class="px-3 py-2 font-semibold">{t('admin.fleet.enabled')}</th>
            <th class="px-3 py-2"></th>
          </tr>
        </thead>
        <tbody>
          {#each fleet as entry (entry.id)}
            <tr class="border-b border-[var(--color-border)] last:border-b-0">
              <td class="px-3 py-2">
                <button
                  type="button"
                  class="font-[family-name:var(--font-mono)] underline-offset-2 hover:underline"
                  class:font-semibold={selectedId === entry.id}
                  onclick={() => select(entry)}
                >
                  {entry.model}
                </button>
              </td>
              <td class="px-3 py-2">{t(entry.labelKey)}</td>
              <td class="px-3 py-2 font-[family-name:var(--font-mono)]">{entry.permission ?? ''}</td>
              <td class="px-3 py-2 font-[family-name:var(--font-mono)]">
                {entry.certification ?? ''}
              </td>
              <td class="px-3 py-2 font-[family-name:var(--font-mono)]">
                {entry.requiredGroup ?? ''}
              </td>
              <td class="px-3 py-2 font-[family-name:var(--font-mono)]">
                {entry.requiredDiscordRole ?? ''}
              </td>
              <td class="px-3 py-2 font-[family-name:var(--font-mono)]">{entry.livery ?? ''}</td>
              <td class="px-3 py-2 font-[family-name:var(--font-mono)]">{entry.sortOrder}</td>
              <td class="px-3 py-2">
                {entry.enabled ? t('admin.fleet.on') : t('admin.fleet.off')}
              </td>
              <td class="px-3 py-2 text-right">
                {#if confirmRemove === entry.id}
                  <span class="mr-2 text-[var(--color-ink-muted)]">
                    {t('admin.fleet.removeConfirm')}
                  </span>
                  <button
                    type="button"
                    class="border border-[var(--color-border)] px-2 py-1 hover:bg-[var(--color-surface)]"
                    disabled={busy}
                    onclick={() => remove(entry.id)}
                  >
                    {t('admin.fleet.remove')}
                  </button>
                  <button
                    type="button"
                    class="ml-1 border border-[var(--color-border)] px-2 py-1 hover:bg-[var(--color-surface)]"
                    onclick={() => (confirmRemove = null)}
                  >
                    {t('form.cancel')}
                  </button>
                {:else}
                  <button
                    type="button"
                    class="border border-[var(--color-border)] px-2 py-1 hover:bg-[var(--color-surface)]"
                    onclick={() => (confirmRemove = entry.id)}
                  >
                    {t('admin.fleet.remove')}
                  </button>
                {/if}
              </td>
            </tr>
          {:else}
            <tr>
              <td class="px-3 py-3 text-[var(--color-ink-muted)]" colspan="10">
                {t('admin.fleet.empty')}
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>

    <p class="max-w-prose text-xs text-[var(--color-ink-muted)]">{t('admin.fleet.gating')}</p>

    {#if selectedId !== null}
      <form class="flex flex-wrap items-end gap-3 border border-[var(--color-border)] p-3" onsubmit={save}>
        <p class="w-full text-xs font-semibold">{t('admin.fleet.edit')}</p>

        <label class="flex flex-col gap-1 text-xs">
          <span>{t('admin.fleet.model')}</span>
          <input
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
            bind:value={draft.model}
          />
        </label>

        <label class="flex flex-col gap-1 text-xs">
          <span>{t('admin.fleet.labelKey')}</span>
          <input
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
            bind:value={draft.labelKey}
          />
        </label>

        <label class="flex flex-col gap-1 text-xs">
          <span>{t('admin.fleet.permission')}</span>
          <input
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
            bind:value={draft.permission}
          />
        </label>

        <label class="flex flex-col gap-1 text-xs">
          <span>{t('admin.fleet.certification')}</span>
          <input
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
            bind:value={draft.certification}
          />
        </label>

        <label class="flex flex-col gap-1 text-xs">
          <span>{t('admin.fleet.requiredGroup')}</span>
          <select
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={draft.requiredGroup}
          >
            <option value="">{t('admin.fleet.noGate')}</option>
            {#each groups as key (key)}
              <option value={key}>{key}</option>
            {/each}
          </select>
        </label>

        <label class="flex flex-col gap-1 text-xs">
          <span>{t('admin.fleet.requiredDiscordRole')}</span>
          <input
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
            bind:value={draft.requiredDiscordRole}
            inputmode="numeric"
          />
        </label>

        <label class="flex flex-col gap-1 text-xs">
          <span>{t('admin.fleet.livery')}</span>
          <!-- Empty is how a livery is cleared; `body()` sends that as -1. -->
          <input
            class="w-20 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
            type="number"
            min="0"
            max="63"
            step="1"
            bind:value={draft.livery}
          />
        </label>

        <label class="flex flex-col gap-1 text-xs">
          <span>{t('admin.fleet.sortOrder')}</span>
          <input
            class="w-20 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
            type="number"
            min="0"
            max="9999"
            step="1"
            required
            bind:value={draft.sortOrder}
          />
        </label>

        <label class="flex items-center gap-1.5 text-xs">
          <input type="checkbox" bind:checked={draft.enabled} />
          <span>{t('admin.fleet.enabled')}</span>
        </label>

        <button
          type="submit"
          class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
          disabled={busy}
        >
          {t('admin.fleet.save')}
        </button>
      </form>
    {/if}

    <form class="flex flex-wrap items-end gap-3" onsubmit={add}>
      <p class="w-full text-xs font-semibold">{t('admin.fleet.new')}</p>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('admin.fleet.model')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={addition.model}
          placeholder={t('admin.fleet.modelPlaceholder')}
          required
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('admin.fleet.labelKey')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={addition.labelKey}
          placeholder={t('admin.fleet.labelKeyPlaceholder')}
          required
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('admin.fleet.requiredGroup')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={addition.requiredGroup}
        >
          <option value="">{t('admin.fleet.noGate')}</option>
          {#each groups as key (key)}
            <option value={key}>{key}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('admin.fleet.requiredDiscordRole')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={addition.requiredDiscordRole}
          inputmode="numeric"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('admin.fleet.sortOrder')}</span>
        <input
          class="w-20 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          type="number"
          min="0"
          max="9999"
          step="1"
          required
          bind:value={addition.sortOrder}
        />
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
        disabled={busy}
      >
        {t('admin.fleet.add')}
      </button>
    </form>
  {/if}
</section>
