<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { CLASSIFICATIONS, INTEL_CASE_STATUSES } from '@fredpd/schema';
  import type { ErrorCode } from '@fredpd/schema';
  import type { IntelCase, IntelNote } from '../../lib/types';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import EntityPicker from '../shared/EntityPicker.svelte';
  import { isStub, type Maybe, type Restricted } from '../records/types';

  /**
   * Cases (spec 10): everyone and everything linked to an investigation, in
   * one board.
   *
   * A link names exactly one of a person or an organization — the database
   * enforces it, and the route refuses `target: 'exactly_one'` rather than an
   * internal error, so the form below asks which kind before it asks for an
   * id instead of taking both.
   */

  interface CaseLink {
    id: number;
    caseId: number;
    personId: number | null;
    orgId: number | null;
    role: string | null;
    targetKind: string;
    personName: string | null;
    personAlias: string | null;
    personStatus: string | null;
    orgName: string | null;
    orgType: string | null;
  }

  interface Evidence {
    id: number;
    storagePath: string | null;
    url: string | null;
    caption: string | null;
    createdBy: string | null;
    createdAt: string;
  }

  interface CaseRecord {
    id: number;
    number: string | null;
    title: string;
    description: string | null;
    status: string;
    classification: string;
    version: number;
  }

  interface Detail {
    case: CaseRecord;
    links: CaseLink[];
    evidence: Evidence[];
    notes: IntelNote[];
  }

  const FIELD_LABELS: Record<string, string> = {
    title: 'intel.case.title',
    description: 'intel.case.description',
    status: 'intel.case.status',
    classification: 'intel.classification',
    personId: 'intel.case.linkId',
    orgId: 'intel.case.linkId',
    role: 'intel.case.linkRole',
    target: 'intel.case.linkKind',
    url: 'intel.evidence.url',
    caption: 'intel.evidence.caption',
    body: 'intel.log.body',
  };

  function when(value: string | null | undefined): string {
    if (!value) return '';

    return value.replace('T', ' ').slice(0, 16);
  }

  /** The list, with a stub where the server says a record exists that this reader may not open. */
  let cases = $state<Maybe<IntelCase>[]>([]);

  /** Who to ask about a record this reader may see only as a stub (4.5). */
  function stubContact(row: Restricted): string {
    return t('records.restricted.contact', { unit: t(`access.unit.${row.contact}`) });
  }
  let listError = $state<ErrorCode | null>(null);
  let listLoading = $state(true);

  async function loadList(): Promise<void> {
    listLoading = true;

    const response = await nui.call<{ cases: Maybe<IntelCase>[] }>('intel.case.list', {});

    if (response.ok) {
      cases = response.data.cases;
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

    const response = await nui.call<Detail>('intel.case.get', { id });

    if (response.ok) {
      detail = response.data;
      openId = id;
      detailError = null;
      editing = false;
      resetEditForm(response.data.case);
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
    title: '',
    description: '',
    status: INTEL_CASE_STATUSES[0] as string,
    classification: 'internal',
  });

  function resetCreateForm(): void {
    createForm = {
      title: '',
      description: '',
      status: INTEL_CASE_STATUSES[0],
      classification: 'internal',
    };
  }

  async function create(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    busy = true;

    const response = await nui.call<{ id: number }>('intel.case.create', {
      title: createForm.title,
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

  let editing = $state(false);

  let editForm = $state({ title: '', description: '', status: '', classification: '' });

  function resetEditForm(record: CaseRecord): void {
    editForm = {
      title: record.title,
      description: record.description ?? '',
      status: record.status,
      classification: record.classification,
    };
  }

  async function save(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail) return;

    busy = true;

    const response = await nui.call<{ id: number }>('intel.case.update', {
      id: detail.case.id,
      version: detail.case.version,
      title: editForm.title || undefined,
      description: editForm.description || undefined,
      status: editForm.status,
      classification: editForm.classification,
    });

    if (response.ok) {
      failure = null;
      editing = false;
      await Promise.all([open(detail.case.id), loadList()]);
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

    const response = await nui.call('intel.case.delete', { id: detail.case.id });

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

  const LINK_KINDS = ['person', 'org'] as const;

  interface LinkTarget {
    id: number;
    label: string;
  }

  /** Both lists already browse everything when the box is empty (the same
   *  `Intel.searchTerm` rule `searchOrgs`/`searchAssociateCandidates` in
   *  IntelPerson.svelte lean on), normalized to one shape so the picker below
   *  does not need to know which kind it is showing. */
  async function searchLinkTargets(term: string): Promise<LinkTarget[]> {
    if (linkForm.kind === 'org') {
      const response = await nui.call<{ orgs: Maybe<{ id: number; name: string }>[] }>('intel.org.list', {
        search: term || undefined,
        limit: 8,
      });

      // A stub is nothing to link to: the server would refuse it anyway.
      return response.ok
        ? response.data.orgs.flatMap((org) => (isStub(org) ? [] : [{ id: org.id, label: org.name }]))
        : [];
    }

    const response = await nui.call<{
      persons: Maybe<{ id: number; name: string | null; alias: string | null }>[];
    }>('intel.person.list', { search: term || undefined, limit: 8 });

    if (!response.ok) return [];

    return response.data.persons.flatMap((person) =>
      isStub(person) ? [] : [{ id: person.id, label: person.name ?? person.alias ?? t('intel.person.unknown') }],
    );
  }

  let linkForm = $state({ kind: 'person' as 'person' | 'org', targetId: '', targetName: '', role: '' });

  /** Switching kind mid-pick would otherwise leave a person's id sitting
   *  under a selection drawn from the organization list, or the reverse. */
  function onLinkKindChange(): void {
    linkForm.targetId = '';
    linkForm.targetName = '';
  }

  async function addLink(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail || !linkForm.targetId) return;

    busy = true;

    const response = await nui.call('intel.case.link.add', {
      caseId: detail.case.id,
      personId: linkForm.kind === 'person' ? Number(linkForm.targetId) : undefined,
      orgId: linkForm.kind === 'org' ? Number(linkForm.targetId) : undefined,
      role: linkForm.role || undefined,
    });

    if (response.ok) {
      failure = null;
      linkForm = { kind: 'person', targetId: '', targetName: '', role: '' };
      await open(detail.case.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  async function removeLink(id: number): Promise<void> {
    if (!detail) return;

    busy = true;

    const response = await nui.call('intel.case.link.remove', { id });

    if (response.ok) {
      failure = null;
      await open(detail.case.id);
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
      caseId: detail.case.id,
      url: evidenceForm.url || undefined,
      caption: evidenceForm.caption || undefined,
    });

    if (response.ok) {
      failure = null;
      evidenceForm = { url: '', caption: '' };
      await open(detail.case.id);
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
      await open(detail.case.id);
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
      caseId: detail.case.id,
      body: noteBody.trim(),
    });

    if (response.ok) {
      failure = null;
      noteBody = '';
      await open(detail.case.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  function linkLabel(link: CaseLink): string {
    if (link.targetKind === 'person') {
      return link.personName ?? link.personAlias ?? t('intel.person.unknown');
    }

    return link.orgName ?? '';
  }

  const messages = $derived(fieldList(failure, FIELD_LABELS));
</script>

<div class="flex min-h-0 flex-1 gap-3">
  <section class="flex w-96 shrink-0 flex-col gap-2 overflow-y-auto border border-[var(--color-border)] p-3">
    <header class="flex items-center justify-between gap-2">
      <h2 class="text-sm font-semibold">{t('intel.tab.cases')}</h2>
      <button
        type="button"
        class="border border-[var(--color-border)] px-3 py-1 text-xs hover:bg-[var(--color-surface)]"
        onclick={() => (creating = !creating)}
      >
        {t('intel.case.new')}
      </button>
    </header>

    {#if creating}
      <form class="flex flex-col gap-2 border border-[var(--color-border)] p-2 text-xs" onsubmit={create}>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.case.title')}</span>
          <input
            type="text"
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={createForm.title}
            required
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.case.description')}</span>
          <textarea
            rows="2"
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={createForm.description}
          ></textarea>
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.case.status')}</span>
          <select
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={createForm.status}
          >
            {#each INTEL_CASE_STATUSES as value (value)}
              <option {value}>{t(`intel.caseStatus.${value}`)}</option>
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
    {:else if cases.length === 0}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('intel.case.empty')}</p>
    {:else}
      <ul class="flex flex-col">
        {#each cases as record, index (isStub(record) ? `stub-${index}` : record.id)}
          {#if isStub(record)}
            <li class="border-b border-[var(--color-border)] py-2 text-sm text-[var(--color-ink-muted)] last:border-b-0">
              {t('records.restricted.title')} — {stubContact(record)}
            </li>
          {:else}
          <li class="border-b border-[var(--color-border)] last:border-b-0">
            <button
              type="button"
              class="flex w-full flex-col gap-0.5 py-2 text-left hover:bg-[var(--color-surface)]"
              class:font-semibold={openId === record.id}
              onclick={() => void open(record.id)}
            >
              <span class="flex items-baseline justify-between gap-3 text-sm">
                <span>
                  {#if record.number}
                    <span class="font-[family-name:var(--font-mono)] text-xs text-[var(--color-ink-muted)]">
                      {record.number}
                    </span>
                  {/if}
                  {record.title}
                </span>
                <span class="text-xs font-normal text-[var(--color-ink-muted)]">
                  {t(`intel.caseStatus.${record.status}`)}
                </span>
              </span>
              <span class="text-xs text-[var(--color-ink-muted)]">
                {t('intel.case.linked', { people: record.personCount ?? 0, orgs: record.orgCount ?? 0 })}
              </span>
            </button>
          </li>
          {/if}
        {/each}
      </ul>
    {/if}
  </section>

  <section class="min-h-0 flex-1 overflow-y-auto border border-[var(--color-border)] p-3 text-xs">
    {#if detailError}
      <p class="border border-[var(--color-border)] px-3 py-2 text-sm">{t(`error.${detailError}`)}</p>
    {:else if !detail}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('intel.case.empty')}</p>
    {:else}
      {@const record = detail.case}

      <div class="flex items-start justify-between gap-3">
        <div>
          {#if record.number}
            <p class="font-[family-name:var(--font-mono)] text-xs text-[var(--color-ink-muted)]">
              {record.number}
            </p>
          {/if}
          <h2 class="text-sm font-semibold">{record.title}</h2>
        </div>
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
            <span class="text-[var(--color-ink-muted)]">{t('intel.case.title')}</span>
            <input
              type="text"
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={editForm.title}
            />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-[var(--color-ink-muted)]">{t('intel.case.description')}</span>
            <textarea
              rows="2"
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={editForm.description}
            ></textarea>
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-[var(--color-ink-muted)]">{t('intel.case.status')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={editForm.status}
            >
              {#each INTEL_CASE_STATUSES as value (value)}
                <option {value}>{t(`intel.caseStatus.${value}`)}</option>
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
          <span>{t(`intel.caseStatus.${record.status}`)}</span>
          <span>{t(`records.classification.${record.classification}`)}</span>
        </div>
        {#if record.description}
          <p class="mt-2">{record.description}</p>
        {/if}
      {/if}

      {#if confirmingDelete}
        <div class="mt-2">
          <ConfirmDialog
            label={t('intel.action.delete')}
            question={t('intel.case.deleteConfirm', { title: record.title })}
            {busy}
            {failure}
            fieldLabels={FIELD_LABELS}
            confirm={() => void remove()}
            cancel={cancelDelete}
          />
        </div>
      {/if}

      <!-- Links -->
      <h3 class="mt-4 font-semibold">{t('intel.case.links')}</h3>
      {#if detail.links.length === 0}
        <p class="mt-1 text-[var(--color-ink-muted)]">{t('intel.case.noLinks')}</p>
      {:else}
        <ul class="mt-1 flex flex-col">
          {#each detail.links as link (link.id)}
            <li class="flex items-center justify-between gap-2 border-b border-[var(--color-border)] py-1 last:border-b-0">
              <span>
                <span class="text-[var(--color-ink-muted)]">
                  {t(link.targetKind === 'person' ? 'intel.case.linkPerson' : 'intel.case.linkOrg')}
                </span>
                {linkLabel(link)}
                {#if link.role}
                  <span class="text-[var(--color-ink-muted)]"> — {link.role}</span>
                {/if}
              </span>
              <button
                type="button"
                class="border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-surface)]"
                onclick={() => void removeLink(link.id)}
              >
                {t('intel.action.remove')}
              </button>
            </li>
          {/each}
        </ul>
      {/if}
      <form class="mt-1 flex flex-wrap items-end gap-2" onsubmit={addLink}>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.case.linkKind')}</span>
          <select
            class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={linkForm.kind}
            onchange={onLinkKindChange}
          >
            {#each LINK_KINDS as kind (kind)}
              <option value={kind}>{t(kind === 'person' ? 'intel.case.linkPerson' : 'intel.case.linkOrg')}</option>
            {/each}
          </select>
        </label>
        <label class="flex w-56 flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.case.linkId')}</span>
          {#key linkForm.kind}
            <EntityPicker
              placeholder={t('intel.case.linkSearchPlaceholder')}
              search={searchLinkTargets}
              label={(target) => target.label}
              getKey={(target) => target.id}
              selectedLabel={linkForm.targetName || null}
              onSelect={(target) => {
                linkForm.targetId = String(target.id);
                linkForm.targetName = target.label;
              }}
              onClear={() => {
                linkForm.targetId = '';
                linkForm.targetName = '';
              }}
            />
          {/key}
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-[var(--color-ink-muted)]">{t('intel.case.linkRole')}</span>
          <input
            type="text"
            class="w-32 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
            bind:value={linkForm.role}
          />
        </label>
        <button type="submit" class="border border-[var(--color-border)] px-3 py-1 hover:bg-[var(--color-surface)]" disabled={busy}>
          {t('intel.case.addLink')}
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
