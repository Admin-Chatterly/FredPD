/**
 * Turns an evidence URL into something the card can render: an embedded
 * player for the clip sites officers actually use, an inline image for direct
 * image links, or a plain link card for everything else.
 */
export type EvidenceKind = "medal" | "youtube" | "streamable" | "image" | "link"

export type EvidenceInfo = {
  kind: EvidenceKind
  /** iframe src for player kinds, null otherwise */
  embedUrl: string | null
  /** short human label, e.g. "medal.tv" */
  label: string
}

const IMAGE_EXT = /\.(png|jpe?g|gif|webp|avif)$/i

function stripWww(host: string): string {
  return host.replace(/^www\./i, "")
}

export function describeEvidenceUrl(raw: string): EvidenceInfo {
  let url: URL
  try {
    url = new URL(raw)
  } catch {
    return { kind: "link", embedUrl: null, label: raw }
  }
  const host = stripWww(url.hostname.toLowerCase())
  const segments = url.pathname.split("/").filter(Boolean)

  if (host === "medal.tv") {
    // https://medal.tv/games/<game>/clips/<clipId>/<slug>  ·  https://medal.tv/clips/<clipId>/…
    // https://medal.tv/clip/<clipId>/…  ·  https://medal.tv/?contentId=<clipId>
    const idx = segments.findIndex((s) => s === "clips" || s === "clip")
    const clipId = idx >= 0 ? segments[idx + 1] : url.searchParams.get("contentId")
    if (clipId && /^[A-Za-z0-9_-]+$/.test(clipId)) {
      return {
        kind: "medal",
        embedUrl: `https://medal.tv/clip/${clipId}?autoplay=0&loop=0&muted=0&cta=0`,
        label: "medal.tv",
      }
    }
    return { kind: "link", embedUrl: null, label: "medal.tv" }
  }

  if (host === "youtube.com" || host === "m.youtube.com" || host === "youtu.be") {
    let videoId: string | null = null
    if (host === "youtu.be") videoId = segments[0] ?? null
    else if (segments[0] === "watch") videoId = url.searchParams.get("v")
    else if (segments[0] === "shorts" || segments[0] === "embed" || segments[0] === "live") videoId = segments[1] ?? null
    if (videoId && /^[A-Za-z0-9_-]{6,}$/.test(videoId)) {
      return { kind: "youtube", embedUrl: `https://www.youtube.com/embed/${videoId}`, label: "youtube.com" }
    }
    return { kind: "link", embedUrl: null, label: host }
  }

  if (host === "streamable.com") {
    const id = segments[0] === "e" ? segments[1] : segments[0]
    if (id && /^[A-Za-z0-9]+$/.test(id)) {
      return { kind: "streamable", embedUrl: `https://streamable.com/e/${id}`, label: "streamable.com" }
    }
    return { kind: "link", embedUrl: null, label: host }
  }

  if (IMAGE_EXT.test(url.pathname)) {
    return { kind: "image", embedUrl: null, label: host }
  }

  return { kind: "link", embedUrl: null, label: host }
}
