/**
 * Shared image rules. These mirror the `intel` bucket's own limits, set in the
 * first migration, so a file that would be rejected server-side is refused here
 * with an explanation instead.
 */
export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024
export const ACCEPTED_IMAGE_TYPES = ["image/jpeg", "image/png", "image/webp", "image/gif"]

/** Returns a message to show the officer, or null when the file is fine. */
export function validateImage(file: File): string | null {
  if (!ACCEPTED_IMAGE_TYPES.includes(file.type)) {
    return "Den filtypen tas inte emot. Använd JPEG, PNG, WebP eller GIF."
  }
  if (file.size > MAX_UPLOAD_BYTES) {
    return `Bilden är ${(file.size / 1024 / 1024).toFixed(1)} MB. Gränsen är 10 MB.`
  }
  return null
}

/**
 * A pasted screenshot arrives as image.png, so the name is usually enough; the
 * mime type is the fallback for anything without a usable extension.
 */
export function extensionFor(file: File): string {
  const fromName = file.name.includes(".") ? file.name.split(".").pop() : null
  if (fromName && /^[a-z0-9]{1,5}$/i.test(fromName)) return fromName.toLowerCase()
  return file.type === "image/jpeg" ? "jpg" : file.type.replace("image/", "") || "bin"
}

export function formatBytes(bytes: number): string {
  return bytes < 1024 * 1024
    ? `${(bytes / 1024).toFixed(0)} KB`
    : `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

/**
 * The browser uploads the file and then tells the server where it put it, so
 * the path is checked against the shapes the app actually writes:
 * `people|organizations|cases/<id>/<name>.<ext>`, `people/<id>/photo/<name>.<ext>`
 * or `unfiled/<name>.<ext>`. Every officer already has full access to the
 * bucket, so this is tidiness and defence in depth rather than a barrier.
 */
export function isSafeStoragePath(path: string): boolean {
  if (path.includes("..") || path.startsWith("/") || path.includes("//")) return false
  return /^(people|organizations|cases|unfiled)\/[A-Za-z0-9/_-]+\.[a-z0-9]{1,5}$/i.test(path)
}
