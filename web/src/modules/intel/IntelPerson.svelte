<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { CLASSIFICATIONS, INTEL_PERSON_STATUSES } from '@fredpd/schema';
  import type { ErrorCode } from '@fredpd/schema';
  import type { IntelNote, IntelPerson } from '../../lib/types';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';

  /**
   * People (spec 10): the register's own person, alias or description.
   *
   * Every write here is drawn for everybody and refused by the server
   * (invariant 4) -- there is no client-side permission check anywhere in
   * this file. A person may have neither a name nor an alias, which is a
   * description in the register rather than a broken row, so the list and
   * the detail panel both fall back the same way `intel.person.unknown` does.
   */

  interface Vehicle {
    id: number;
    plate: string | null;
    model: string | null;
    color: string | null;
    notes: string | null;
    personId: number;
    version: number;
  }

  interface Membership {
    orgId: number;
    role: string | null;
    isConfirmed: boolean;
    orgName: string;
    orgType: string | null;
    orgStatus: string;
  }

  interface Associate {
    personId: number;
    name: string | null;
    alias: string | null;
    status: string;
    relationship: string | null;
    isConfirmed: boolean;
  }

  interface CaseLink {
    id: number;
    caseId: number;
    role: string | null;
    title: string;
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

  interface PersonRecord {
    id: number;
    name: string | null;
    alias: string | null;
    description: string | null;
    status: string;
    classification: string;
    version: number;
  }

  interface Detail {
    person: PersonRecord;
    memberships: Membership[];
    associates: Associate[];
    vehicles: Vehicle[];
    cases: CaseLink[];
    evidence: Evidence[];
    notes: IntelNote[];
  }

  const FIELD_LABELS: Record<string, string> = {
    name: 'intel.person.name',
    alias: 'intel.person.alias',
    description: 'intel.person.description',
    status: 'intel.person.status',
    classification: 'intel.classification',
    keepId: 'intel.person.mergeKeepId',
    dropId: 'intel.person.mergeDropId',
    plate: 'intel.person.plate',
    model: 'intel.person.model',
    color: 'intel.person.color',
    notes: 'intel.person.vehicleNotes',
    orgId: 'intel.person.orgId',
    role: 'intel.person.role',
    associateId: 'intel.person.associateId',
    relationship: 'intel.person.relationship',
    url: 'intel.evidence.url',
    caption: 'intel.evidence.caption',
    body: 'intel.log.body',
  };

  /** A server timestamp with its date -- the same slice `IntelLog` reads by. */
  function when(value: string | null | undefined): string {
    if (!value) return '';

    return value.replace('T', ' ').slice(0, 16);
  }

  let persons = $state<IntelPerson[]>([]);
  let listError = $state<ErrorCode | null>(null);
  let listLoading = $state(true);

  async function loadList(): Promise<void> {
    listLoading = true;

    const response = await nui.call<{ persons: IntelPerson[] }>('intel.person.list', {});

    if (response.ok) {
      persons = response.data.persons;
      listError = null;
    } else {
      listError = response.err;
    }

    listLoading = false;
  }

  void loadList();

  // ------------------------------------------------------------------ detail

  let openId = $state<number | null>(null);
  let detail = $state<Detail | null>(null);
  let detailError = $state<ErrorCode | null>(null);
  let busy = $state(false);
  let failure = $state<Failure | null>(null);

  async function open(id: number): Promise<void> {
    busy = true;

    const response = await nui.call<Detail>('intel.person.get', { id });

    if (response.ok) {
      detail = response.data;
      openId = id;
      detailError = null;
      editing = false;
      resetEditForm(response.data.person);
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

  // -------------------------------------------------------------- creating

  let creating = $state(false);

  let createForm = $state({
    name: '',
    alias: '',
    description: '',
    status: INTEL_PERSON_STATUSES[0] as string,
    classification: 'internal',
  });

  function resetCreateForm(): void {
    createForm = {
      name: '',
      alias: '',
      description: '',
      status: INTEL_PERSON_STATUSES[0],
      classification: 'internal',
    };
  }

  async function create(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    busy = true;

    const response = await nui.call<{ id: number }>('intel.person.create', {
      name: createForm.name || undefined,
      alias: createForm.alias || undefined,
      description: createForm.description || undefined,
      status: createForm.status,
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

  // ---------------------------------------------------------------- editing

  let editing = $state(false);

  let editForm = $state({
    name: '',
    alias: '',
    description: '',
    status: '',
    classification: '',
  });

  function resetEditForm(person: PersonRecord): void {
    editForm = {
      name: person.name ?? '',
      alias: person.alias ?? '',
      description: person.description ?? '',
      status: person.status,
      classification: person.classification,
    };
  }

  async function save(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail) return;

    busy = true;

    const response = await nui.call<{ id: number }>('intel.person.update', {
      id: detail.person.id,
      version: detail.person.version,
      name: editForm.name || undefined,
      alias: editForm.alias || undefined,
      description: editForm.description || undefined,
      status: editForm.status,
      classification: editForm.classification,
    });

    if (response.ok) {
      failure = null;
      editing = false;
      await Promise.all([open(detail.person.id), loadList()]);
    } else {
      failure = response;
    }

    busy = false;
  }

  // --------------------------------------------------------------- deleting

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

    const response = await nui.call('intel.person.delete', { id: detail.person.id });

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

  // ----------------------------------------------------------------- merge

  let confirmingMerge = $state(false);
  let mergeTrigger: HTMLButtonElement | null = null;
  let mergeDropId = $state('');

  function askMerge(event: MouseEvent): void {
    confirmingMerge = true;
    failure = null;
    mergeDropId = '';
    mergeTrigger = event.currentTarget as HTMLButtonElement;
  }

  function cancelMerge(): void {
    confirmingMerge = false;
    failure = null;
    mergeTrigger?.focus();
  }

  async function merge(): Promise<void> {
    if (!detail || !mergeDropId) return;

    busy = true;

    const response = await nui.call<{ id: number }>('intel.person.merge', {
      keepId: detail.person.id,
      dropId: Number(mergeDropId),
    });

    if (response.ok) {
      failure = null;
      confirmingMerge = false;
      await Promise.all([open(detail.person.id), loadList()]);
    } else {
      failure = response;
    }

    busy = false;
  }

  // -------------------------------------------------------------- vehicles

  let vehicleForm = $state({ plate: '', model: '', color: '', notes: '' });

  async function addVehicle(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail) return;

    busy = true;

    const response = await nui.call('intel.vehicle.create', {
      personId: detail.person.id,
      plate: vehicleForm.plate || undefined,
      model: vehicleForm.model || undefined,
      color: vehicleForm.color || undefined,
      notes: vehicleForm.notes || undefined,
    });

    if (response.ok) {
      failure = null;
      vehicleForm = { plate: '', model: '', color: '', notes: '' };
      await open(detail.person.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  async function removeVehicle(id: number): Promise<void> {
    if (!detail) return;

    busy = true;

    const response = await nui.call('intel.vehicle.delete', { id });

    if (response.ok) {
      failure = null;
      await open(detail.person.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  // ---------------------------------------------------------- memberships

  let membershipForm = $state({ orgId: '', role: '', isConfirmed: false });

  async function addMembership(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail || !membershipForm.orgId) return;

    busy = true;

    const response = await nui.call('intel.membership.set', {
      personId: detail.person.id,
      orgId: Number(membershipForm.orgId),
      role: membershipForm.role || undefined,
      isConfirmed: membershipForm.isConfirmed || undefined,
    });

    if (response.ok) {
      failure = null;
      membershipForm = { orgId: '', role: '', isConfirmed: false };
      await open(detail.person.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  async function removeMembership(orgId: number): Promise<void> {
    if (!detail) return;

    busy = true;

    const response = await nui.call('intel.membership.remove', {
      personId: detail.person.id,
      orgId,
    });

    if (response.ok) {
      failure = null;
      await open(detail.person.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  // ------------------------------------------------------------ associates

  let associateForm = $state({ associateId: '', relationship: '', isConfirmed: false });

  async function addAssociate(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail || !associateForm.associateId) return;

    busy = true;

    const response = await nui.call('intel.associate.set', {
      personId: detail.person.id,
      associateId: Number(associateForm.associateId),
      relationship: associateForm.relationship || undefined,
      isConfirmed: associateForm.isConfirmed || undefined,
    });

    if (response.ok) {
      failure = null;
      associateForm = { associateId: '', relationship: '', isConfirmed: false };
      await open(detail.person.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  async function removeAssociate(associateId: number): Promise<void> {
    if (!detail) return;

    busy = true;

    const response = await nui.call('intel.associate.remove', {
      personId: detail.person.id,
      associateId,
    });

    if (response.ok) {
      failure = null;
      await open(detail.person.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  // -------------------------------------------------------------- case links

  async function unlinkCase(id: number): Promise<void> {
    if (!detail) return;

    busy = true;

    const response = await nui.call('intel.case.link.remove', { id });

    if (response.ok) {
      failure = null;
      await open(detail.person.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  // ---------------------------------------------------------------- evidence

  let evidenceForm = $state({ url: '', caption: '' });

  async function addEvidence(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail) return;

    busy = true;

    const response = await nui.call('intel.evidence.add', {
      personId: detail.person.id,
      url: evidenceForm.url || undefined,
      caption: evidenceForm.caption || undefined,
    });

    if (response.ok) {
      failure = null;
      evidenceForm = { url: '', caption: '' };
      await open(detail.person.id);
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
      await open(detail.person.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  // ------------------------------------------------------------------ notes

  let noteBody = $state('');

  async function addNote(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail || noteBody.trim() === '') return;

    busy = true;

    const response = await nui.call('intel.note.create', {
      personId: detail.person.id,
      body: noteBody.trim(),
    });

    if (response.ok) {
      failure = null;
      noteBody = '';
      await open(detail.person.id);
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
      <h2 class="text-sm font-semibold">{t('intel.tab.people')}</h2>
      <button
        type="button"
        class="border border-[var(--color-border)] px-3 py-1 text-xs hover:bg-[var(--color-surface)]"
        onclick={() => (creating = !creating)}
      >
        {t('intel.person.new')}
      </button>
    </header>

    {#if creating}
      <form class="flex flex-col gap-2 border border-[var(--color-border)] p-2 text-xs" onsubmit={create}>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.person.name')}</span>
          <input
            type="text"
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={createForm.name}
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.person.alias')}</span>
          <input
            type="text"
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={createForm.alias}
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.person.description')}</span>
          <textarea
            rows="2"
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={createForm.description}
          ></textarea>
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.person.status')}</span>
          <select
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={createForm.status}
          >
            {#each INTEL_PERSON_STATUSES as status (status)}
              <option value={status}>{t(`intel.personStatus.${status}`)}</option>
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
    {:else if persons.length === 0}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('intel.person.empty')}</p>
    {:else}
      <ul class="flex flex-col">
        {#each persons as person (person.id)}
          <li class="border-b border-[var(--color-border)] last:border-b-0">
            <button
              type="button"
              class="flex w-full flex-col gap-0.5 py-2 text-left hover:bg-[var(--color-surface)]"
              class:font-semibold={openId === person.id}
              onclick={() => void open(person.id)}
            >
              <span class="flex items-baseline justify-between gap-3 text-sm">
                {person.name ?? person.alias ?? t('intel.person.unknown')}
                <span class="text-xs font-normal text-[var(--color-ink-muted)]">
                  {t(`intel.personStatus.${person.status}`)}
                </span>
              </span>
              {#if person.description}
                <p class="text-xs text-[var(--color-ink-muted)]">{person.description}</p>
              {/if}
              <span class="flex flex-wrap gap-3 text-xs text-[var(--color-ink-muted)]">
                <span>{t('intel.person.noteCount', { count: person.noteCount ?? 0 })}</span>
                {#if person.plates}
                  <span>{person.plates}</span>
                {/if}
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
      <p class="text-sm text-[var(--color-ink-muted)]">{t('intel.person.empty')}</p>
    {:else}
      {@const person = detail.person}

      <div class="flex items-start justify-between gap-3">
        <h2 class="text-sm font-semibold">{person.name ?? person.alias ?? t('intel.person.unknown')}</h2>
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
            onclick={askMerge}
          >
            {t('intel.person.merge')}
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

      {#if failure && !confirmingDelete && !confirmingMerge}
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
            <span class="text-[var(--color-ink-muted)]">{t('intel.person.name')}</span>
            <input
              type="text"
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={editForm.name}
            />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-[var(--color-ink-muted)]">{t('intel.person.alias')}</span>
            <input
              type="text"
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={editForm.alias}
            />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-[var(--color-ink-muted)]">{t('intel.person.description')}</span>
            <textarea
              rows="2"
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={editForm.description}
            ></textarea>
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-[var(--color-ink-muted)]">{t('intel.person.status')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={editForm.status}
            >
              {#each INTEL_PERSON_STATUSES as status (status)}
                <option value={status}>{t(`intel.personStatus.${status}`)}</option>
              {/each}
            </select>
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
          <span>{t(`intel.personStatus.${person.status}`)}</span>
          <span>{t(`records.classification.${person.classification}`)}</span>
        </div>
        {#if person.description}
          <p class="mt-2">{person.description}</p>
        {/if}
      {/if}

      {#if confirmingDelete}
        <div class="mt-2">
          <ConfirmDialog
            label={t('intel.action.delete')}
            question={t('intel.person.deleteConfirm', {
              name: person.name ?? person.alias ?? t('intel.person.unknown'),
            })}
            {busy}
            {failure}
            fieldLabels={FIELD_LABELS}
            confirm={() => void remove()}
            cancel={cancelDelete}
          />
        </div>
      {/if}

      {#if confirmingMerge}
        <div class="mt-2">
          <ConfirmDialog
            label={t('intel.person.merge')}
            question={t('intel.person.mergeHint')}
            {busy}
            {failure}
            fieldLabels={FIELD_LABELS}
            confirm={() => void merge()}
            cancel={cancelMerge}
          >
            <label class="mt-1 flex flex-col gap-1">
              <span class="text-[var(--color-ink-muted)]">{t('intel.person.mergeDropId')}</span>
              <input
                type="number"
                min="1"
                class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
                bind:value={mergeDropId}
              />
            </label>
          </ConfirmDialog>
        </div>
      {/if}

      <!-- Vehicles -->
      <h3 class="mt-4 font-semibold">{t('intel.person.vehicles')}</h3>
      {#if detail.vehicles.length === 0}
        <p class="mt-1 text-[var(--color-ink-muted)]">{t('intel.person.noVehicles')}</p>
      {:else}
        <ul class="mt-1 flex flex-col">
          {#each detail.vehicles as vehicle (vehicle.id)}
            <li class="flex items-center justify-between gap-2 border-b border-[var(--color-border)] py-1 last:border-b-0">
              <span>
                <span class="font-[family-name:var(--font-mono)]">{vehicle.plate ?? ''}</span>
                {#if vehicle.model || vehicle.color}
                  <span class="text-[var(--color-ink-muted)]"> — {[vehicle.color, vehicle.model].filter(Boolean).join(' ')}</span>
                {/if}
              </span>
              <button
                type="button"
                class="border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-surface)]"
                onclick={() => void removeVehicle(vehicle.id)}
              >
                {t('intel.action.remove')}
              </button>
            </li>
          {/each}
        </ul>
      {/if}
      <form class="mt-1 flex flex-wrap items-end gap-2" onsubmit={addVehicle}>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.person.plate')}</span>
          <input
            type="text"
            class="w-28 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
            bind:value={vehicleForm.plate}
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.person.model')}</span>
          <input
            type="text"
            class="w-28 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={vehicleForm.model}
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.person.color')}</span>
          <input
            type="text"
            class="w-24 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={vehicleForm.color}
          />
        </label>
        <button type="submit" class="border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]" disabled={busy}>
          {t('intel.person.addVehicle')}
        </button>
      </form>

      <!-- Memberships -->
      <h3 class="mt-4 font-semibold">{t('intel.person.orgs')}</h3>
      {#if detail.memberships.length === 0}
        <p class="mt-1 text-[var(--color-ink-muted)]">{t('intel.person.noMemberships')}</p>
      {:else}
        <ul class="mt-1 flex flex-col">
          {#each detail.memberships as membership (membership.orgId)}
            <li class="flex items-center justify-between gap-2 border-b border-[var(--color-border)] py-1 last:border-b-0">
              <span>
                {membership.orgName}
                {#if membership.role}
                  <span class="text-[var(--color-ink-muted)]"> — {membership.role}</span>
                {/if}
                <span class="text-[var(--color-ink-muted)]">
                  ({t(membership.isConfirmed ? 'intel.person.confirmed' : 'intel.person.suspected')})
                </span>
              </span>
              <button
                type="button"
                class="border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-surface)]"
                onclick={() => void removeMembership(membership.orgId)}
              >
                {t('intel.action.remove')}
              </button>
            </li>
          {/each}
        </ul>
      {/if}
      <form class="mt-1 flex flex-wrap items-end gap-2" onsubmit={addMembership}>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.person.orgId')}</span>
          <input
            type="number"
            min="1"
            class="w-24 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={membershipForm.orgId}
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.person.role')}</span>
          <input
            type="text"
            class="w-32 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={membershipForm.role}
          />
        </label>
        <label class="flex items-center gap-1">
          <input type="checkbox" bind:checked={membershipForm.isConfirmed} />
          {t('intel.person.confirmed')}
        </label>
        <button type="submit" class="border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]" disabled={busy}>
          {t('intel.person.addMembership')}
        </button>
      </form>

      <!-- Associates -->
      <h3 class="mt-4 font-semibold">{t('intel.person.associates')}</h3>
      {#if detail.associates.length === 0}
        <p class="mt-1 text-[var(--color-ink-muted)]">{t('intel.person.noAssociates')}</p>
      {:else}
        <ul class="mt-1 flex flex-col">
          {#each detail.associates as associate (associate.personId)}
            <li class="flex items-center justify-between gap-2 border-b border-[var(--color-border)] py-1 last:border-b-0">
              <span>
                {associate.name ?? associate.alias ?? t('intel.person.unknown')}
                {#if associate.relationship}
                  <span class="text-[var(--color-ink-muted)]"> — {associate.relationship}</span>
                {/if}
                <span class="text-[var(--color-ink-muted)]">
                  ({t(associate.isConfirmed ? 'intel.person.confirmed' : 'intel.person.suspected')})
                </span>
              </span>
              <button
                type="button"
                class="border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-surface)]"
                onclick={() => void removeAssociate(associate.personId)}
              >
                {t('intel.action.remove')}
              </button>
            </li>
          {/each}
        </ul>
      {/if}
      <form class="mt-1 flex flex-wrap items-end gap-2" onsubmit={addAssociate}>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.person.associateId')}</span>
          <input
            type="number"
            min="1"
            class="w-24 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={associateForm.associateId}
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.person.relationship')}</span>
          <input
            type="text"
            class="w-32 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={associateForm.relationship}
          />
        </label>
        <label class="flex items-center gap-1">
          <input type="checkbox" bind:checked={associateForm.isConfirmed} />
          {t('intel.person.confirmed')}
        </label>
        <button type="submit" class="border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]" disabled={busy}>
          {t('intel.person.addAssociate')}
        </button>
      </form>

      <!-- Cases -->
      <h3 class="mt-4 font-semibold">{t('intel.person.cases')}</h3>
      {#if detail.cases.length === 0}
        <p class="mt-1 text-[var(--color-ink-muted)]">{t('intel.person.noCases')}</p>
      {:else}
        <ul class="mt-1 flex flex-col">
          {#each detail.cases as link (link.id)}
            <li class="flex items-center justify-between gap-2 border-b border-[var(--color-border)] py-1 last:border-b-0">
              <span>
                {link.title}
                <span class="text-[var(--color-ink-muted)]"> — {t(`intel.caseStatus.${link.status}`)}</span>
                {#if link.role}
                  <span class="text-[var(--color-ink-muted)]"> ({link.role})</span>
                {/if}
              </span>
              <button
                type="button"
                class="border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-surface)]"
                onclick={() => void unlinkCase(link.id)}
              >
                {t('intel.action.remove')}
              </button>
            </li>
          {/each}
        </ul>
      {/if}

      <!-- Evidence -->
      <h3 class="mt-4 font-semibold">{t('intel.evidence.title')}</h3>
      {#if detail.evidence.length === 0}
        <p class="mt-1 text-[var(--color-ink-muted)]">{t('intel.evidence.empty')}</p>
      {:else}
        <ul class="mt-1 flex flex-col">
          {#each detail.evidence as item (item.id)}
            <li class="flex items-center justify-between gap-2 border-b border-[var(--color-border)] py-1 last:border-b-0">
              <span>
                {item.caption ?? item.url ?? ''}
              </span>
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
