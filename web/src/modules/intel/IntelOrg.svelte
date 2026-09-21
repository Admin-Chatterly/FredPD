<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { CLASSIFICATIONS, INTEL_ORG_STATUSES, INTEL_ORG_TYPES } from '@fredpd/schema';
  import type { ErrorCode } from '@fredpd/schema';
  import type { IntelNote, IntelOrg } from '../../lib/types';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';

  /**
   * Organizations (spec 10): gangs, crews and the businesses that front them.
   *
   * Membership is written from here as well as from a person's own detail
   * panel -- `intel.membership.set` takes both ids either way, and a
   * supervisor tidying a roster should not have to open every member in turn
   * to add or remove one.
   */

  interface RosterMember {
    personId: number;
    role: string | null;
    isConfirmed: boolean;
    name: string | null;
    alias: string | null;
    status: string;
  }

  interface Evidence {
    id: number;
    storagePath: string | null;
    url: string | null;
    caption: string | null;
    createdBy: string | null;
    createdAt: string;
  }

  interface OrgRecord {
    id: number;
    name: string;
    type: string | null;
    territory: string | null;
    status: string;
    notes: string | null;
    classification: string;
    version: number;
  }

  interface Detail {
    org: OrgRecord;
    roster: RosterMember[];
    evidence: Evidence[];
    notes: IntelNote[];
  }

  const FIELD_LABELS: Record<string, string> = {
    name: 'intel.org.name',
    type: 'intel.org.type',
    territory: 'intel.org.territory',
    status: 'intel.org.status',
    notes: 'intel.org.notes',
    classification: 'intel.classification',
    personId: 'intel.org.personId',
    orgId: 'intel.person.orgId',
    role: 'intel.person.role',
    url: 'intel.evidence.url',
    caption: 'intel.evidence.caption',
    body: 'intel.log.body',
  };

  function when(value: string | null | undefined): string {
    if (!value) return '';

    return value.replace('T', ' ').slice(0, 16);
  }

  let orgs = $state<IntelOrg[]>([]);
  let listError = $state<ErrorCode | null>(null);
  let listLoading = $state(true);

  async function loadList(): Promise<void> {
    listLoading = true;

    const response = await nui.call<{ orgs: IntelOrg[] }>('intel.org.list', {});

    if (response.ok) {
      orgs = response.data.orgs;
      listError = null;
    } else {
      listError = response.err;
    }

    listLoading = false;
  }

  void loadList();

  let openId = $state<number | null>(null);
  let detail = $state<Detail | null>(null);
  let detailError = $state<ErrorCode | null>(null);
  let busy = $state(false);
  let failure = $state<Failure | null>(null);

  async function open(id: number): Promise<void> {
    busy = true;

    const response = await nui.call<Detail>('intel.org.get', { id });

    if (response.ok) {
      detail = response.data;
      openId = id;
      detailError = null;
      editing = false;
      resetEditForm(response.data.org);
    } else {
      detail = null;
      openId = null;
      detailError = response.err;
    }

    busy = false;
  }

  function close(): void {
    openId = null;
    detail = null;
    failure = null;
  }

  let creating = $state(false);

  let createForm = $state({
    name: '',
    type: INTEL_ORG_TYPES[0] as string,
    territory: '',
    status: INTEL_ORG_STATUSES[0] as string,
    notes: '',
    classification: 'internal',
  });

  function resetCreateForm(): void {
    createForm = {
      name: '',
      type: INTEL_ORG_TYPES[0],
      territory: '',
      status: INTEL_ORG_STATUSES[0],
      notes: '',
      classification: 'internal',
    };
  }

  async function create(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    busy = true;

    const response = await nui.call<{ id: number }>('intel.org.create', {
      name: createForm.name,
      type: createForm.type,
      territory: createForm.territory || undefined,
      status: createForm.status,
      notes: createForm.notes || undefined,
      classification: createForm.classification,
    });

    if (response.ok) {
      failure = null;
      creating = false;
      resetCreateForm();
      await loadList();
      await open(response.data.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  let editing = $state(false);

  let editForm = $state({
    name: '',
    type: '',
    territory: '',
    status: '',
    notes: '',
    classification: '',
  });

  function resetEditForm(org: OrgRecord): void {
    editForm = {
      name: org.name,
      type: org.type ?? '',
      territory: org.territory ?? '',
      status: org.status,
      notes: org.notes ?? '',
      classification: org.classification,
    };
  }

  async function save(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail) return;

    busy = true;

    const response = await nui.call<{ id: number }>('intel.org.update', {
      id: detail.org.id,
      version: detail.org.version,
      name: editForm.name || undefined,
      type: editForm.type || undefined,
      territory: editForm.territory || undefined,
      status: editForm.status,
      notes: editForm.notes || undefined,
      classification: editForm.classification,
    });

    if (response.ok) {
      failure = null;
      editing = false;
      await Promise.all([open(detail.org.id), loadList()]);
    } else {
      failure = response;
    }

    busy = false;
  }

  let confirmingDelete = $state(false);
  let deleteTrigger: HTMLButtonElement | null = null;

  function askDelete(event: MouseEvent): void {
    confirmingDelete = true;
    failure = null;
    deleteTrigger = event.currentTarget as HTMLButtonElement;
  }

  function cancelDelete(): void {
    confirmingDelete = false;
    failure = null;
    deleteTrigger?.focus();
  }

  async function remove(): Promise<void> {
    if (!detail) return;

    busy = true;

    const response = await nui.call('intel.org.delete', { id: detail.org.id });

    if (response.ok) {
      failure = null;
      confirmingDelete = false;
      close();
      await loadList();
    } else {
      failure = response;
    }

    busy = false;
  }

  let memberForm = $state({ personId: '', role: '', isConfirmed: false });

  async function addMember(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail || !memberForm.personId) return;

    busy = true;

    const response = await nui.call('intel.membership.set', {
      personId: Number(memberForm.personId),
      orgId: detail.org.id,
      role: memberForm.role || undefined,
      isConfirmed: memberForm.isConfirmed || undefined,
    });

    if (response.ok) {
      failure = null;
      memberForm = { personId: '', role: '', isConfirmed: false };
      await open(detail.org.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  async function removeMember(personId: number): Promise<void> {
    if (!detail) return;

    busy = true;

    const response = await nui.call('intel.membership.remove', {
      personId,
      orgId: detail.org.id,
    });

    if (response.ok) {
      failure = null;
      await open(detail.org.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  let evidenceForm = $state({ url: '', caption: '' });

  async function addEvidence(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail) return;

    busy = true;

    const response = await nui.call('intel.evidence.add', {
      orgId: detail.org.id,
      url: evidenceForm.url || undefined,
      caption: evidenceForm.caption || undefined,
    });

    if (response.ok) {
      failure = null;
      evidenceForm = { url: '', caption: '' };
      await open(detail.org.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  async function removeEvidence(id: number): Promise<void> {
    if (!detail) return;

    busy = true;

    const response = await nui.call('intel.evidence.delete', { id });

    if (response.ok) {
      failure = null;
      await open(detail.org.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  let noteBody = $state('');

  async function addNote(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail || noteBody.trim() === '') return;

    busy = true;

    const response = await nui.call('intel.note.create', {
      orgId: detail.org.id,
      body: noteBody.trim(),
    });

    if (response.ok) {
      failure = null;
      noteBody = '';
      await open(detail.org.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  const messages = $derived(fieldList(failure, FIELD_LABELS));
</script>

<div class="flex min-h-0 flex-1 gap-3">
  <section class="flex w-96 shrink-0 flex-col gap-2 overflow-y-auto border border-[var(--color-border)] p-3">
    <header class="flex items-center justify-between gap-2">
      <h2 class="text-sm font-semibold">{t('intel.tab.orgs')}</h2>
      <button
        type="button"
        class="border border-[var(--color-border)] px-3 py-1 text-xs hover:bg-[var(--color-surface)]"
        onclick={() => (creating = !creating)}
      >
        {t('intel.org.new')}
      </button>
    </header>

    {#if creating}
      <form class="flex flex-col gap-2 border border-[var(--color-border)] p-2 text-xs" onsubmit={create}>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.org.name')}</span>
          <input
            type="text"
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={createForm.name}
            required
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.org.type')}</span>
          <select
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={createForm.type}
          >
            {#each INTEL_ORG_TYPES as value (value)}
              <option {value}>{t(`intel.orgType.${value}`)}</option>
            {/each}
          </select>
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.org.territory')}</span>
          <input
            type="text"
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={createForm.territory}
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.org.status')}</span>
          <select
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={createForm.status}
          >
            {#each INTEL_ORG_STATUSES as value (value)}
              <option {value}>{t(`intel.orgStatus.${value}`)}</option>
            {/each}
          </select>
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.classification')}</span>
          <select
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={createForm.classification}
          >
            {#each CLASSIFICATIONS as value (value)}
              <option {value}>{t(`records.classification.${value}`)}</option>
            {/each}
          </select>
        </label>
        <button
          type="submit"
          class="self-start border border-[var(--color-border)] px-3 py-1 font-semibold hover:bg-[var(--color-surface)]"
          disabled={busy}
        >
          {t('intel.action.create')}
        </button>
      </form>
    {/if}

    {#if listError}
      <p class="border border-[var(--color-border)] px-3 py-2 text-xs">{t(`error.${listError}`)}</p>
    {/if}

    {#if listLoading}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
    {:else if orgs.length === 0}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('intel.org.empty')}</p>
    {:else}
      <ul class="flex flex-col">
        {#each orgs as org (org.id)}
          <li class="border-b border-[var(--color-border)] last:border-b-0">
            <button
              type="button"
              class="flex w-full flex-col gap-0.5 py-2 text-left hover:bg-[var(--color-surface)]"
              class:font-semibold={openId === org.id}
              onclick={() => void open(org.id)}
            >
              <span class="flex items-baseline justify-between gap-3 text-sm">
                {org.name}
                <span class="text-xs font-normal text-[var(--color-ink-muted)]">
                  {t(`intel.orgStatus.${org.status}`)}
                </span>
              </span>
              <span class="flex flex-wrap gap-3 text-xs text-[var(--color-ink-muted)]">
                {#if org.type}
                  <span>{t(`intel.orgType.${org.type}`)}</span>
                {/if}
                <span>{t('intel.org.members', { count: org.memberCount ?? 0 })}</span>
              </span>
            </button>
          </li>
        {/each}
      </ul>
    {/if}
  </section>

  <section class="min-h-0 flex-1 overflow-y-auto border border-[var(--color-border)] p-3 text-xs">
    {#if detailError}
      <p class="border border-[var(--color-border)] px-3 py-2 text-sm">{t(`error.${detailError}`)}</p>
    {:else if !detail}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('intel.org.empty')}</p>
    {:else}
      {@const org = detail.org}

      <div class="flex items-start justify-between gap-3">
        <h2 class="text-sm font-semibold">{org.name}</h2>
        <div class="flex gap-2">
          <button
            type="button"
            class="border border-[var(--color-border)] px-2 py-1 hover:bg-[var(--color-surface)]"
            onclick={() => (editing = !editing)}
          >
            {t('intel.action.edit')}
          </button>
          <button
            type="button"
            class="border border-[var(--color-border)] px-2 py-1 hover:bg-[var(--color-surface)]"
            onclick={askDelete}
          >
            {t('intel.action.delete')}
          </button>
        </div>
      </div>

      {#if failure && !confirmingDelete}
        <div class="mt-2 border border-[var(--color-alert)] px-2 py-1">
          <p class="font-semibold">{t(`error.${failure.err}`)}</p>
          {#each messages as message (message.name)}
            <p class="text-[var(--color-alert)]">{message.label} — {message.reason}</p>
          {/each}
        </div>
      {/if}

      {#if editing}
        <form class="mt-2 flex flex-col gap-2 border border-[var(--color-border)] p-2" onsubmit={save}>
          <label class="flex flex-col gap-1">
            <span class="text-[var(--color-ink-muted)]">{t('intel.org.name')}</span>
            <input
              type="text"
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={editForm.name}
            />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-[var(--color-ink-muted)]">{t('intel.org.type')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={editForm.type}
            >
              {#each INTEL_ORG_TYPES as value (value)}
                <option {value}>{t(`intel.orgType.${value}`)}</option>
              {/each}
            </select>
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-[var(--color-ink-muted)]">{t('intel.org.territory')}</span>
            <input
              type="text"
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={editForm.territory}
            />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-[var(--color-ink-muted)]">{t('intel.org.status')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={editForm.status}
            >
              {#each INTEL_ORG_STATUSES as value (value)}
                <option {value}>{t(`intel.orgStatus.${value}`)}</option>
              {/each}
            </select>
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-[var(--color-ink-muted)]">{t('intel.org.notes')}</span>
            <textarea
              rows="2"
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={editForm.notes}
            ></textarea>
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-[var(--color-ink-muted)]">{t('intel.classification')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={editForm.classification}
            >
              {#each CLASSIFICATIONS as value (value)}
                <option {value}>{t(`records.classification.${value}`)}</option>
              {/each}
            </select>
          </label>
          <button
            type="submit"
            class="self-start border border-[var(--color-border)] px-3 py-1 font-semibold hover:bg-[var(--color-surface)]"
            disabled={busy}
          >
            {t('intel.action.save')}
          </button>
        </form>
      {:else}
        <div class="mt-2 flex flex-wrap gap-3 text-[var(--color-ink-muted)]">
          {#if org.type}
            <span>{t(`intel.orgType.${org.type}`)}</span>
          {/if}
          <span>{t(`intel.orgStatus.${org.status}`)}</span>
          <span>{t(`records.classification.${org.classification}`)}</span>
          {#if org.territory}
            <span>{org.territory}</span>
          {/if}
        </div>
        {#if org.notes}
          <p class="mt-2">{org.notes}</p>
        {/if}
      {/if}

      {#if confirmingDelete}
        <div class="mt-2">
          <ConfirmDialog
            label={t('intel.action.delete')}
            question={t('intel.org.deleteConfirm', { name: org.name })}
            {busy}
            {failure}
            fieldLabels={FIELD_LABELS}
            confirm={() => void remove()}
            cancel={cancelDelete}
          />
        </div>
      {/if}

      <!-- Roster -->
      <h3 class="mt-4 font-semibold">{t('intel.org.roster')}</h3>
      {#if detail.roster.length === 0}
        <p class="mt-1 text-[var(--color-ink-muted)]">{t('intel.org.noRoster')}</p>
      {:else}
        <ul class="mt-1 flex flex-col">
          {#each detail.roster as member (member.personId)}
            <li class="flex items-center justify-between gap-2 border-b border-[var(--color-border)] py-1 last:border-b-0">
              <span>
                {member.name ?? member.alias ?? t('intel.person.unknown')}
                {#if member.role}
                  <span class="text-[var(--color-ink-muted)]"> — {member.role}</span>
                {/if}
                <span class="text-[var(--color-ink-muted)]">
                  ({t(member.isConfirmed ? 'intel.person.confirmed' : 'intel.person.suspected')})
                </span>
              </span>
              <button
                type="button"
                class="border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-surface)]"
                onclick={() => void removeMember(member.personId)}
              >
                {t('intel.action.remove')}
              </button>
            </li>
          {/each}
        </ul>
      {/if}
      <form class="mt-1 flex flex-wrap items-end gap-2" onsubmit={addMember}>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.org.personId')}</span>
          <input
            type="number"
            min="1"
            class="w-24 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={memberForm.personId}
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.person.role')}</span>
          <input
            type="text"
            class="w-32 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={memberForm.role}
          />
        </label>
        <label class="flex items-center gap-1">
          <input type="checkbox" bind:checked={memberForm.isConfirmed} />
          {t('intel.person.confirmed')}
        </label>
        <button type="submit" class="border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]" disabled={busy}>
          {t('intel.org.addMember')}
        </button>
      </form>

      <!-- Evidence -->
      <h3 class="mt-4 font-semibold">{t('intel.evidence.title')}</h3>
      {#if detail.evidence.length === 0}
        <p class="mt-1 text-[var(--color-ink-muted)]">{t('intel.evidence.empty')}</p>
      {:else}
        <ul class="mt-1 flex flex-col">
          {#each detail.evidence as item (item.id)}
            <li class="flex items-center justify-between gap-2 border-b border-[var(--color-border)] py-1 last:border-b-0">
              <span>{item.caption ?? item.url ?? ''}</span>
              <button
                type="button"
                class="border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-surface)]"
                onclick={() => void removeEvidence(item.id)}
              >
                {t('intel.action.remove')}
              </button>
            </li>
          {/each}
        </ul>
      {/if}
      <form class="mt-1 flex flex-wrap items-end gap-2" onsubmit={addEvidence}>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.evidence.url')}</span>
          <input
            type="text"
            class="w-56 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={evidenceForm.url}
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.evidence.caption')}</span>
          <input
            type="text"
            class="w-40 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={evidenceForm.caption}
          />
        </label>
        <button type="submit" class="border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]" disabled={busy}>
          {t('intel.evidence.add')}
        </button>
      </form>

      <!-- Notes -->
      <h3 class="mt-4 font-semibold">{t('intel.person.notes')}</h3>
      {#if detail.notes.length === 0}
        <p class="mt-1 text-[var(--color-ink-muted)]">{t('intel.person.noNotes')}</p>
      {:else}
        <ul class="mt-1 flex flex-col gap-2">
          {#each detail.notes as note (note.id)}
            <li class="border border-[var(--color-border)] p-2">
              <p class="whitespace-pre-wrap">{note.body}</p>
              <p class="mt-1 text-[var(--color-ink-muted)]">{when(note.createdAt)}</p>
            </li>
          {/each}
        </ul>
      {/if}
      <form class="mt-1 flex flex-col gap-2" onsubmit={addNote}>
        <textarea
          rows="2"
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          placeholder={t('intel.log.bodyPlaceholder')}
          bind:value={noteBody}
        ></textarea>
        <button type="submit" class="self-start border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]" disabled={busy}>
          {t('intel.log.post')}
        </button>
      </form>
    {/if}
  </section>
</div>
