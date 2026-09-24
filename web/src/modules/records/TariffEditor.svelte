<script lang="ts">
  import { tick } from 'svelte';
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import { tariffName, type Tariff } from './tariff';

  /**
   * The ordningsbot tariff, as the agency's command edits it (spec 7.11,
   * 0036). Every save is a new version of the line: citations already issued
   * keep the amount and points they were written under.
   *
   * Drawn only when the server said this session may edit; the two routes
   * check the permission again for themselves.
   */

  interface Props {
    tariffs: Tariff[];
    /** Whether licence points are switched on (config), so the column means something. */
    licence: boolean;
    onChanged: () => Promise<void>;
  }

  let { tariffs, licence, onChanged }: Props = $props();

  const FIELD_LABELS: Record<string, string> = {
    code: 'ordningsbot.tariffEditor.code',
    label: 'ordningsbot.tariffEditor.label',
    amount: 'ordningsbot.tariffEditor.amount',
    licencePoints: 'ordningsbot.tariffEditor.points',
  };

  const blank = () => ({ code: '', label: '', amount: '', licencePoints: '0' });

  let form = $state(blank());
  /** The code being edited, or null for a new line. */
  let editing = $state<string | null>(null);
  let failure = $state<Failure | null>(null);
  let status = $state('');
  let busy = $state(false);
  let retiring = $state<Tariff | null>(null);
  let formTop = $state<HTMLElement | null>(null);
  let heading = $state<HTMLElement | null>(null);
  let table = $state<HTMLElement | null>(null);
  /** The Retire button that opened the confirmation, to give focus back to. */
  let retireTrigger: HTMLButtonElement | null = null;

  const FOCUS = 'focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]';
  const editingName = $derived(editing ? tariffs.find((entry) => entry.code === editing) : undefined);

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  async function edit(tariff: Tariff): Promise<void> {
    editing = tariff.code;
    form = {
      code: tariff.code,
      label: '',
      amount: String(tariff.amount),
      licencePoints: String(tariff.licencePoints ?? 0),
    };
    failure = null;
    status = '';
    await tick();
    formTop?.querySelector<HTMLInputElement>('input:not([readonly])')?.focus();
  }

  function startNew(): void {
    editing = null;
    form = blank();
    failure = null;
    status = '';
  }

  /** Cancel an edit: focus goes back to the row's own Edit button. */
  async function cancelEdit(): Promise<void> {
    const code = editing;
    startNew();
    await tick();
    table?.querySelector<HTMLButtonElement>(`button[data-edit="${code}"]`)?.focus();
  }

  function cancelRetire(): void {
    retiring = null;
    failure = null;
    retireTrigger?.focus();
  }

  async function save(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy) return;
    busy = true;

    const code = form.code.trim();
    const response = await nui.call('ordningsbot.tariff.set', {
      code,
      label: form.label.trim() || undefined,
      amount: Number.parseInt(form.amount, 10),
      licencePoints: Number.parseInt(form.licencePoints, 10) || 0,
    });

    if (response.ok) {
      startNew();
      status = t('ordningsbot.tariffEditor.saved', { code });
      await onChanged();
    } else {
      failure = response;
    }

    busy = false;
  }

  async function retire(): Promise<void> {
    if (!retiring || busy) return;
    busy = true;

    const code = retiring.code;
    const response = await nui.call('ordningsbot.tariff.retire', { code });

    if (response.ok) {
      failure = null;
      retiring = null;
      if (editing === code) startNew();
      status = t('ordningsbot.tariffEditor.retired', { code });
      await onChanged();
      // The row and its button are gone: the heading takes focus.
      await tick();
      heading?.focus();
    } else {
      failure = response;
    }

    busy = false;
  }
</script>

