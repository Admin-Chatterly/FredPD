import { createMockBridge } from './mock';
import { createRealBridge, isInGame } from './real';
import type { NuiBridge } from './types';

/**
 * Picks the bridge for the environment: the real NUI transport inside FiveM,
 * fixtures in a browser tab.
 *
 * The choice is made once, here, so no component ever has to know which one it
 * is talking to -- which is what makes the whole UI developable, screenshot-
 * testable and reviewable without starting a game server.
 */
export const nui: NuiBridge = isInGame() ? createRealBridge() : createMockBridge();

export type { NuiBridge, NuiMessage, RouteResponse } from './types';
