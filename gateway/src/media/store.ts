import { createHash } from 'node:crypto';
import { mkdir, open, rename, stat, unlink } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { join, resolve } from 'node:path';

/**
 * Local-disk media storage (spec 3.2: "disk or S3-compatible"). A deployment
 * that needs S3 swaps this file for one with the same exports; nothing above
 * it knows which backend is in use.
 *
 * Every path is built from a `media_ref` this module itself generated
 * (`newMediaRef`, `tokens.ts`) — never from a value a caller sent — so
 * `REF_PATTERN` below is a defensive assertion, not a parser of untrusted
 * input. A ref that does not match it is a bug here, not an attack from
 * outside, and failing loudly is what catches that during development rather
 * than in production.
 */

const REF_PATTERN = /^media_[0-9a-f-]{36}$/;

export interface MediaStore {
  /** Streams a request body to disk, capped at `maxBytes`. */
  save(mediaRef: string, stream: NodeJS.ReadableStream, maxBytes: number): Promise<{ bytes: number }>;
  /** The absolute path of a stored file, once it exists. */
  pathFor(mediaRef: string): string;
  exists(mediaRef: string): Promise<boolean>;
  /** A stream to serve a download from. */
  read(mediaRef: string): NodeJS.ReadableStream;
  remove(mediaRef: string): Promise<void>;
  /** SHA-256 of the stored bytes, for the audit entry a scan or a release writes. */
  hash(mediaRef: string): Promise<string>;
}

class TooLargeError extends Error {
  constructor() {
    super('upload exceeds the configured size cap');
    this.name = 'TooLargeError';
  }
}

export { TooLargeError };

export function createDiskStore(directory: string): MediaStore {
  const root = resolve(directory);

  function assertRef(mediaRef: string): void {
    if (!REF_PATTERN.test(mediaRef)) {
      throw new Error(`not a media ref this store generated: ${mediaRef}`);
    }
  }

  function finalPath(mediaRef: string): string {
    assertRef(mediaRef);
    return join(root, mediaRef);
  }

  function partPath(mediaRef: string): string {
    assertRef(mediaRef);
    return join(root, `${mediaRef}.part`);
  }

  return {
    pathFor: finalPath,

    async exists(mediaRef) {
      try {
        await stat(finalPath(mediaRef));
        return true;
      } catch {
        return false;
      }
    },

    read(mediaRef) {
      return createReadStream(finalPath(mediaRef));
    },

    async remove(mediaRef) {
      await unlink(finalPath(mediaRef)).catch(() => undefined);
    },

    async hash(mediaRef) {
      const digest = createHash('sha256');

      await new Promise<void>((resolvePromise, rejectPromise) => {
        const stream = createReadStream(finalPath(mediaRef));
        stream.on('data', (chunk) => digest.update(chunk as Buffer));
        stream.on('end', () => resolvePromise());
        stream.on('error', rejectPromise);
      });

      return digest.digest('hex');
    },

    /**
     * Written to a `.part` file first and renamed into place only once the
     * whole body has arrived within the size cap. A reader that raced the
     * write would otherwise see a truncated file with no way to tell it apart
     * from a genuinely short one -- the rename is what makes "exists" mean
     * "complete".
     */
    async save(mediaRef, stream, maxBytes) {
      await mkdir(root, { recursive: true });

      const tmp = partPath(mediaRef);
      const handle = await open(tmp, 'w');
      let bytes = 0;

      try {
        for await (const chunk of stream as AsyncIterable<Buffer>) {
          bytes += chunk.length;

          if (bytes > maxBytes) {
            throw new TooLargeError();
          }

          await handle.write(chunk);
        }
      } finally {
        await handle.close();
      }

      await rename(tmp, finalPath(mediaRef));

      return { bytes };
    },
  };
}
