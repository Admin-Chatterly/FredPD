<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { layoutGraph } from '../../lib/graphLayout';
  import { type Failure } from '../shared/failure';

  /**
   * The link diagram (spec 10.6), after PD-Span's `/board`: people and
   * organisations as nodes, memberships and associations as lines. Scoped to
   * everything, one case or one organisation, because a board of a whole
   * server is unreadable.
   *
   * Every node is one the server's access filter let through, and every line
   * joins two of them; nothing here decides what may be seen. Each node is a
   * button: Tab walks the board, Enter opens the record.
   */

  interface BoardPerson {
    id: number;
    name?: string | null;
    alias?: string | null;
    status: string;
  }

  interface BoardOrg {
    id: number;
    name: string;
    type?: string | null;
    status: string;
  }

  interface Board {
    persons: BoardPerson[];
    orgs: BoardOrg[];
    memberships: { personId: number; orgId: number; role?: string | null; isConfirmed: boolean }[];
    associates: { personId: number; associateId: number; relationship?: string | null; isConfirmed: boolean }[];
    truncated: boolean;
  }

  interface Props {
    onOpenPerson: (id: number) => void;
    onOpenOrg: (id: number) => void;
  }

  let { onOpenPerson, onOpenOrg }: Props = $props();

  let scope = $state('all');
  let cases = $state<{ id: number; number?: string | null; title: string }[]>([]);
  let orgOptions = $state<{ id: number; name: string }[]>([]);
  let board = $state<Board | null>(null);
  let failure = $state<Failure | null>(null);

  /** Pan and zoom, as a view box over the laid-out board. */
  let zoom = $state(1);
  let pan = $state({ x: 0, y: 0 });
  let dragging: { x: number; y: number } | null = null;

  const NODE_W = 150;
  const NODE_H = 40;

  async function loadScopes(): Promise<void> {
    const [caseList, orgList] = await Promise.all([
      nui.call<{ cases: { id: number; number?: string | null; title: string }[] }>('intel.case.list', { limit: 100 }),
      nui.call<{ orgs: { id: number; name: string }[] }>('intel.org.list', { limit: 100 }),
    ]);
    if (caseList.ok) cases = caseList.data.cases;
    if (orgList.ok) orgOptions = orgList.data.orgs;
  }

  async function load(): Promise<void> {
    const [kind, id] = scope.split(':');
    const response = await nui.call<Board>('intel.board', id ? { scope: kind, id: Number(id) } : { scope: 'all' });

    if (response.ok) {
      board = response.data;
      failure = null;
    } else {
      board = null;
      failure = response;
    }
    zoom = 1;
    pan = { x: 0, y: 0 };
  }

  void loadScopes();

  $effect(() => {
    void scope;
    void load();
  });

  /** Node ids on the diagram: people and organisations share one layout. */
  const personKey = (id: number): string => `p${id}`;
  const orgKey = (id: number): string => `o${id}`;

  const layout = $derived.by(() => {
    if (!board) return null;

    const nodes = [
      ...board.persons.map((person) => ({ id: personKey(person.id) })),
      ...board.orgs.map((org) => ({ id: orgKey(org.id) })),
    ];
    const links = [
      ...board.memberships.map((edge) => ({ source: personKey(edge.personId), target: orgKey(edge.orgId) })),
      ...board.associates.map((edge) => ({ source: personKey(edge.personId), target: personKey(edge.associateId) })),
    ];
    const positions = layoutGraph(nodes, links);

    let minX = Infinity;
    let minY = Infinity;
    let maxX = -Infinity;
    let maxY = -Infinity;
    for (const { x, y } of positions.values()) {
      minX = Math.min(minX, x);
      minY = Math.min(minY, y);
      maxX = Math.max(maxX, x);
      maxY = Math.max(maxY, y);
    }
    if (positions.size === 0) {
      minX = minY = -100;
      maxX = maxY = 100;
    }

    const pad = NODE_W;
    return {
      positions,
      box: { x: minX - pad, y: minY - pad, w: maxX - minX + pad * 2, h: maxY - minY + pad * 2 },
    };
  });

  const viewBox = $derived.by(() => {
    if (!layout) return '0 0 100 100';
    const { box } = layout;
    const w = box.w / zoom;
    const h = box.h / zoom;
    const x = box.x + (box.w - w) / 2 + pan.x;
    const y = box.y + (box.h - h) / 2 + pan.y;
    return `${x} ${y} ${w} ${h}`;
  });

  function at(key: string): { x: number; y: number } {
    return layout?.positions.get(key) ?? { x: 0, y: 0 };
  }

  function personLabel(person: BoardPerson): string {
    return person.name || person.alias || t('intel.person.unknown');
  }

  function zoomBy(factor: number): void {
    zoom = Math.min(6, Math.max(0.25, zoom * factor));
  }

  function onWheel(event: WheelEvent): void {
    event.preventDefault();
    zoomBy(event.deltaY < 0 ? 1.15 : 1 / 1.15);
  }

  function onPointerDown(event: PointerEvent): void {
    if ((event.target as Element).closest('[data-node]')) return;
    dragging = { x: event.clientX, y: event.clientY };
    (event.currentTarget as Element).setPointerCapture(event.pointerId);
  }

  function onPointerMove(event: PointerEvent): void {
    if (!dragging || !layout) return;
    const svg = event.currentTarget as SVGSVGElement;
    const scale = layout.box.w / zoom / Math.max(1, svg.clientWidth);
    pan = { x: pan.x - (event.clientX - dragging.x) * scale, y: pan.y - (event.clientY - dragging.y) * scale };
    dragging = { x: event.clientX, y: event.clientY };
  }

  function onPointerUp(): void {
    dragging = null;
  }

  function activate(event: KeyboardEvent, open: () => void): void {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      open();
    }
  }

  const control =
    'border border-[var(--color-border)] px-2 py-1 focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]';
