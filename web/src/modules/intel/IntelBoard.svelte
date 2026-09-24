<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { BOX_H, BOX_W, layoutGraph } from '../../lib/graphLayout';
  import { type Failure } from '../shared/failure';
  import { isStub, type Maybe } from '../records/types';

  /**
   * The link diagram (spec 10.6), after PD-Span's `/board`: people and
   * organisations as nodes, memberships and associations as lines. Scoped to
   * everything, one case or one organisation, because a board of a whole
   * server is unreadable.
   *
   * Every node is one the server's access filter let through, and every line
   * joins two of them; nothing here decides what may be seen.
   *
   * Keyboard (6.4): Tab walks the nodes top to bottom, Enter or Space opens
   * one, a focused node is brought into view, the arrow keys move the view and
   * + and − zoom. The wheel zooms only with Ctrl held, so it still scrolls the
   * page everywhere else.
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

  interface Node {
    key: string;
    kind: 'person' | 'org';
    id: number;
    label: string;
    x: number;
    y: number;
  }

  interface Edge {
    key: string;
    x1: number;
    y1: number;
    x2: number;
    y2: number;
    kind: 'membership' | 'associate';
    confirmed: boolean;
    title: string;
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
  let width = $state(0);
  let dragging: { x: number; y: number } | null = null;

  async function loadScopes(): Promise<void> {
    const [caseList, orgList] = await Promise.all([
      nui.call<{ cases: Maybe<{ id: number; number?: string | null; title: string }>[] }>('intel.case.list', {
        limit: 100,
      }),
      nui.call<{ orgs: Maybe<{ id: number; name: string }>[] }>('intel.org.list', { limit: 100 }),
    ]);
    // A stub has no board to show: only what this reader may open is offered.
    if (caseList.ok) cases = caseList.data.cases.flatMap((row) => (isStub(row) ? [] : [row]));
    if (orgList.ok) orgOptions = orgList.data.orgs.flatMap((row) => (isStub(row) ? [] : [row]));
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
    resetView();
  }

  void loadScopes();

  $effect(() => {
    void scope;
    void load();
  });

  function personLabel(person: BoardPerson): string {
    return person.name || person.alias || t('intel.person.unknown');
  }

  const layout = $derived.by(() => {
    if (!board) return null;

    const personKey = (id: number): string => `p${id}`;
    const orgKey = (id: number): string => `o${id}`;

    const positions = layoutGraph(
      [
        ...board.persons.map((person) => ({ id: personKey(person.id) })),
        ...board.orgs.map((org) => ({ id: orgKey(org.id) })),
      ],
      [
        ...board.memberships.map((edge) => ({ source: personKey(edge.personId), target: orgKey(edge.orgId) })),
        ...board.associates.map((edge) => ({ source: personKey(edge.personId), target: personKey(edge.associateId) })),
      ],
    );

    const nodes: Node[] = [];
    for (const person of board.persons) {
      const at = positions.get(personKey(person.id));
      if (at) nodes.push({ key: personKey(person.id), kind: 'person', id: person.id, label: personLabel(person), ...at });
    }
    for (const org of board.orgs) {
      const at = positions.get(orgKey(org.id));
      if (at) nodes.push({ key: orgKey(org.id), kind: 'org', id: org.id, label: org.name, ...at });
    }
    // Tab follows the picture: top to bottom, then left to right.
    nodes.sort((a, b) => a.y - b.y || a.x - b.x);

    const edges: Edge[] = [];
    const titled = (label: string, confirmed: boolean): string =>
      confirmed ? label : t('intel.board.linkUnconfirmed', { label });

    for (const edge of board.memberships) {
      const from = positions.get(personKey(edge.personId));
      const to = positions.get(orgKey(edge.orgId));
      // A line whose ends are not both drawn is not drawn either.
      if (!from || !to) continue;
      edges.push({
        key: `m${edge.personId}-${edge.orgId}`,
        x1: from.x,
        y1: from.y,
        x2: to.x,
        y2: to.y,
        kind: 'membership',
        confirmed: edge.isConfirmed,
        title: titled(edge.role || t('intel.board.membership'), edge.isConfirmed),
      });
    }
    for (const edge of board.associates) {
      const from = positions.get(personKey(edge.personId));
      const to = positions.get(personKey(edge.associateId));
      if (!from || !to) continue;
      edges.push({
        key: `a${edge.personId}-${edge.associateId}`,
        x1: from.x,
        y1: from.y,
        x2: to.x,
        y2: to.y,
        kind: 'associate',
        confirmed: edge.isConfirmed,
        title: titled(edge.relationship || t('intel.board.associate'), edge.isConfirmed),
      });
    }

    let minX = Infinity;
    let minY = Infinity;
    let maxX = -Infinity;
    let maxY = -Infinity;
    for (const node of nodes) {
      minX = Math.min(minX, node.x);
      minY = Math.min(minY, node.y);
      maxX = Math.max(maxX, node.x);
      maxY = Math.max(maxY, node.y);
    }
    if (nodes.length === 0) {
      minX = minY = -100;
      maxX = maxY = 100;
    }

    const pad = BOX_W;
    return {
      nodes,
      edges,
      box: { x: minX - pad, y: minY - pad, w: maxX - minX + pad * 2, h: maxY - minY + pad * 2 },
    };
  });

  /**
   * The zoom a board opens at: the whole board when it fits readably, and
   * otherwise close enough that a board unit is never much under a pixel --
   * a label drawn at three pixels is not a label.
   */
  const readableZoom = $derived(layout && width > 0 ? Math.max(1, (0.9 * layout.box.w) / width) : 1);

  function resetView(): void {
    zoom = readableZoom;
    pan = { x: 0, y: 0 };
  }

  // A new layout, or the first measurement of the frame, opens readably.
  $effect(() => {
    void layout;
    void width;
    resetView();
  });

  const view = $derived.by(() => {
    if (!layout) return { x: 0, y: 0, w: 100, h: 100 };
    const { box } = layout;
    const w = box.w / zoom;
    const h = box.h / zoom;
    return { x: box.x + (box.w - w) / 2 + pan.x, y: box.y + (box.h - h) / 2 + pan.y, w, h };
  });

  function zoomBy(factor: number): void {
    zoom = Math.min(8, Math.max(0.25, zoom * factor));
  }

  function panBy(dx: number, dy: number): void {
    pan = { x: pan.x + dx, y: pan.y + dy };
  }

  /** Brings a focused node into view when it is outside it. */
  function reveal(node: Node): void {
    if (!layout) return;
    const inside =
      node.x - BOX_W / 2 >= view.x &&
      node.x + BOX_W / 2 <= view.x + view.w &&
      node.y - BOX_H / 2 >= view.y &&
      node.y + BOX_H / 2 <= view.y + view.h;
    if (inside) return;

    const { box } = layout;
    pan = { x: node.x - (box.x + box.w / 2), y: node.y - (box.y + box.h / 2) };
  }

  function onWheel(event: WheelEvent): void {
    if (!event.ctrlKey) return;
    event.preventDefault();
    zoomBy(event.deltaY < 0 ? 1.15 : 1 / 1.15);
  }

  function onKeydown(event: KeyboardEvent): void {
    const step = view.w / 10;
    const moves: Record<string, [number, number]> = {
      ArrowLeft: [-step, 0],
      ArrowRight: [step, 0],
      ArrowUp: [0, -step],
      ArrowDown: [0, step],
    };
    const move = moves[event.key];
    if (move) {
      event.preventDefault();
      panBy(move[0], move[1]);
    } else if (event.key === '+' || event.key === '=') {
      event.preventDefault();
      zoomBy(1.25);
    } else if (event.key === '-') {
      event.preventDefault();
      zoomBy(0.8);
    }
  }

  function onPointerDown(event: PointerEvent): void {
    if ((event.target as Element).closest('[data-node]')) return;
    dragging = { x: event.clientX, y: event.clientY };
    (event.currentTarget as Element).setPointerCapture(event.pointerId);
  }

  function onPointerMove(event: PointerEvent): void {
    if (!dragging || !layout) return;
    const scale = view.w / Math.max(1, width);
    panBy(-(event.clientX - dragging.x) * scale, -(event.clientY - dragging.y) * scale);
    dragging = { x: event.clientX, y: event.clientY };
  }

  function onPointerUp(): void {
    dragging = null;
  }

  function open(node: Node): void {
    if (node.kind === 'person') onOpenPerson(node.id);
    else onOpenOrg(node.id);
  }

  function activate(event: KeyboardEvent, node: Node): void {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      open(node);
    }
  }

  function short(label: string): string {
    return label.length > 18 ? `${label.slice(0, 17)}…` : label;
  }

  const control =
    'border border-[var(--color-border)] px-2 py-1 focus-visible:outline-2 focus-visible:outline-[var(--color-focus)]';
