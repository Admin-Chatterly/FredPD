import Link from "next/link"
import { XIcon } from "lucide-react"
import { Badge } from "@/components/ui/badge"

/**
 * Visas på en lista man kommit till via en tagg, så att det syns varför listan
 * är kort och hur man vidgar den igen.
 */
export function ActiveTagFilter({ tag, clearHref }: { tag: string; clearHref: string }) {
  return (
    <div className="flex flex-wrap items-center gap-2 text-sm">
      <span className="text-muted-foreground">Taggat</span>
      <Badge variant="default" className="font-mono text-xs">
        #{tag}
      </Badge>
      <Link
        href={clearHref}
        className="inline-flex items-center gap-1 text-xs text-muted-foreground hover:underline"
      >
        <XIcon className="size-3" /> rensa
      </Link>
    </div>
  )
}