<section id="tariff-editor" class="flex flex-col gap-2 border border-[var(--color-border)] p-3" aria-labelledby="tariff-editor-heading">
  <h2 id="tariff-editor-heading" class="text-[15px] font-semibold" tabindex="-1" bind:this={heading}>
    {t('ordningsbot.tariffEditor.title')}
  </h2>
  <p class="text-xs text-[var(--color-ink-muted)]">{t('ordningsbot.tariffEditor.hint')}</p>

  {#if failure && !retiring}
    <div class="border border-[var(--color-alert)] px-3 py-2 text-sm" role="alert">
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
  {#if status}
    <p class="text-xs text-[var(--color-ink-muted)]" role="status">{status}</p>
  {/if}

  <table class="w-full text-[12.5px] tabular-nums" bind:this={table}>
    <thead class="bg-[var(--color-surface)]">
      <tr>
        <th class="px-2 py-1 text-left font-semibold">{t('ordningsbot.tariffEditor.code')}</th>
        <th class="px-2 py-1 text-left font-semibold">{t('ordningsbot.tariffEditor.label')}</th>
        <th class="px-2 py-1 text-right font-semibold">{t('ordningsbot.tariffEditor.amount')}</th>
        {#if licence}
          <th class="px-2 py-1 text-right font-semibold">{t('ordningsbot.tariffEditor.points')}</th>
        {/if}
        <th class="px-2 py-1"><span class="sr-only">{t('ordningsbot.tariffEditor.actions')}</span></th>
      </tr>
    </thead>
    <tbody>
      {#each tariffs as tariff (tariff.id)}
        <tr
          class="border-t border-l-2 border-t-[var(--color-border)]"
          class:border-l-[var(--color-focus)]={editing === tariff.code}
          class:border-l-transparent={editing !== tariff.code}
        >
          <td class="px-2 py-1 font-[family-name:var(--font-mono)]">{tariff.code}</td>
          <td class="px-2 py-1">{tariffName(tariff)}</td>
          <td class="px-2 py-1 text-right">{tariff.amount}</td>
          {#if licence}
            <td class="px-2 py-1 text-right">{tariff.licencePoints ?? 0}</td>
          {/if}
          <td class="px-2 py-1 text-right whitespace-nowrap">
            <button
              type="button"
              class="border border-[var(--color-border)] px-2 py-0.5 {FOCUS}"
              data-edit={tariff.code}
              aria-label={t('ordningsbot.tariffEditor.editLine', { name: tariffName(tariff) })}
              onclick={() => void edit(tariff)}
            >
              {t('ordningsbot.tariffEditor.edit')}
            </button>
            <button
              type="button"
              class="ml-1 border border-[var(--color-border)] px-2 py-0.5 {FOCUS}"
              aria-label={t('ordningsbot.tariffEditor.retireLine', { name: tariffName(tariff) })}
              onclick={(event) => {
                retireTrigger = event.currentTarget;
                retiring = tariff;
                failure = null;
              }}
            >
              {t('ordningsbot.tariffEditor.retire')}
            </button>
          </td>
        </tr>
      {/each}
    </tbody>
  </table>

  {#if retiring}
    <ConfirmDialog
      label={t('ordningsbot.tariffEditor.retire')}
      question={t('ordningsbot.tariffEditor.confirmRetire', { name: tariffName(retiring) })}
      {busy}
      {failure}
      fieldLabels={FIELD_LABELS}
      confirm={() => void retire()}
      cancel={cancelRetire}
    />
  {/if}

  <!-- novalidate: the server's refusal is drawn above, translated; the
       browser's own bubble is in the browser's language and names no rule. -->
  <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
  <form
    class="flex flex-wrap items-end gap-2 border-t border-[var(--color-border)] pt-3"
    onsubmit={save}
    bind:this={formTop}
    novalidate
    onkeydown={(event) => {
      // Escape leaves the edit, not the MDT (`main.ts` closes the NUI on an
      // Escape that reaches `window`).
      if (event.key !== 'Escape' || !editing) return;
      event.stopPropagation();
      event.preventDefault();
      void cancelEdit();
    }}
  >
    <p class="w-full text-xs font-semibold">
      {editing ? t('ordningsbot.tariffEditor.editing', { code: editing }) : t('ordningsbot.tariffEditor.new')}
    </p>
    <label class="flex flex-col gap-1 text-xs">
      <span>{t('ordningsbot.tariffEditor.code')} <span aria-hidden="true">*</span></span>
      <input
        bind:value={form.code}
        required
        readonly={editing !== null}
        maxlength="32"
        aria-describedby="tariff-code-hint"
        onblur={() => (form.code = form.code.trim().toLowerCase())}
        class="w-40 border border-[var(--color-border)] px-2 py-1 font-[family-name:var(--font-mono)] {FOCUS}"
      />
      <span id="tariff-code-hint" class="text-[var(--color-ink-muted)]">{t('ordningsbot.tariffEditor.codeHint')}</span>
    </label>
    <label class="flex flex-col gap-1 text-xs">
      <span>
        {t('ordningsbot.tariffEditor.label')}
        {#if !editing}<span aria-hidden="true">*</span>{/if}
      </span>
      <input
        bind:value={form.label}
        required={editing === null}
        maxlength="120"
        aria-describedby={editingName ? 'tariff-name-hint' : undefined}
        class="w-64 border border-[var(--color-border)] px-2 py-1 {FOCUS}"
      />
      {#if editingName}
        <span id="tariff-name-hint" class="text-[var(--color-ink-muted)]">
          {t('ordningsbot.tariffEditor.keepName', { name: tariffName(editingName) })}
        </span>
      {/if}
    </label>
    <label class="flex flex-col gap-1 text-xs">
      <span>{t('ordningsbot.tariffEditor.amount')} <span aria-hidden="true">*</span></span>
      <input type="number" bind:value={form.amount} required min="0" max="1000000" class="w-28 border border-[var(--color-border)] px-2 py-1 {FOCUS}" />
    </label>
    {#if licence}
      <label class="flex flex-col gap-1 text-xs">
        {t('ordningsbot.tariffEditor.points')}
        <input type="number" bind:value={form.licencePoints} min="0" max="20" class="w-20 border border-[var(--color-border)] px-2 py-1 {FOCUS}" />
      </label>
    {/if}
    <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs {FOCUS}">
      {t('ordningsbot.tariffEditor.save')}
    </button>
    {#if editing}
      <button type="button" class="border border-[var(--color-border)] px-3 py-1 text-xs {FOCUS}" onclick={() => void cancelEdit()}>
        {t('ordningsbot.tariffEditor.cancelEdit')}
      </button>
    {/if}
  </form>
</section>
