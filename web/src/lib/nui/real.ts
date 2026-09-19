import type { MessageHandler, NuiBridge, NuiMessage, RouteResponse } from './types';

/**
 * The real bridge: NUI callbacks over `https://<resource>/<route>`, and pushed
 * messages over the CEF `message` event.
 */

declare global {
  interface Window {
    /** Present only inside FiveM's CEF. */
    GetParentResourceName?: () => string;
    invokeNative?: (native: string, ...args: unknown[]) => unknown;
  }
}

/** True when the page is running inside FiveM rather than a browser tab. */
export function isInGame(): boolean {
  return typeof window.GetParentResourceName === 'function' || typeof window.invokeNative === 'function';
}

function resourceName(): string {
  return window.GetParentResourceName?.() ?? 'fredpd';
}

export function createRealBridge(): NuiBridge {
  const handlers = new Map<string, Set<MessageHandler>>();

  window.addEventListener('message', (event: MessageEvent<NuiMessage>) => {
    const message = event.data;
    if (!message || typeof message.type !== 'string') return;

    for (const handler of handlers.get(message.type) ?? []) {
      handler(message);
    }
  });

  return {
    isMock: false,

    async call<T>(route: string, data?: unknown): Promise<RouteResponse<T>> {
      try {
        const response = await fetch(`https://${resourceName()}/${route}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json; charset=UTF-8' },
          body: JSON.stringify(data ?? {}),
        });

        if (!response.ok) {
          return { ok: false, err: 'internal' };
        }

        return (await response.json()) as RouteResponse<T>;
      } catch {
        // The game closed the page, or the resource stopped mid-call. Either
        // way the UI should say "no connection", not throw.
        return { ok: false, err: 'internal' };
      }
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
