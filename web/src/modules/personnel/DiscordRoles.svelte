<script lang="ts">
  import { tick } from 'svelte';
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';

  /**
   * Discord role actions (ADR-022): hire, promote, demote and dismiss, as a
   * change to a Discord role the gateway makes. FredPD never grants a
   * permission here: the role changes in Discord, and comes back through the
   * read sync like any other change (invariant 2).
   *
   * With an officer, the roles they hold and may be given or lose. Without
   * one, hiring somebody not on the roster yet, by their Discord id.
   *
   * Only what the server says is drawn: whether role actions are on, which
   * roles may be managed, and whether this session may hire or promote. The
   * server re-checks every one of those, and more (ADR-022's guards), on the
   * change itself.
   */

  interface Role {
    id: string;
    kind: 'hire' | 'rank';
    name: string;
    held: boolean;
  }

  interface Answer {
    enabled: boolean;
    roles: Role[];
    self?: boolean;
    may?: { hire: boolean; promote: boolean };
  }

  interface Props {
    /** The officer, or null to hire somebody not on the roster. */
    officerId: number | null;
    /** After a change: the caller re-reads what it shows. */
    onChanged?: () => void;
  }

  let { officerId, onChanged }: Props = $props();

  const FIELD_LABELS: Record<string, string> = {
    roleId: 'personnel.roles.role',
    reason: 'personnel.roles.reason',
    discordId: 'personnel.roles.discordId',
    officerId: 'personnel.roles.officer',
  };

  let answer = $state<Answer | null>(null);
  let busy = $state(false);
  let status = $state('');
  let failure = $state<Failure | null>(null);

  /** The change being confirmed: which role, and which way. */
  let pending = $state<{ role: Role; grant: boolean } | null>(null);
  let reason = $state('');
  let trigger: HTMLButtonElement | null = null;

  // Hiring somebody new.
  let hiring = $state(false);
  let hireToggle = $state<HTMLButtonElement | null>(null);
  let hireForm = $state({ discordId: '', roleId: '' });

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  const hireRoles = $derived((answer?.roles ?? []).filter((role) => role.kind === 'hire'));

  function mayChange(role: Role): boolean {
    if (!answer || answer.self) return false;
    return role.kind === 'hire' ? answer.may?.hire === true : answer.may?.promote === true;
  }

  async function load(): Promise<void> {
    const response = await nui.call<Answer>('personnel.roles.get', officerId ? { id: officerId } : {});
    answer = response.ok ? response.data : null;
    if (answer && hireRoles[0] && !hireForm.roleId) hireForm.roleId = hireRoles[0].id;
  }

  $effect(() => {
    void officerId;
    status = '';
    failure = null;
    pending = null;
    void load();
  });

  function ask(role: Role, grant: boolean, event: MouseEvent): void {
    trigger = event.currentTarget as HTMLButtonElement;
    failure = null;
    reason = '';
    pending = { role, grant };
  }

  // The button that opened the dialog is disabled while it is open, so focus
  // goes back only once it has been re-enabled.
  async function refocus(): Promise<void> {
    await tick();
    trigger?.focus();
  }

  function cancel(): void {
    pending = null;
    failure = null;
    void refocus();
  }

  function verb(role: Role, grant: boolean): string {
    if (role.kind === 'hire') return t(grant ? 'personnel.roles.hire' : 'personnel.roles.dismiss');
    return t(grant ? 'personnel.roles.promote' : 'personnel.roles.demote');
  }

  async function confirm(): Promise<void> {
    if (!pending || busy) return;
    busy = true;

    const { role, grant } = pending;
    const response = await nui.call(role.kind === 'hire' ? 'personnel.roles.hire' : 'personnel.roles.rank', {
      officerId,
      roleId: role.id,
      grant,
      reason: reason.trim(),
    });

    busy = false;

    if (!response.ok) {
      failure = response;
      return;
    }

    pending = null;
    status = t(grant ? 'personnel.roles.granted' : 'personnel.roles.removed', { role: role.name });
    await load();
    // The button that opened it now says the opposite verb, and is still the
    // place to come back to.
    await refocus();
    onChanged?.();
  }

  async function hire(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy) return;
    busy = true;
    failure = null;

    const response = await nui.call('personnel.roles.hire', {
      discordId: hireForm.discordId.trim(),
      roleId: hireForm.roleId,
      grant: true,
      reason: reason.trim(),
    });

    busy = false;

    if (!response.ok) {
      failure = response;
      return;
    }

    const role = hireRoles.find((entry) => entry.id === hireForm.roleId);
    status = t('personnel.roles.hired', { role: role?.name ?? '' });
    hireForm.discordId = '';
    reason = '';
    hiring = false;
    // The form, and the button that was focused in it, are gone.
    await tick();
    hireToggle?.focus();
    onChanged?.();
  }