</script>

<section class="flex min-h-0 flex-1 flex-col gap-2" aria-labelledby="intel-board-title">
  <div class="flex flex-wrap items-end justify-between gap-2">
    <div>
      <h2 id="intel-board-title" class="text-sm font-semibold">{t('intel.board.title')}</h2>
      {#if board}
        <p class="text-xs text-[var(--color-ink-muted)]" role="status">
          {t('intel.board.counts', {
            nodes: board.persons.length + board.orgs.length,
            links: board.memberships.length + board.associates.length,
          })}
          {#if board.truncated}
            — {t('intel.board.truncated')}
          {/if}
        </p>
      {/if}
    </div>

    <div class="flex flex-wrap items-end gap-2 text-xs">
      <label class="flex flex-col gap-1">
        {t('intel.board.scope')}
        <select bind:value={scope} class={control}>
          <option value="all">{t('intel.board.everything')}</option>
          {#if cases.length > 0}
            <optgroup label={t('intel.tab.cases')}>
              {#each cases as item (item.id)}
                <option value={`case:${item.id}`}>{item.number ? `${item.number} — ${item.title}` : item.title}</option>
              {/each}
            </optgroup>
          {/if}
          {#if orgOptions.length > 0}
            <optgroup label={t('intel.tab.orgs')}>
              {#each orgOptions as item (item.id)}
                <option value={`org:${item.id}`}>{item.name}</option>
              {/each}
            </optgroup>
          {/if}
        </select>
      </label>
      <button type="button" class={control} aria-label={t('intel.board.zoomIn')} onclick={() => zoomBy(1.25)}>+</button>
      <button type="button" class={control} aria-label={t('intel.board.zoomOut')} onclick={() => zoomBy(0.8)}>−</button>
      <button
        type="button"
        class={control}
        onclick={() => {
          zoom = 1;
          pan = { x: 0, y: 0 };
        }}
      >
        {t('intel.board.reset')}
      </button>
    </div>
  </div>

  {#if failure}
    <div class="border border-[var(--color-alert)] px-2 py-1 text-xs" role="alert">
      <p>{t(`error.${failure.err}`)}</p>
    </div>
  {/if}

  {#if board && layout}
    {#if board.persons.length + board.orgs.length === 0}
      <p class="text-xs text-[var(--color-ink-muted)]">{t('intel.board.empty')}</p>
    {:else}
      <svg
        class="min-h-[360px] w-full flex-1 touch-none border border-[var(--color-border)] bg-[var(--color-surface)]"
        viewBox={viewBox}
        role="group"
        aria-label={t('intel.board.title')}
        onwheel={onWheel}
        onpointerdown={onPointerDown}
        onpointermove={onPointerMove}
        onpointerup={onPointerUp}
        onpointercancel={onPointerUp}
      >
        <g>
          {#each board.memberships as edge (`m${edge.personId}-${edge.orgId}`)}
            {@const from = at(personKey(edge.personId))}
            {@const to = at(orgKey(edge.orgId))}
            <line
              x1={from.x}
              y1={from.y}
              x2={to.x}
              y2={to.y}
              stroke="var(--color-ink-muted)"
              stroke-width="2"
              stroke-dasharray={edge.isConfirmed ? undefined : '8 6'}
            />
          {/each}
          {#each board.associates as edge (`a${edge.personId}-${edge.associateId}`)}
            {@const from = at(personKey(edge.personId))}
            {@const to = at(personKey(edge.associateId))}
            <line
              x1={from.x}
              y1={from.y}
              x2={to.x}
              y2={to.y}
              stroke="var(--color-accent)"
              stroke-width="2"
              stroke-dasharray={edge.isConfirmed ? undefined : '8 6'}
            />
          {/each}
        </g>

        {#each board.orgs as org (org.id)}
          {@const p = at(orgKey(org.id))}
          <g
            data-node
            role="button"
            tabindex="0"
            aria-label={t('intel.board.openOrg', { name: org.name })}
            class="cursor-pointer outline-none [&:focus-visible>rect]:stroke-[var(--color-focus)] [&:focus-visible>rect]:[stroke-width:4]"
            onclick={() => onOpenOrg(org.id)}
            onkeydown={(event) => activate(event, () => onOpenOrg(org.id))}
          >
            <rect
              x={p.x - NODE_W / 2}
              y={p.y - NODE_H / 2}
              width={NODE_W}
              height={NODE_H}
              rx={NODE_H / 2}
              fill="var(--color-panel)"
              stroke="var(--color-accent)"
              stroke-width="2"
            />
            <text x={p.x} y={p.y + 5} text-anchor="middle" font-size="14" font-weight="600" fill="var(--color-ink)">
              {org.name.length > 18 ? `${org.name.slice(0, 17)}…` : org.name}
            </text>
          </g>
        {/each}

        {#each board.persons as person (person.id)}
          {@const p = at(personKey(person.id))}
          {@const label = personLabel(person)}
          <g
            data-node
            role="button"
            tabindex="0"
            aria-label={t('intel.board.openPerson', { name: label })}
            class="cursor-pointer outline-none [&:focus-visible>rect]:stroke-[var(--color-focus)] [&:focus-visible>rect]:[stroke-width:4]"
            onclick={() => onOpenPerson(person.id)}
            onkeydown={(event) => activate(event, () => onOpenPerson(person.id))}
          >
            <rect
              x={p.x - NODE_W / 2}
              y={p.y - NODE_H / 2}
              width={NODE_W}
              height={NODE_H}
              rx="3"
              fill="var(--color-panel)"
              stroke="var(--color-ink)"
              stroke-width="1.5"
            />
            <text x={p.x} y={p.y + 5} text-anchor="middle" font-size="14" fill="var(--color-ink)">
              {label.length > 18 ? `${label.slice(0, 17)}…` : label}
            </text>
          </g>
        {/each}
      </svg>

      <ul class="flex flex-wrap gap-4 text-xs text-[var(--color-ink-muted)]" aria-label={t('intel.board.legend')}>
        <li class="flex items-center gap-1">
          <svg width="22" height="12" aria-hidden="true"><rect x="1" y="1" width="20" height="10" rx="1" fill="none" stroke="var(--color-ink)" /></svg>
          {t('intel.board.person')}
        </li>
        <li class="flex items-center gap-1">
          <svg width="22" height="12" aria-hidden="true"><rect x="1" y="1" width="20" height="10" rx="5" fill="none" stroke="var(--color-accent)" stroke-width="2" /></svg>
          {t('intel.board.org')}
        </li>
        <li class="flex items-center gap-1">
          <svg width="22" height="12" aria-hidden="true"><line x1="0" y1="6" x2="22" y2="6" stroke="var(--color-ink-muted)" stroke-width="2" /></svg>
          {t('intel.board.membership')}
        </li>
        <li class="flex items-center gap-1">
          <svg width="22" height="12" aria-hidden="true"><line x1="0" y1="6" x2="22" y2="6" stroke="var(--color-accent)" stroke-width="2" /></svg>
          {t('intel.board.associate')}
        </li>
        <li class="flex items-center gap-1">
          <svg width="22" height="12" aria-hidden="true"><line x1="0" y1="6" x2="22" y2="6" stroke="var(--color-ink-muted)" stroke-width="2" stroke-dasharray="5 3" /></svg>
          {t('intel.board.unconfirmed')}
        </li>
      </ul>
    {/if}
  {/if}
</section>
