import sharp from 'sharp';

/**
 * Re-encoding an uploaded photograph (invariant 9, spec 11.2).
 *
 * A file that claims to be an image is decoded and written out again as a
 * fresh JPEG, so what the store keeps is always something sharp produced:
 * EXIF (a camera's position, a phone's serial) is gone, a polyglot that is
 * also a script or an archive is gone, and a file that is not an image at all
 * fails to decode and is refused. Oversized images are brought down to
 * `MAX_DIMENSION` on their longer side, which is still well beyond anything a
 * record screen draws.
 */

const MAX_DIMENSION = 2048;

/** Decompression-bomb guard: sharp refuses more pixels than this on input. */
export const MAX_INPUT_PIXELS = 16_000_000;

/**
 * The formats a photograph arrives in. screenshot-basic writes JPEG; PNG and
 * WebP are what a browser would hand over. SVG, TIFF, HEIF and the rest of
 * what libvips can read are refused before a decoder is reached for them.
 */
const ACCEPTED_FORMATS = new Set(['jpeg', 'png', 'webp']);

/**
 * At most this many images decoded at once. Each decode can hold tens of
 * megabytes, and every officer with an upload link can start one.
 */
const MAX_CONCURRENT_DECODES = 2;
let running = 0;
const waiting: Array<() => void> = [];

/** Runs `task` once a decode slot is free. */
export async function withDecodeSlot<T>(task: () => Promise<T>): Promise<T> {
  if (running >= MAX_CONCURRENT_DECODES) {
    await new Promise<void>((resolve) => waiting.push(resolve));
  }

  running += 1;
  try {
    return await task();
  } finally {
    running -= 1;
    waiting.shift()?.();
  }
}

export async function reencodeImage(input: Buffer): Promise<Buffer | null> {
  return withDecodeSlot(async () => {
    try {
      const { format } = await sharp(input, { limitInputPixels: MAX_INPUT_PIXELS }).metadata();
      if (!format || !ACCEPTED_FORMATS.has(format)) return null;

      return await sharp(input, { limitInputPixels: MAX_INPUT_PIXELS })
        .rotate()
        .resize({ width: MAX_DIMENSION, height: MAX_DIMENSION, fit: 'inside', withoutEnlargement: true })
        .jpeg({ quality: 85 })
        .toBuffer();
    } catch {
      return null;
    }
  });
}

/**
 * What a stored file is, from its first bytes, for the `content-type` it is
 * served with. Only the kinds this gateway itself writes are named; anything
 * else is served as an opaque download.
 */
export function contentTypeOf(head: Buffer): string {
  if (head.length >= 3 && head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) return 'image/jpeg';
  if (head.length >= 4 && head.subarray(0, 4).toString('latin1') === '%PDF') return 'application/pdf';

  return 'application/octet-stream';
}