</script>

{#snippet feedback()}
  {#if failure && !pending}
    <div class="mt-2 border border-[var(--color-alert)] px-2 py-1 text-xs" role="alert">
      <p>{t(`error.${failure.err}`)}</p>
      {#each messages as message (message.name)}
        <p class="text-[var(--color-ink-muted)]">{message.label} — {message.reason}</p>
      {/each}
    </div>
  {/if}
  {#if status}
    <p class="mt-1 text-xs text-[var(--color-ink-muted)]" role="status">{status}</p>
  {/if}
{/snippet}

{#if answer?.enabled}
  {#if officerId !== null}
    <section class="mb-4" aria-labelledby="discord-roles-title">
      <h3 id="discord-roles-title" class="mb-1 text-xs font-semibold">{t('personnel.roles.title')}</h3>
      {#if answer.self}
        <p class="mb-2 text-xs text-[var(--color-ink-muted)]">{t('personnel.roles.notOwn')}</p>
      {/if}
      {#if answer.roles.length === 0}
        <p class="text-xs text-[var(--color-ink-muted)]">{t('personnel.roles.none')}</p>
      {:else}
        <ul class="text-xs">
          {#each answer.roles as role (role.id)}
            <li class="flex items-center justify-between gap-2 border-t border-[var(--color-border)] py-1">
              <span>
                {role.name}
                <span class="text-[var(--color-ink-muted)]">
                  — {t(`personnel.roles.kind.${role.kind}`)} · {t(role.held ? 'personnel.roles.held' : 'personnel.roles.notHeld')}
                </span>
              </span>
              {#if mayChange(role)}
                <button
                  type="button"
                  class="border border-[var(--color-border)] px-2 py-0.5 focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
                  aria-label={t('personnel.roles.actionFor', { verb: verb(role, !role.held), role: role.name })}
                  disabled={busy || pending !== null}
                  onclick={(event) => ask(role, !role.held, event)}
                >
                  {verb(role, !role.held)}
                </button>
              {/if}
            </li>
          {/each}
        </ul>
      {/if}

      {#if pending}
        <div class="mt-2">
          <ConfirmDialog
            label={verb(pending.role, pending.grant)}
            question={t(pending.grant ? 'personnel.roles.confirmGrant' : 'personnel.roles.confirmRemove', {
              role: pending.role.name,
            })}
            {busy}
            {failure}
            fieldLabels={FIELD_LABELS}
            confirm={() => void confirm()}
            {cancel}
          >
            <label class="mt-2 flex flex-col gap-1">
              {t('personnel.roles.reason')}
              <textarea
                bind:value={reason}
                required
                minlength="3"
                maxlength="200"
                rows="2"
                class="border border-[var(--color-border)] px-2 py-1 focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
              ></textarea>
            </label>
          </ConfirmDialog>
        </div>
      {/if}

      {@render feedback()}
    </section>
  {:else if answer.may?.hire && hireRoles.length > 0}
    <div>
      <button
        bind:this={hireToggle}
        type="button"
        class="border border-[var(--color-border)] px-3 py-1 text-xs focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
        aria-expanded={hiring}
        onclick={() => (hiring = !hiring)}
      >
        {t('personnel.roles.hireNew')}
      </button>
      {#if hiring}
        <!-- `novalidate`: the server's own, translated refusal is the message,
             never the browser's English bubble. -->
        <form
          class="mt-2 flex flex-wrap items-end gap-3 border border-[var(--color-border)] p-3 text-xs"
          novalidate
          onsubmit={hire}
        >
          <label class="flex flex-col gap-1">
            {t('personnel.roles.discordId')}
            <input
              bind:value={hireForm.discordId}
              required
              inputmode="numeric"
              pattern={'[0-9]{17,20}'}
              maxlength="20"
              class="border border-[var(--color-border)] px-2 py-1 font-[family-name:var(--font-mono)] focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
            />
          </label>
          <label class="flex flex-col gap-1">
            {t('personnel.roles.role')}
            <select bind:value={hireForm.roleId} class="border border-[var(--color-border)] px-2 py-1 focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]">
              {#each hireRoles as role (role.id)}
                <option value={role.id}>{role.name}</option>
              {/each}
            </select>
          </label>
          <label class="flex flex-1 flex-col gap-1">
            {t('personnel.roles.reason')}
            <input
              bind:value={reason}
              required
              minlength="3"
              maxlength="200"
              class="border border-[var(--color-border)] px-2 py-1 focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
            />
          </label>
          <button
            type="submit"
            class="border border-[var(--color-border)] px-3 py-1 aria-disabled:opacity-60 focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]"
            aria-disabled={busy}
          >
            {t('personnel.roles.hire')}
          </button>
        </form>
      {/if}

      {@render feedback()}
    </div>
  {/if}

{/if}
