<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { formatMoment } from '../../lib/time';
  import { fieldList, type Failure } from '../shared/failure';
  import ConfirmDialog from '../shared/ConfirmDialog.svelte';
  import { isStub, type Maybe, type Restricted } from '../records/types';

  /**
   * Personnel: roster detail, shift log, equipment, certifications and the
   * disciplinary file (spec 7.22-7.24).
   *
   * Rank is never shown as a permission: `discordRoles` is display only
   * (invariant 2) and this screen never lets a session change it — hire,
   * promote and demote are Discord role actions the gateway does not build
   * yet (see `0017_personnel.sql`'s header), so this screen edits the roster
   * label fields FredPD actually owns.
   */

  interface Equipment {
    id: number;
    itemKey: string;
    serial?: string | null;
    assignedAt: number;
    returnedAt?: number | null;
  }

  interface Certification {
    id: number;
    certKey: string;
    issuedAt: number;
    expiresAt?: number | null;
    revokedAt?: number | null;
  }

  interface ShiftEntry {
    id: number;
    startedAt: number;
    endedAt?: number | null;
  }

  /** A named, catalogue-level equipment set (0026) -- distinct from
   *  `Equipment`, which is one physical item actually issued. */
  interface Loadout {
    id: number;
    name: string;
    itemKeys?: string[];
  }

  interface Officer {
    id: number;
    discordId: string;
    callsign?: string | null;
    badgeNumber?: string | null;
    division?: string | null;
    name?: string | null;
    active: boolean;
    discordRoles?: string[];
    equipment?: Equipment[];
    certifications?: Certification[];
    shiftLog?: ShiftEntry[];
    openShift?: ShiftEntry | null;
    /** Resolved server-side from `loadout_id` (0026) -- never a name to
     *  trust from the client, only one to display. */
    loadout?: { id: number; name: string } | null;
  }

  interface DisciplineCase {
    id: number;
    number: string;
    category: string;
    summary: string;
    createdAt: number;
    closedAt?: number | null;
    outcomeKey?: string | null;
    version: number;
  }

  const EQUIPMENT_ITEMS = [
    'sidearm', 'taser', 'vest', 'radio', 'bodycam', 'laptop', 'less_lethal', 'other',
  ];
  const CERTIFICATIONS = [
    'fto', 'firearms_instructor', 'evoc', 'k9_handler', 'swat', 'crisis_negotiator',
    'motor_unit', 'air_unit', 'field_training', 'breach',
  ];
  const DISCIPLINE_CATEGORIES = [
    'conduct', 'use_of_force', 'policy', 'performance', 'complaint_external',
  ];
  const DISCIPLINE_OUTCOMES = [
    'unfounded', 'exonerated', 'sustained_counseled', 'sustained_written',
    'sustained_suspension', 'sustained_termination',
  ];

  const FIELD_LABELS: Record<string, string> = {
    badgeNumber: 'personnel.field.badgeNumber',
    division: 'personnel.field.division',
    itemKey: 'personnel.equipment.itemChoose',
    certKey: 'personnel.certification.choose',
    category: 'personnel.discipline.categoryChoose',
    summary: 'personnel.discipline.summary',
    outcomeKey: 'personnel.discipline.outcomeChoose',
    name: 'personnel.loadout.name',
    itemKeys: 'personnel.loadout.items',
    loadoutId: 'personnel.loadout.choose',
  };

  let rows = $state<Officer[]>([]);
  let detail = $state<Officer | null>(null);
  let discipline = $state<DisciplineCase[] | null>(null);
  let failure = $state<Failure | null>(null);
  let busy = $state(false);
  let activeOnly = $state(true);
  let status = $state('');

  let editForm = $state({ badgeNumber: '', division: '' });
  let equipmentForm = $state({ itemKey: EQUIPMENT_ITEMS[0], serial: '' });
  let certForm = $state({ certKey: CERTIFICATIONS[0] });
  let disciplineForm = $state({ category: DISCIPLINE_CATEGORIES[0], summary: '' });

  // -------------------------------------------------------------- loadouts

  let loadouts = $state<Loadout[]>([]);
  let managingLoadouts = $state(false);
  let loadoutForm = $state({ name: '', itemKeys: [] as string[] });
  let assignLoadoutId = $state('');

  async function loadLoadouts(): Promise<void> {
    const response = await nui.call<{ loadouts: Loadout[] }>('personnel.loadout.list', {});
    if (response.ok) loadouts = response.data.loadouts ?? [];
  }

  async function createLoadout(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (loadoutForm.itemKeys.length === 0) return;

    busy = true;
    const response = await nui.call('personnel.loadout.create', {
      name: loadoutForm.name,
      itemKeys: loadoutForm.itemKeys,
    });

    if (response.ok) {
      failure = null;
      loadoutForm = { name: '', itemKeys: [] };
      await loadLoadouts();
    } else {
      failure = response;
    }

    busy = false;
  }

  async function deleteLoadout(id: number): Promise<void> {
    busy = true;
    const response = await nui.call('personnel.loadout.delete', { id });

    if (response.ok) {
      failure = null;
      await Promise.all([loadLoadouts(), detail ? open(detail.id) : Promise.resolve()]);
    } else {
      failure = response;
    }

    busy = false;
  }

  async function assignLoadout(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail) return;

    busy = true;
    const response = await nui.call('personnel.officer.setLoadout', {
      officerId: detail.id,
      loadoutId: assignLoadoutId ? Number(assignLoadoutId) : undefined,
    });

    if (response.ok) {
      failure = null;
      await open(detail.id);
    } else {
      failure = response;
    }

    busy = false;
  }

  let confirmingDiscipline = $state(false);
  let closingCase = $state<DisciplineCase | null>(null);
  let outcomeKey = $state(DISCIPLINE_OUTCOMES[0]);
  let trigger: HTMLButtonElement | null = null;

  // `personnel.shift.start`/`.end` always act on the caller's own row
  // (`session.officerId` on the server, never an id in the input) -- the
  // shift toggle must only appear on the viewer's own detail, never on a
  // colleague's, or pressing it there would silently clock the viewer on or
  // off while they read someone else's record. `session.get` carries no
  // discord id to the client, so callsign is the only thing here to match on.
  let viewerCallsign = $state<string | null>(null);
  const isSelf = $derived(detail !== null && detail.callsign !== null && detail.callsign === viewerCallsign);

  const messages = $derived(fieldList(failure, FIELD_LABELS));

  function cancelConfirm(): void {
    confirmingDiscipline = false;
    closingCase = null;
    failure = null;
    trigger?.focus();
  }

  async function load(): Promise<void> {
    busy = true;

    const response = await nui.call<{ officers: Officer[] }>('personnel.roster.list', {
      active: activeOnly ? true : undefined,
      limit: 100,
    });

    if (response.ok) {
      rows = response.data.officers ?? [];
      failure = null;
    } else {
      failure = response;
    }

    busy = false;
  }

  async function open(id: number): Promise<void> {
    busy = true;
    discipline = null;

    const response = await nui.call<{ officer: Officer }>('personnel.roster.get', { id });

    if (response.ok) {
      detail = response.data.officer;
      editForm = { badgeNumber: detail.badgeNumber ?? '', division: detail.division ?? '' };
      assignLoadoutId = detail.loadout ? String(detail.loadout.id) : '';
      failure = null;
    } else {
      detail = null;
      failure = response;
    }

    busy = false;
  }

  async function loadDiscipline(): Promise<void> {
    if (!detail) return;

    const response = await nui.call<{ cases: Maybe<DisciplineCase>[] }>('personnel.discipline.list', {
      officerId: detail.id,
    });

    if (response.ok) {
      discipline = (response.data.cases ?? []) as DisciplineCase[];
      failure = null;
    } else {
      failure = response;
    }
  }

  async function saveRoster(): Promise<void> {
    if (!detail) return;

    busy = true;
    const response = await nui.call('personnel.roster.update', {
      id: detail.id,
      badgeNumber: editForm.badgeNumber || undefined,
      division: editForm.division || undefined,
    });

    if (response.ok) {
      failure = null;
      status = t('personnel.saved');
      await Promise.all([open(detail.id), load()]);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function toggleShift(): Promise<void> {
    if (!detail) return;

    busy = true;
    const route = detail.openShift ? 'personnel.shift.end' : 'personnel.shift.start';
    const response = await nui.call(route, {});

    if (response.ok) {
      failure = null;
      await open(detail.id);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function assignEquipment(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail) return;

    busy = true;
    const response = await nui.call('personnel.equipment.assign', {
      officerId: detail.id,
      itemKey: equipmentForm.itemKey,
      serial: equipmentForm.serial || undefined,
    });

    if (response.ok) {
      failure = null;
      equipmentForm = { itemKey: EQUIPMENT_ITEMS[0], serial: '' };
      await open(detail.id);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function returnEquipment(id: number): Promise<void> {
    if (!detail) return;

    busy = true;
    const response = await nui.call('personnel.equipment.return', { id, officerId: detail.id });

    if (response.ok) {
      failure = null;
      await open(detail.id);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function issueCertification(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail) return;

    busy = true;
    const response = await nui.call('personnel.certification.issue', {
      officerId: detail.id,
      certKey: certForm.certKey,
    });

    if (response.ok) {
      failure = null;
      certForm = { certKey: CERTIFICATIONS[0] };
      await open(detail.id);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function revokeCertification(id: number): Promise<void> {
    if (!detail) return;

    busy = true;
    const response = await nui.call('personnel.certification.revoke', { id, officerId: detail.id });

    if (response.ok) {
      failure = null;
      await open(detail.id);
    } else {
      failure = response;
      busy = false;
    }
  }

  async function openDiscipline(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!detail) return;

    busy = true;
    const response = await nui.call('personnel.discipline.open', {
      officerId: detail.id,
      category: disciplineForm.category,
      summary: disciplineForm.summary,
    });

    if (response.ok) {
      failure = null;
      disciplineForm = { category: DISCIPLINE_CATEGORIES[0], summary: '' };
      await loadDiscipline();
    } else {
      failure = response;
    }

    busy = false;
  }

  async function closeDiscipline(): Promise<void> {
    if (!closingCase) return;

    busy = true;
    const response = await nui.call('personnel.discipline.close', {
      id: closingCase.id,
      version: closingCase.version,
      outcomeKey,
    });

    if (response.ok) {
      failure = null;
      confirmingDiscipline = false;
      closingCase = null;
      trigger?.focus();
      await loadDiscipline();
    } else {
      failure = response;
      busy = false;
    }
  }

  function stubContact(row: Restricted): string {
    return t('records.restricted.contact', { unit: t(`access.unit.${row.contact}`) });
  }

  async function loadViewer(): Promise<void> {
    const response = await nui.call<{ callsign: string | null }>('session.get', {});
    if (response.ok) viewerCallsign = response.data.callsign;
  }

  void load();
  void loadViewer();
  void loadLoadouts();
</script>

<div class="flex flex-col gap-3">
  <form
    class="flex flex-wrap items-end gap-2"
    onsubmit={(event) => {
      event.preventDefault();
      void load();
    }}
  >
    <label class="flex items-center gap-1 text-xs">
      <input type="checkbox" bind:checked={activeOnly} onchange={() => void load()} />
      {t('personnel.filter.activeOnly')}
    </label>

    <button
      type="button"
      class="border border-[var(--color-border)] px-3 py-1 text-xs"
      onclick={() => (managingLoadouts = !managingLoadouts)}
    >
      {t('personnel.loadout.manage')}
    </button>
  </form>

  {#if managingLoadouts}
    <div class="border border-[var(--color-border)] p-3">
      <h3 class="mb-1 text-xs font-semibold">{t('personnel.loadout.title')}</h3>
      {#if loadouts.length === 0}
        <p class="mb-2 text-xs text-[var(--color-ink-muted)]">{t('personnel.loadout.none')}</p>
      {:else}
        <ul class="mb-2 text-xs">
          {#each loadouts as loadout (loadout.id)}
            <li class="flex items-center justify-between border-t border-[var(--color-border)] py-1">
              <span>
                {loadout.name}
                {#if loadout.itemKeys}
                  <span class="text-[var(--color-ink-muted)]">
                    — {loadout.itemKeys.map((key) => t(`personnel.equipment.item.${key}`)).join(', ')}
                  </span>
                {/if}
              </span>
              <button
                type="button"
                class="border border-[var(--color-border)] px-2 py-0.5"
                disabled={busy}
                onclick={() => void deleteLoadout(loadout.id)}
              >
                {t('personnel.loadout.delete')}
              </button>
            </li>
          {/each}
        </ul>
      {/if}
      <form class="flex flex-wrap items-end gap-3" onsubmit={createLoadout}>
        <label class="flex flex-col gap-1 text-xs">
          {t('personnel.loadout.name')}
          <input
            bind:value={loadoutForm.name}
            required
            maxlength="191"
            class="border border-[var(--color-border)] px-2 py-1"
          />
        </label>
        <fieldset class="flex flex-col gap-1 text-xs">
          <legend>{t('personnel.loadout.items')}</legend>
          <div class="flex flex-wrap gap-2">
            {#each EQUIPMENT_ITEMS as key (key)}
              <label class="flex items-center gap-1">
                <input type="checkbox" bind:group={loadoutForm.itemKeys} value={key} />
                {t(`personnel.equipment.item.${key}`)}
              </label>
            {/each}
          </div>
        </fieldset>
        <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
          {t('personnel.loadout.create')}
        </button>
      </form>
    </div>
  {/if}

  {#if failure}
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

  <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)]">
    <div class="border border-[var(--color-border)]">
      {#if rows.length === 0}
        <p class="px-3 py-2 text-xs text-[var(--color-ink-muted)]">{t('personnel.empty')}</p>
      {:else}
        <table class="w-full text-xs">
          <thead class="bg-[var(--color-surface)]">
            <tr>
              <th class="px-2 py-1 text-left font-semibold">{t('personnel.column.callsign')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('personnel.column.badge')}</th>
              <th class="px-2 py-1 text-left font-semibold">{t('personnel.column.division')}</th>
            </tr>
          </thead>
          <tbody>
            {#each rows as row (row.id)}
              <tr class="border-t border-[var(--color-border)]">
                <td class="px-2 py-1 whitespace-nowrap">
                  <button
                    type="button"
                    class="underline-offset-2 hover:underline"
                    class:font-semibold={detail?.id === row.id}
                    onclick={() => void open(row.id)}
                  >
                    {row.callsign ?? row.name ?? row.discordId}
                  </button>
                </td>
                <td class="px-2 py-1 font-[family-name:var(--font-mono)]">{row.badgeNumber ?? '—'}</td>
                <td class="px-2 py-1">{row.division ?? '—'}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      {/if}
    </div>

    <div class="border border-[var(--color-border)] p-3">
      {#if !detail}
        <p class="text-xs text-[var(--color-ink-muted)]">{t('personnel.detail.none')}</p>
      {:else}
        <header class="mb-3 flex items-center justify-between">
          <div>
            <h2 class="text-sm font-semibold">{detail.callsign ?? detail.name}</h2>
            {#if detail.discordRoles && detail.discordRoles.length > 0}
              <p class="text-xs text-[var(--color-ink-muted)]">{detail.discordRoles.join(', ')}</p>
            {/if}
          </div>
          {#if isSelf}
            <button
              type="button"
              class="border border-[var(--color-border)] px-3 py-1 text-xs"
              disabled={busy}
              onclick={() => void toggleShift()}
            >
              {detail.openShift ? t('personnel.shift.end') : t('personnel.shift.start')}
            </button>
          {/if}
        </header>

        <form
          class="mb-4 flex flex-wrap items-end gap-2 border-b border-[var(--color-border)] pb-3"
          onsubmit={(event) => {
            event.preventDefault();
            void saveRoster();
          }}
        >
          <label class="flex flex-col gap-1 text-xs">
            {t('personnel.field.badgeNumber')}
            <input bind:value={editForm.badgeNumber} maxlength="16" class="border border-[var(--color-border)] px-2 py-1" />
          </label>
          <label class="flex flex-col gap-1 text-xs">
            {t('personnel.field.division')}
            <input bind:value={editForm.division} maxlength="64" class="border border-[var(--color-border)] px-2 py-1" />
          </label>
          <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
            {t('form.save')}
          </button>
        </form>

        <section class="mb-4">
          <h3 class="mb-1 text-xs font-semibold">{t('personnel.loadout.title')}</h3>
          <p class="mb-2 text-xs text-[var(--color-ink-muted)]">
            {detail.loadout ? detail.loadout.name : t('personnel.loadout.none')}
          </p>
          <!--
            Assigning a loadout here does not issue anything by itself
            (0026): the kit is applied the next time this officer's duty
            state changes, off `fredpd:dutyChanged` -- an officer already on
            duty when their loadout is set or swapped keeps whatever they are
            currently holding until they cycle duty.
          -->
          <form class="flex flex-wrap items-end gap-2" onsubmit={assignLoadout}>
            <label class="flex flex-col gap-1 text-xs">
              {t('personnel.loadout.choose')}
              <select bind:value={assignLoadoutId} class="border border-[var(--color-border)] px-2 py-1">
                <option value="">{t('personnel.loadout.none')}</option>
                {#each loadouts as loadout (loadout.id)}
                  <option value={String(loadout.id)}>{loadout.name}</option>
                {/each}
              </select>
            </label>
            <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
              {t('form.save')}
            </button>
          </form>
        </section>

        <section class="mb-4">
          <h3 class="mb-1 text-xs font-semibold">{t('personnel.equipment.title')}</h3>
          {#if detail.equipment && detail.equipment.length > 0}
            <ul class="mb-2 text-xs">
              {#each detail.equipment as item (item.id)}
                <li class="flex items-center justify-between border-t border-[var(--color-border)] py-1">
                  <span>{t(`personnel.equipment.item.${item.itemKey}`)} {item.serial ? `(${item.serial})` : ''}</span>
                  {#if !item.returnedAt}
                    <button
                      type="button"
                      class="border border-[var(--color-border)] px-2 py-0.5"
                      onclick={() => void returnEquipment(item.id)}
                    >
                      {t('personnel.equipment.return')}
                    </button>
                  {:else}
                    <span class="text-[var(--color-ink-muted)]">{t('personnel.equipment.returned')}</span>
                  {/if}
                </li>
              {/each}
            </ul>
          {/if}
          <form class="flex flex-wrap items-end gap-2" onsubmit={assignEquipment}>
            <label class="flex flex-col gap-1 text-xs">
              {t('personnel.equipment.itemChoose')}
              <select bind:value={equipmentForm.itemKey} class="border border-[var(--color-border)] px-2 py-1">
                {#each EQUIPMENT_ITEMS as key (key)}
                  <option value={key}>{t(`personnel.equipment.item.${key}`)}</option>
                {/each}
              </select>
            </label>
            <label class="flex flex-col gap-1 text-xs">
              {t('personnel.equipment.serial')}
              <input bind:value={equipmentForm.serial} maxlength="64" class="border border-[var(--color-border)] px-2 py-1" />
            </label>
            <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
              {t('personnel.equipment.assign')}
            </button>
          </form>
        </section>

        <section class="mb-4">
          <h3 class="mb-1 text-xs font-semibold">{t('personnel.certification.title')}</h3>
          {#if detail.certifications && detail.certifications.length > 0}
            <ul class="mb-2 text-xs">
              {#each detail.certifications as cert (cert.id)}
                <li class="flex items-center justify-between border-t border-[var(--color-border)] py-1">
                  <span>{t(`personnel.certification.key.${cert.certKey}`)}</span>
                  {#if !cert.revokedAt}
                    <button
                      type="button"
                      class="border border-[var(--color-border)] px-2 py-0.5"
                      onclick={() => void revokeCertification(cert.id)}
                    >
                      {t('personnel.certification.revoke')}
                    </button>
                  {:else}
                    <span class="text-[var(--color-ink-muted)]">{t('personnel.certification.revoked')}</span>
                  {/if}
                </li>
              {/each}
            </ul>
          {/if}
          <form class="flex flex-wrap items-end gap-2" onsubmit={issueCertification}>
            <label class="flex flex-col gap-1 text-xs">
              {t('personnel.certification.choose')}
              <select bind:value={certForm.certKey} class="border border-[var(--color-border)] px-2 py-1">
                {#each CERTIFICATIONS as key (key)}
                  <option value={key}>{t(`personnel.certification.key.${key}`)}</option>
                {/each}
              </select>
            </label>
            <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
              {t('personnel.certification.issue')}
            </button>
          </form>
        </section>

        <section class="border-t border-[var(--color-border)] pt-3">
          <div class="mb-1 flex items-center justify-between">
            <h3 class="text-xs font-semibold">{t('personnel.discipline.title')}</h3>
            {#if discipline === null}
              <button
                type="button"
                class="border border-[var(--color-border)] px-2 py-0.5 text-xs"
                onclick={() => void loadDiscipline()}
              >
                {t('personnel.discipline.reveal')}
              </button>
            {/if}
          </div>

          {#if discipline !== null}
            {#if discipline.length === 0}
              <p class="text-xs text-[var(--color-ink-muted)]">{t('personnel.discipline.empty')}</p>
            {:else}
              <ul class="mb-2 text-xs">
                {#each discipline as item, index (index)}
                  {#if isStub(item)}
                    <li class="border-t border-[var(--color-border)] py-1 text-[var(--color-ink-muted)]">
                      {t('records.restricted.title')} — {stubContact(item)}
                    </li>
                  {:else}
                    <li class="border-t border-[var(--color-border)] py-1">
                      <div class="flex items-center justify-between">
                        <span class="font-[family-name:var(--font-mono)]">{item.number}</span>
                        <span>{t(`personnel.discipline.category.${item.category}`)}</span>
                      </div>
                      <p class="mt-1 text-[var(--color-ink-muted)]">
                        {formatMoment(item.createdAt)}
                      </p>
                      <p class="mt-1 text-[var(--color-ink-muted)]">{item.summary}</p>
                      {#if item.closedAt && item.outcomeKey}
                        <p class="mt-1">{t(`personnel.discipline.outcome.${item.outcomeKey}`)}</p>
                      {:else}
                        <button
                          type="button"
                          class="mt-1 border border-[var(--color-border)] px-2 py-0.5"
                          onclick={(event) => {
                            trigger = event.currentTarget;
                            closingCase = item;
                            outcomeKey = DISCIPLINE_OUTCOMES[0];
                            confirmingDiscipline = true;
                            failure = null;
                          }}
                        >
                          {t('personnel.discipline.close')}
                        </button>
                      {/if}
                    </li>
                  {/if}
                {/each}
              </ul>
            {/if}

            {#if confirmingDiscipline && closingCase}
              <ConfirmDialog
                label={t('personnel.discipline.close')}
                question={t('personnel.discipline.confirmClose')}
                {busy}
                {failure}
                fieldLabels={FIELD_LABELS}
                confirm={() => void closeDiscipline()}
                cancel={cancelConfirm}
              >
                <label class="flex flex-col gap-1 text-xs">
                  {t('personnel.discipline.outcomeChoose')}
                  <select bind:value={outcomeKey} class="border border-[var(--color-border)] px-2 py-1">
                    {#each DISCIPLINE_OUTCOMES as key (key)}
                      <option value={key}>{t(`personnel.discipline.outcome.${key}`)}</option>
                    {/each}
                  </select>
                </label>
              </ConfirmDialog>
            {/if}

            <form class="mt-2 flex flex-wrap items-end gap-2 border-t border-[var(--color-border)] pt-2" onsubmit={openDiscipline}>
              <label class="flex flex-col gap-1 text-xs">
                {t('personnel.discipline.categoryChoose')}
                <select bind:value={disciplineForm.category} class="border border-[var(--color-border)] px-2 py-1">
                  {#each DISCIPLINE_CATEGORIES as key (key)}
                    <option value={key}>{t(`personnel.discipline.category.${key}`)}</option>
                  {/each}
                </select>
              </label>
              <label class="flex flex-1 flex-col gap-1 text-xs">
                {t('personnel.discipline.summary')}
                <input bind:value={disciplineForm.summary} required class="border border-[var(--color-border)] px-2 py-1" />
              </label>
              <button type="submit" class="border border-[var(--color-border)] px-3 py-1 text-xs" disabled={busy}>
                {t('personnel.discipline.open')}
              </button>
            </form>
          {/if}
        </section>
      {/if}
    </div>
  </div>
</div>
