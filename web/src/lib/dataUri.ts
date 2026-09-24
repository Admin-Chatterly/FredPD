/** `data:image/jpeg;base64,…` to bytes, without fetching a `data:` URL (the CSP's connect-src has none). */
export function dataUriToBlob(dataUri: string): Blob | null {
  const match = /^data:(image\/[a-z]+);base64,(.*)$/.exec(dataUri);
  if (!match || match[1] === undefined || match[2] === undefined) return null;

  const binary = atob(match[2]);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);

  return new Blob([bytes], { type: match[1] });
}