</script>

<section class="flex min-h-0 flex-1 flex-col gap-2" aria-labelledby="intel-board-title">
  <div class="flex flex-wrap items-end justify-between gap-2">
    <div>
      <h2 id="intel-board-title" class="text-[15px] font-semibold">{t('intel.board.title')}</h2>
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
      <button type="button" class={control} aria-label={t('intel.board.zoomIn')} onclick={() => zoomBy(1.25)}>
        <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.5">
          <circle cx="7" cy="7" r="5" /><path d="M5 7h4M7 5v4M11 11l3.5 3.5" />
        </svg>
      </button>
      <button type="button" class={control} aria-label={t('intel.board.zoomOut')} onclick={() => zoomBy(0.8)}>
        <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.5">
          <circle cx="7" cy="7" r="5" /><path d="M5 7h4M11 11l3.5 3.5" />
        </svg>
      </button>
      <button type="button" class={control} onclick={resetView}>{t('intel.board.reset')}</button>
    </div>
  </div>

  {#if failure}
    <div class="border border-[var(--color-alert)] px-2 py-1 text-xs" role="alert">
      <p>{t(`error.${failure.err}`)}</p>
    </div>
  {/if}

  {#if board && layout}
    {#if layout.nodes.length === 0}
      <p class="text-xs text-[var(--color-ink-muted)]">{t('intel.board.empty')}</p>
    {:else}
      <p class="text-xs text-[var(--color-ink-muted)]">{t('intel.board.keys')}</p>
      <!--
        The frame takes the room the workspace has and no more: the SVG fills
        it absolutely, so a tall board never pushes the legend off screen.
      -->
      <div class="relative min-h-[240px] flex-1" bind:clientWidth={width}>
        <!-- The group pans and zooms for the keys and pointer its nodes hand up;
             the nodes are the controls. -->
        <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
        <svg
          class="absolute inset-0 h-full w-full touch-none border border-[var(--color-border)] bg-[var(--color-surface)]"
          viewBox={`${view.x} ${view.y} ${view.w} ${view.h}`}
          role="group"
          aria-label={t('intel.board.title')}
          onwheel={onWheel}
          onkeydown={onKeydown}
          onpointerdown={onPointerDown}
          onpointermove={onPointerMove}
          onpointerup={onPointerUp}
          onpointercancel={onPointerUp}
        >
          {#each layout.edges as edge (edge.key)}
            <line
              x1={edge.x1}
              y1={edge.y1}
              x2={edge.x2}
              y2={edge.y2}
              stroke={edge.kind === 'associate' ? 'var(--color-accent)' : 'var(--color-ink-muted)'}
              stroke-width="2"
              stroke-dasharray={edge.confirmed ? undefined : '8 6'}
              vector-effect="non-scaling-stroke"
            >
              <title>{edge.title}</title>
            </line>
          {/each}

          {#each layout.nodes as node (node.key)}
            <g
              data-node
              role="button"
              tabindex="0"
              aria-label={t(node.kind === 'person' ? 'intel.board.openPerson' : 'intel.board.openOrg', {
                name: node.label,
              })}
              class="board-node cursor-pointer outline-none"
              onclick={() => open(node)}
              onkeydown={(event) => activate(event, node)}
              onfocus={() => reveal(node)}
            >
              <title>{node.label}</title>
              <rect
                class="focus-ring"
                x={node.x - BOX_W / 2 - 6}
                y={node.y - BOX_H / 2 - 6}
                width={BOX_W + 12}
                height={BOX_H + 12}
                rx="4"
                fill="none"
                stroke="var(--color-focus)"
                stroke-width="3"
                vector-effect="non-scaling-stroke"
              />
              <rect
                x={node.x - BOX_W / 2}
                y={node.y - BOX_H / 2}
                width={BOX_W}
                height={BOX_H}
                rx={node.kind === 'org' ? BOX_H / 2 : 3}
                fill="var(--color-panel)"
                stroke={node.kind === 'org' ? 'var(--color-accent)' : 'var(--color-ink)'}
                stroke-width={node.kind === 'org' ? 2 : 1.5}
                vector-effect="non-scaling-stroke"
              />
              <text
                x={node.x}
                y={node.y + 5}
                text-anchor="middle"
                font-size="14"
                font-weight={node.kind === 'org' ? 600 : 400}
                fill="var(--color-ink)"
              >
                {short(node.label)}
              </text>
            </g>
          {/each}
        </svg>
      </div>

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

<style>
  /* The focus ring is its own shape outside the node, in the focus colour at a
     width that does not shrink with the zoom (6.7: visible focus). */
  .board-node .focus-ring {
    display: none;
  }

  .board-node:focus-visible .focus-ring {
    display: inline;
  }
</style>
