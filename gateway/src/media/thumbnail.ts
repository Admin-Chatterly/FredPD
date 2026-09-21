import sharp from 'sharp';

/**
 * WebP thumbnails (spec 12.2: "Media: WebP thumbnails, lazy-loaded images,
 * long cache headers").
 *
 * Runs after the scan, never before: `routes.ts` calls this only once
 * `scanUpload` has reported clean, so a hostile image never reaches the
 * decoder that would otherwise be the first thing to touch it.
 *
 * Returns `null` for anything that is not an image sharp can decode --
 * photographs are the only media this suite ever thumbnails today, and a
 * request to thumbnail a PDF or an audio capture is not an error, it is a
 * caller that should not have asked.
 */
export async function makeThumbnail(
  input: Buffer,
  maxDimension = 320,
): Promise<Buffer | null> {
  try {
    return await sharp(input)
      .rotate()
      .resize({ width: maxDimension, height: maxDimension, fit: 'inside', withoutEnlargement: true })
      .webp({ quality: 80 })
      .toBuffer();
  } catch {
    return null;
  }
}
