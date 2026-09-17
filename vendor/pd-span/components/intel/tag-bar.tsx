import Link from "next/link"
import { XIcon } from "lucide-react"
import { intelHref, type IntelFilters } from "@/lib/intel"
import { Badge } from "@/components/ui/badge"
import { cn } from "@/lib/utils"

/**
 * The tags actually in use, most used first, as toggles. Clicking the active
 * tag clears it; every other filter is preserved.
 */
export function TagBar({
  tags,
  filters,
  limit = 24,
}: {
  tags: { tag: string; uses: number }[]
  filters: IntelFilters
  limit?: number
}) {
  if (tags.length === 0) return null
  const shown = tags.slice(0, limit)

  return (
    <div className="flex flex-wrap items-center gap-1.5">
      <span className="text-xs text-muted-foreground">Taggar</span>
      {shown.map(({ tag, uses }) => {
        const active = filters.tag === tag
        return (
          <Link key={tag} href={intelHref({ ...filters, tag: active ? "" : tag })}>
            <Badge
              variant={active ? "default" : "secondary"}
              className={cn("font-mono text-xs", active && "pr-1")}
            >
              #{tag}
              <span className={cn("ml-1", active ? "opacity-80" : "text-muted-foreground")}>
                {uses}
              </span>
              {active ? <XIcon className="ml-0.5 size-3" /> : null}
            </Badge>
          </Link>
        )
      })}
      {tags.length > shown.length ? (
        <span className="text-xs text-muted-foreground">+{tags.length - shown.length} till</span>
      ) : null}
    </div>
  )
}
