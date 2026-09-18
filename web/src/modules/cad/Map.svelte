<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import type { ErrorCode } from '@fredpd/schema';
  import {
    elapsed,
    oneRowPerUnit,
    priorityInk,
    priorityShort,
    type Beat,
    type Call,
    type Unit,
  } from './Dispatch.svelte';

  /**
   * The live map (spec 7.17): the agency's units, the open calls, and the beat
   * polygons behind them.
   *
   * **It is loaded when it is opened.** The console imports this component
   * dynamically, so the map, and only the map, is a second chunk — budget 12.1
   * caps the initial bundle at 250 KB gzipped and says the map loads on demand.
   *
   * **Positions arrive only while it is open.** `map.view` is the subscription:
   * opening it registers this session with the AVL sweep and answers with the
   * snapshot, closing it unregisters. That is 3.6 ("map positions go out every
   * 1–2 seconds, only to sessions with the map open") and it is why the sweep
   * costs an agency with nobody watching one table lookup a second. The effect
   * below is where the two halves are paired: subscribe on mount, unsubscribe
   * on destroy, and never a poll in between — `fredpd:cad:avl` carries only the
   * units that actually moved.
   *
   * Nothing is drawn here that the server did not send. Every position in the
   * snapshot and in every delta has been through the same access check a read
   * makes (invariants 4 and 5).
   */

  interface Props {
    beats: Beat[];
    now: number;
    /** Opening a call from the map is the console opening its card. */
    onselect: (id: number) => void;
  }

  const { beats, now, onselect }: Props = $props();

  interface Position {
    x: number;
    y: number;
    z?: number;
    heading?: number;
    at?: number;
    gone?: boolean;
  }

  let units = $state<Unit[]>([]);
  /** Where each unit is now, from the sweep. Keyed by `fpd_units.officer_id`. */
  let positions = $state<Record<number, Position>>({});
  let mapCalls = $state<Call[]>([]);

  let subscribed = $state(false);
  let error = $state<ErrorCode | null>(null);
  let loading = $state(true);

  let showUnits = $state(true);
  let showCalls = $state(true);
  let showBeats = $state(true);

  let followOfficerId = $state<number | null>(null);
  let centredCallId = $state<number | null>(null);

  $effect(() => {
    let cancelled = false;

    void (async () => {
      const response = await nui.call<{ subscribed: boolean; units: Unit[]; calls: Call[] }>(
        'map.view',
        { subscribe: true },
      );

      if (cancelled) return;

      if (response.ok) {
        units = oneRowPerUnit(response.data.units);
        mapCalls = response.data.calls;
        subscribed = response.data.subscribed;

        const seeded: Record<number, Position> = {};

        for (const unit of response.data.units) {
          // `typeof`, not `!== null`: a unit the AVL sweep has never seen has
          // no position, the column is NULL, and a NULL reaches the NUI as an
          // absent key -- `undefined`, which `!== null` lets straight through
          // and then draws at NaN.
          if (typeof unit.x === 'number' && typeof unit.y === 'number') {
            seeded[unit.officerId] = {
              x: unit.x,
              y: unit.y,
              ...(unit.positionAtUnix === null ? {} : { at: unit.positionAtUnix }),
            };
          }
        }

        positions = seeded;
        error = null;
      } else {
        error = response.err;
        subscribed = false;
      }

      loading = false;
    })();

    return () => {
      cancelled = true;
      // The close half of the same route: the sweep stops pushing to this
      // session the moment the map leaves the screen.
      void nui.call('map.view', { subscribe: false });
    };
  });

  $effect(() =>
    nui.on('fredpd:cad:avl', (message) => {
      const moved = message['units'] as (Position & { officerId: number })[] | undefined;
      if (!Array.isArray(moved)) return;

      const next = { ...positions };

      for (const entry of moved) {
        // `gone` is how a unit leaves the map: signed off, or no longer
        // connected. It is sent once, so it has to be acted on when it arrives.
        if (entry.gone) delete next[entry.officerId];
        else next[entry.officerId] = entry;
      }

      positions = next;
    }),
  );

  $effect(() =>
    nui.on('fredpd:cad:unit', (message) => {
      const unit = message['unit'] as Unit | undefined;
      if (!unit) return;

      const rest = units.filter((existing) => existing.officerId !== unit.officerId);
      units = unit.status === 'off_duty' ? rest : [...rest, unit];
    }),
  );

  $effect(() =>
    nui.on('fredpd:cad:call', (message) => {
      const incoming = message['call'] as Call | undefined;
      if (!incoming) return;

      const rest = mapCalls.filter((existing) => existing.id !== incoming.id);
      const closed = incoming.status === 'cleared' || incoming.status === 'cancelled';

      // The map holds its own set rather than the queue's: the queue can be
      // filtered down to one beat or to a day's cleared calls, and a map that
      // followed it would go blank while a dispatcher was reading history.
      mapCalls = closed ? rest : [...rest, incoming];
    }),
  );

  const unitMarkers = $derived(
    units
      .map((unit) => {
        const position = positions[unit.officerId];
        if (!position) return null;

        return {
          id: unit.officerId,
          x: position.x,
          y: position.y,
          label: unit.callsign,
          emergency: unit.status === 'emergency',
          // The delta's own stamp when it brought one, and the board row's
          // otherwise: a unit that has not moved since the snapshot still has a
          // position, and it is still as old as the snapshot said.
          at: position.at ?? unit.positionAtUnix,
        };
      })
      .filter((marker) => marker !== null),
  );

  const callMarkers = $derived(
    mapCalls
      // A call raised by address rather than by position has no coordinates,
      // so the key is absent and arrives as `undefined`. See the note above.
      .filter((call): call is Call & { x: number; y: number } =>
        typeof call.x === 'number' && typeof call.y === 'number')
      .map((call) => ({
        id: call.id,
        x: call.x,
        y: call.y,
        label: call.callNumber,
        priority: call.priority,
        emergency: call.source === 'panic',
      })),
  );

  /**
   * The window on the world, in world units.
   *
   * It fits whatever there is to show — the beats, which are the agency's own
   * districts, and anything outside them — rather than assuming a particular
   * city's coordinates. Following a unit or centring on a call narrows it to a
   * fixed span around that point, which is what "follow" means on a console.
   *
   * The Y axis is flipped on the way into the SVG: north is up in the world and
   * down in a viewport.
   */
  const view = $derived.by(() => {
    const followed = followOfficerId === null ? undefined : positions[followOfficerId];
    const centred = centredCallId === null ? undefined : callMarkers.find((call) => call.id === centredCallId);
    const focus = followed ?? centred;

    if (focus) {
      const span = 500;

      return { minX: focus.x - span, minY: focus.y - span, width: span * 2, height: span * 2 };
    }

    const xs: number[] = [];
    const ys: number[] = [];

    if (showBeats) {
      for (const beat of beats) {
        xs.push(beat.minX, beat.maxX);
        ys.push(beat.minY, beat.maxY);
      }
    }

    for (const marker of [...unitMarkers, ...callMarkers]) {
      xs.push(marker.x);
      ys.push(marker.y);
    }

    if (xs.length === 0 || ys.length === 0) {
      return { minX: -4000, minY: -4000, width: 9000, height: 12000 };
    }

    const minX = Math.min(...xs);
    const maxX = Math.max(...xs);
    const minY = Math.min(...ys);
    const maxY = Math.max(...ys);

    // A margin so a unit sitting on the edge of a district is not drawn on the
    // frame, and a floor so a single marker does not fill the viewport.
    const width = Math.max(maxX - minX, 400) * 1.15;
    const height = Math.max(maxY - minY, 400) * 1.15;
    const centreX = (minX + maxX) / 2;
    const centreY = (minY + maxY) / 2;

    return { minX: centreX - width / 2, minY: centreY - height / 2, width, height };
  });

  /** World Y grows north; SVG Y grows down, so the axis is mirrored. */
  function screenY(y: number): number {
    return view.minY + view.height - (y - view.minY);
  }

  function polygonPoints(beat: Beat): string {
    return beat.polygon.map(([x, y]) => `${x},${screenY(y)}`).join(' ');
  }

  function centreOf(beat: Beat): { x: number; y: number } {
    return { x: (beat.minX + beat.maxX) / 2, y: screenY((beat.minY + beat.maxY) / 2) };
  }

  /** Marker sizes in world units, so they keep their size as the window moves. */
  const scale = $derived(Math.max(view.width, view.height) / 120);

  const empty = $derived(unitMarkers.length === 0 && callMarkers.length === 0 && beats.length === 0);
