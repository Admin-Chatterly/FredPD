import { describe, expect, it } from 'vitest';

import { dataUriToBlob } from './dataUri';

describe('dataUriToBlob', () => {
  it('turns a JPEG data URI into its bytes, typed', async () => {
    const blob = dataUriToBlob('data:image/jpeg;base64,/9j/4A==');

    expect(blob?.type).toBe('image/jpeg');
    expect(Array.from(new Uint8Array(await blob!.arrayBuffer()))).toEqual([0xff, 0xd8, 0xff, 0xe0]);
  });

  it('refuses anything that is not an image data URI', () => {
    expect(dataUriToBlob('data:text/html;base64,PGI+')).toBeNull();
    expect(dataUriToBlob('https://example.com/a.jpg')).toBeNull();
  });
});
