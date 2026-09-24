import { fixtures, isRefusal } from './fixtures';
import type { MessageHandler, NuiBridge, NuiMessage, RouteResponse } from './types';

/**
 * The mock bridge: runs the NUI in a plain browser against fixtures, with no
 * game and no server (spec 17.2, M0).
 *
 * It deliberately behaves like the real thing in the ways that catch bugs:
 * every answer is asynchronous and arrives after a delay, unknown routes fail
 * rather than hang, and failures come back as envelopes instead of throwing.
 *
 * Query parameters steer a session without code changes:
 *   ?latency=400    delay every call by 400 ms
 *   ?fail=forbidden make every call fail with that code
 */

const DEFAULT_LATENCY_MS = 120;

function queryParams(): URLSearchParams {
  return new URLSearchParams(window.location.search);
}

function latency(): number {
  const raw = queryParams().get('latency');
  if (raw === null) return DEFAULT_LATENCY_MS;

  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : DEFAULT_LATENCY_MS;
}

function forcedFailure(): string | null {
  return queryParams().get('fail');
}

function wait(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function createMockBridge(): NuiBridge {
  const handlers = new Map<string, Set<MessageHandler>>();

  /**
   * A paper copy is being read (7.28). The client answers `fredpd:close` by
   * letting go of the focus and saying `fredpd:close` back, which is what
   * puts the paper away; the mock does the same, only while a paper is
   * open, so Escape elsewhere in the browser does not blank the page.
   */
  let paperOpen = false;

  /** Lets fixtures and the dev tools push a message as the game would. */
  function emit(message: NuiMessage): void {
    for (const handler of handlers.get(message.type) ?? []) {
      handler(message);
    }
  }

  /**
   * The game normally opens the NUI; in a browser it is always open.
   *
   * It opens *at a placement*, because several routes take the id of the
   * terminal the call is made at and refuse without it — the property room
   * counter and the lab bench both do. Opening with none would leave every
   * screen that needs one unreachable in a browser, which is the one place the
   * interface is supposed to be walkable end to end.
   *
   * `?placement=` overrides it, and `?placement=none` opens with none at all,
   * to walk what an officer sees having opened the MDT on the keybind in the
   * middle of a field.
   */
  const requested = new URLSearchParams(window.location.search).get('placement');

  queueMicrotask(() =>
    emit({
      type: 'fredpd:open',
      ...(requested === 'none' ? {} : { placementId: Number(requested) || 1 }),
    }),
  );

  // A test (or the dev tools) opening and closing the interface the way
  // client/main.lua does, with `window.postMessage` -- and a paper copy being
  // read (7.28). Only these: the CAD
  // pushes have their own window listener (modules/cad/push.ts), and
  // forwarding those here too would deliver them twice.
  window.addEventListener('message', (event: MessageEvent<NuiMessage>) => {
    const type = event.data?.type;
    if (type === 'fredpd:open' || type === 'fredpd:close' || type === 'fredpd:paper') emit(event.data);
    if (type === 'fredpd:paper') paperOpen = true;
    if (type === 'fredpd:open' || type === 'fredpd:close') paperOpen = false;
  });

  return {
    isMock: true,

    async call<T>(route: string, data?: unknown): Promise<RouteResponse<T>> {
      await wait(latency());

      if (route === 'fredpd:close' && paperOpen) {
        paperOpen = false;
        emit({ type: 'fredpd:close' });
        return { ok: true, data: {} as T };
      }

      const forced = forcedFailure();
      if (forced !== null) {
        return { ok: false, err: forced as RouteResponse<T> extends { ok: false; err: infer E } ? E : never };
      }

      const failure = fixtures.fail[route];
      if (failure) {
        return failure.fields
          ? { ok: false, err: failure.err, fields: failure.fields }
          : { ok: false, err: failure.err };
      }

      const fixture = fixtures.ok[route];
      if (!fixture) {
        // An unmocked route is a gap in the fixtures, and saying so beats a
        // promise that never settles.
        console.warn(`[fredpd] no fixture for route "${route}". Add one in src/lib/nui/fixtures.ts.`);
        return { ok: false, err: 'not_found' };
      }

      const answer = fixture(data);

      // A refusal the fixture decided on from the call itself, as opposed to a
      // route marked as always refusing in `fixtures.fail`.
      if (isRefusal(answer)) {
        return answer.fields
          ? { ok: false, err: answer.err, fields: answer.fields }
          : { ok: false, err: answer.err };
      }

      return { ok: true, data: answer as T };
    },

    on(type, handler) {
      const set = handlers.get(type) ?? new Set<MessageHandler>();
      set.add(handler);
      handlers.set(type, set);

      return () => {
        set.delete(handler);
      };
    },
  };
}
