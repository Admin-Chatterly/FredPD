/**
 * A search that could not be run -- the route refused it. Thrown by a
 * picker's `search` so the box says why (`error.<code>`) instead of "No
 * matches", which would tell an officer refused the register that the
 * record does not exist.
 */
export class PickerRefusal extends Error {
  readonly code: string;

  constructor(code: string) {
    super(code);
    this.code = code;
  }
}

/** What a picker's `search` may return: the rows, or the rows and a muted note. */
export type PickerResult<T> = T[] | { items: T[]; note?: string | null };
