import { dataUriToBlob } from './dataUri';
import { nui } from './nui';
import type { RouteResponse } from './nui/types';

/**
 * Taking a photograph for a record (spec 7.3, 7.9; ADR-019).
 *
 * Three steps, the first and last the server's:
 *
 *   1. `begin` -- a route that reads the person, asks the gateway for a
 *      single-use upload link and records who asked. Passed in, because a
 *      record photo and a mugshot begin differently.
 *   2. The client takes the picture (`fredpd:photoCapture`, client/photo.lua)
 *      and this uploads it to the link. The gateway re-encodes it or refuses.
 *   3. `person.photo.commit` attaches the stored file to the person.
 *
 * Every failure comes back as the same envelope a route answers with, so the
 * screen draws it the way it draws any refusal.
 */

export interface PhotoBegun {
  mediaRef: string;
  uploadUrl: string;
  targetId?: number;
}

export interface PhotoCommitted {
  id: number;
  photoId: number;
}

export async function takePhoto(
  begin: () => Promise<RouteResponse<PhotoBegun>>,
): Promise<RouteResponse<PhotoCommitted>> {
  const begun = await begin();
  if (!begun.ok) return begun;

  const captured = await nui.call<{ image: string }>('fredpd:photoCapture', {
    targetId: begun.data.targetId,
  });
  if (!captured.ok) return captured;

  // In the browser against fixtures there is no gateway to upload to; the
  // commit fixture stands in for the whole round trip.
  if (!nui.isMock) {
    const blob = dataUriToBlob(captured.data.image);
    if (!blob) return { ok: false, err: 'invalid', fields: { file: 'not_image' } };

    try {
      const response = await fetch(begun.data.uploadUrl, {
        method: 'PUT',
        headers: { 'content-type': blob.type },
        body: blob,
      });

      if (!response.ok) {
        return { ok: false, err: 'invalid', fields: { file: response.status === 413 ? 'too_large' : 'not_image' } };
      }
    } catch {
      return { ok: false, err: 'conflict', fields: { _input: 'gateway_unavailable' } };
    }
  }

  return nui.call<PhotoCommitted>('person.photo.commit', { mediaRef: begun.data.mediaRef });
}
