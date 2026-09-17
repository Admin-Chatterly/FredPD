import type { ErrorCode } from '@fredpd/schema';

/**
 * The response envelope every route answers with (spec 3.5). There is no third
 * shape: a route either succeeded and carries data, or failed and carries a
 * code the UI turns into a locale key.
 */
export type RouteResponse<T> =
  | { ok: true; data: T }
  | { ok: false; err: ErrorCode; fields?: Record<string, string> };

/** A message pushed from the game to the NUI (spec 3.6). */
export interface NuiMessage {
  type: string;
  [key: string]: unknown;
}

export type MessageHandler = (message: NuiMessage) => void;

export interface NuiBridge {
  /**
   * Calls a route and resolves with its envelope. Transport failures are
   * folded into the same envelope, so callers only ever branch on `ok`.
   */
  call<T>(route: string, data?: unknown): Promise<RouteResponse<T>>;

  /** Subscribes to pushed messages. Returns an unsubscribe function. */
  on(type: string, handler: MessageHandler): () => void;

  /** True when running against fixtures in a plain browser. */
  readonly isMock: boolean;
}