</script>

<section class="flex min-h-0 flex-col gap-2">
  <header class="flex flex-wrap items-center gap-4">
    <h2 class="text-sm font-semibold">{t('cad.map.title')}</h2>

    <label class="flex items-center gap-1.5 text-xs">
      <input type="checkbox" bind:checked={showUnits} />
      <span>{t('cad.map.units')}</span>
    </label>
    <label class="flex items-center gap-1.5 text-xs">
      <input type="checkbox" bind:checked={showCalls} />
      <span>{t('cad.map.calls')}</span>
    </label>
    <label class="flex items-center gap-1.5 text-xs">
      <input type="checkbox" bind:checked={showBeats} />
      <span>{t('cad.map.beats')}</span>
    </label>

  </header>

  {#if error}
    <p class="border border-[var(--color-border)] px-3 py-2 text-sm">{t(`error.${error}`)}</p>
  {/if}

  {#if loading}
    <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
  {:else}
    {#if !subscribed}
      <!-- The subscription is what makes the 1–2 second push legal at all, so a
           map without one is a still picture and says so. -->
      <p class="border border-[var(--color-caution)] px-3 py-1.5 text-xs text-[var(--color-caution)]">
        {t('cad.map.closed')}
      </p>
    {/if}

    {#if empty}
      <p class="border border-[var(--color-border)] px-3 py-2 text-xs text-[var(--color-ink-muted)]">
        {t('cad.map.empty')}
      </p>
    {:else}
      <div class="border border-[var(--color-border)]">
        <svg
          role="img"
          aria-label={t('cad.map.title')}
          class="h-[28rem] w-full bg-[var(--color-surface)]"
          viewBox="{view.minX} {view.minY} {view.width} {view.height}"
          preserveAspectRatio="xMidYMid meet"
        >
          {#if showBeats}
            {#each beats as beat (beat.id)}
              <polygon
                points={polygonPoints(beat)}
                fill="none"
                stroke="var(--color-border)"
                stroke-width={scale / 6}
              />
              <text
                x={centreOf(beat).x}
                y={centreOf(beat).y}
                fill="var(--color-ink-muted)"
                font-size={scale}
                text-anchor="middle"
              >
                {beat.code}
              </text>
            {/each}
          {/if}

          {#if showCalls}
            {#each callMarkers as call (call.id)}
              <!-- A call is a square and a unit is a circle: the two are told
                   apart by shape, not by colour (6.7). -->
              <g
                role="button"
                tabindex="0"
                onclick={() => {
                  centredCallId = call.id;
                  followOfficerId = null;
                  onselect(call.id);
                }}
                onkeydown={(event) => {
                  if (event.key === 'Enter') onselect(call.id);
                }}
              >
                <rect
                  x={call.x - scale / 2}
                  y={screenY(call.y) - scale / 2}
                  width={scale}
                  height={scale}
                  fill={call.priority === 1 ? 'var(--color-alert)' : 'var(--color-caution)'}
                  stroke="var(--color-ink)"
                  stroke-width={scale / 10}
                />
                <text
                  x={call.x + scale}
                  y={screenY(call.y)}
                  fill="var(--color-ink)"
                  font-size={scale}
                >
                  {priorityShort(call.priority)} {call.label}
                </text>
              </g>
            {/each}
          {/if}

          {#if showUnits}
            {#each unitMarkers as unit (unit.id)}
              <g
                role="button"
                tabindex="0"
                onclick={() => {
                  followOfficerId = unit.id;
                  centredCallId = null;
                }}
                onkeydown={(event) => {
                  if (event.key === 'Enter') followOfficerId = unit.id;
                }}
              >
                <circle
                  cx={unit.x}
                  cy={screenY(unit.y)}
                  r={scale / 2}
                  fill={unit.emergency ? 'var(--color-alert)' : 'var(--color-clear)'}
                  stroke="var(--color-ink)"
                  stroke-width={scale / 10}
                />
                {#if unit.emergency}
                  <!-- An officer in distress keeps a ring around them, so the
                       marker is not only a different colour. -->
                  <circle
                    cx={unit.x}
                    cy={screenY(unit.y)}
                    r={scale}
                    fill="none"
                    stroke="var(--color-alert)"
                    stroke-width={scale / 8}
                  />
                {/if}
                <text
                  x={unit.x + scale}
                  y={screenY(unit.y)}
                  fill="var(--color-ink)"
                  font-size={scale}
                >
                  {unit.label}
                </text>
              </g>
            {/each}
          {/if}
        </svg>
      </div>

      <!-- The legend, and the two things a dispatcher does with a map. -->
      <div class="flex flex-wrap gap-6 text-xs">
        <div>
          <h3 class="font-semibold">{t('cad.map.legend')}</h3>
          <ul class="mt-1 flex flex-col gap-1">
            <li class="flex items-center gap-2">
              <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
                <circle cx="6" cy="6" r="5" fill="var(--color-clear)" stroke="var(--color-ink)" />
              </svg>
              <span>{t('cad.map.units')}</span>
            </li>
            <li class="flex items-center gap-2">
              <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
                <rect
                  x="1"
                  y="1"
                  width="10"
                  height="10"
                  fill="var(--color-caution)"
                  stroke="var(--color-ink)"
                />
              </svg>
              <span>{t('cad.map.calls')}</span>
            </li>
            <li class="flex items-center gap-2">
              <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
                <polygon
                  points="1,10 6,1 11,10"
                  fill="none"
                  stroke="var(--color-border)"
                  stroke-width="1.5"
                />
              </svg>
              <span>{t('cad.map.beats')}</span>
            </li>
          </ul>
        </div>

        <div>
          <h3 class="font-semibold">{t('cad.map.follow')}</h3>
          <ul class="mt-1 flex flex-wrap gap-2">
            {#each unitMarkers as unit (unit.id)}
              <li>
                <button
                  type="button"
                  class="border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-surface)]"
                  class:font-semibold={followOfficerId === unit.id}
                  onclick={() => {
                    // Pressing the unit that is being followed lets it go, which
                    // is what puts the whole agency back on the screen.
                    followOfficerId = followOfficerId === unit.id ? null : unit.id;
                    centredCallId = null;
                  }}
                >
                  <span class="font-[family-name:var(--font-mono)]">{unit.label}</span>
                  <span class="text-[var(--color-ink-muted)]">
                    {typeof unit.at === 'number'
                      ? t('cad.map.positionAge', { duration: elapsed(unit.at, now) })
                      : t('cad.map.noPosition')}
                  </span>
                </button>
              </li>
            {/each}
          </ul>
        </div>

        <div>
          <h3 class="font-semibold">{t('cad.map.center')}</h3>
          <ul class="mt-1 flex flex-wrap gap-2">
            {#each callMarkers as call (call.id)}
              <li>
                <button
                  type="button"
                  class="border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-surface)]"
                  class:font-semibold={centredCallId === call.id}
                  onclick={() => {
                    centredCallId = centredCallId === call.id ? null : call.id;
                    followOfficerId = null;
                    onselect(call.id);
                  }}
                >
                  <span class="{priorityInk(call.priority)} font-semibold">
                    {priorityShort(call.priority)}
                  </span>
                  <span class="font-[family-name:var(--font-mono)]">{call.label}</span>
                </button>
              </li>
            {/each}
          </ul>
        </div>
      </div>
    {/if}
  {/if}
</section>
