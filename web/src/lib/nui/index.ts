import { createRealBridge, isInGame } from './real';
import type { NuiBridge } from './types';

/**
 * Picks the bridge for the environment: the real NUI transport inside FiveM,
 * fixtures in a browser tab.
 *
 * The choice is made once, here, so no component ever has to know which one it
 * is talking to -- which is what makes the whole UI developable, screenshot-
 * testable and reviewable without starting a game server.
 *
 * The mock branch is gated on `import.meta.env.DEV`, a compile-time constant
 * Vite substitutes with the literal `false` in a production build. Once that
 * substitution happens, `false && !isInGame()` folds to `false` at build time
 * and the minifier proves the `import('./mock')` branch unreachable, dropping
 * it -- and with it `./mock` and the ~5,000-line `./fixtures` it pulls in --
 * from what ships to players. `isInGame()` alone cannot do this: it is a
 * runtime check, so both branches would always be reachable and both would
 * always be bundled. The check still applies *within* dev, so a dev build
 * hosted inside FiveM's CEF for hot-reload testing still gets the real
 * bridge rather than fixtures.
 */
export const nui: NuiBridge =
  import.meta.env.DEV && !isInGame()
    ? (await import('./mock')).createMockBridge()
    : createRealBridge();

export type { NuiBridge, NuiMessage, RouteResponse } from './types';
