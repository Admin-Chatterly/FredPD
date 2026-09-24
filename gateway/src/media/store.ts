import { createHash } from 'node:crypto';
import { link, mkdir, open, readFile, stat, unlink, writeFile } from 'node:fs/promises';
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
  /**
   * Streams a request body to disk, capped at `maxBytes`, and publishes it
   * under the ref only once `options.accept` has passed it -- the scan, and
   * for a photograph the re-encode, run against the unpublished part, so
   * nothing is ever servable that was not accepted.
   *
   * Once only: a ref that already holds a file, another upload is writing
   * right now, or was refused before, is refused with `AlreadyStoredError`.
   */
  save(
    mediaRef: string,
    stream: NodeJS.ReadableStream,
    maxBytes: number,
    options?: SaveOptions,
  ): Promise<{ bytes: number }>;
  /** The first bytes of a stored file, for telling what it is. */
  head(mediaRef: string, length: number): Promise<Buffer>;
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

class AlreadyStoredError extends Error {
  constructor() {
    super('this media ref already holds a file');
    this.name = 'AlreadyStoredError';
  }
}

/** An upload `accept` refused; the reason is what the caller answers with. */
class RefusedError extends Error {
  constructor(readonly reason: string) {
    super(`upload refused: ${reason}`);
    this.name = 'RefusedError';
  }
}

export interface SaveOptions {
  /**
   * Passed the received file (its unpublished path and bytes) before it is
   * published. Returns the bytes to publish -- the same, or a replacement
   * such as a re-encoded image -- or a refusal reason.
   */
  accept?: (partPath: string, bytes: Buffer) => Promise<{ bytes: Buffer } | { refused: string }>;
}

export { AlreadyStoredError, RefusedError, TooLargeError };

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

  function tombstonePath(mediaRef: string): string {
    assertRef(mediaRef);
    return join(root, `${mediaRef}.refused`);
  }

  async function pathExists(path: string): Promise<boolean> {
    try {
      await stat(path);
      return true;
    } catch {
      return false;
    }
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
     * Written to a `.part` file first and linked into place only once the
     * whole body has arrived within the size cap. A reader that raced the
     * write would otherwise see a truncated file with no way to tell it apart
     * from a genuinely short one -- the link is what makes "exists" mean
     * "complete".
     */
    async save(mediaRef, stream, maxBytes, options) {
      await mkdir(root, { recursive: true });

      // An upload token is good for one file. A ref that already holds one,
      // or was refused once (the tombstone), is not written again, and 'wx'
      // makes a second upload racing the first fail on the `.part` file
      // rather than interleave with it.
      if ((await this.exists(mediaRef)) || (await pathExists(tombstonePath(mediaRef)))) {
        throw new AlreadyStoredError();
      }

      const tmp = partPath(mediaRef);
      let handle;
      try {
        handle = await open(tmp, 'wx');
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'EEXIST') throw new AlreadyStoredError();
        throw error;
      }

      let bytes = 0;
      let complete = false;

      try {
        for await (const chunk of stream as AsyncIterable<Buffer>) {
          bytes += chunk.length;

          if (bytes > maxBytes) {
            throw new TooLargeError();
          }

          await handle.write(chunk);
        }

        complete = true;
      } finally {
        await handle.close();
        // A refused or broken upload leaves nothing behind, not even a part.
        if (!complete) await unlink(tmp).catch(() => undefined);
      }

      try {
        let published = bytes;

        if (options?.accept) {
          const verdict = await options.accept(tmp, await readFile(tmp));

          if ('refused' in verdict) {
            // The token is spent: a refused ref is not tried again.
            await writeFile(tombstonePath(mediaRef), verdict.refused);
            throw new RefusedError(verdict.refused);
          }

          await writeFile(tmp, verdict.bytes);
          published = verdict.bytes.length;
        }

        // `link` refuses an existing name where `rename` would overwrite it:
        // whatever raced this upload in, the file already published stays.
        try {
          await link(tmp, finalPath(mediaRef));
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code === 'EEXIST') throw new AlreadyStoredError();
          throw error;
        }

        return { bytes: published };
      } finally {
        await unlink(tmp).catch(() => undefined);
      }
    },

    async head(mediaRef, length) {
      const handle = await open(finalPath(mediaRef), 'r');
      try {
        const buffer = Buffer.alloc(length);
        const { bytesRead } = await handle.read(buffer, 0, length, 0);
        return buffer.subarray(0, bytesRead);
      } finally {
        await handle.close();
      }
    },
  };
}
