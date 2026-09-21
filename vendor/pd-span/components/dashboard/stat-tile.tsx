import Link from "next/link"
import type { LucideIcon } from "lucide-react"
import { Card, CardContent } from "@/components/ui/card"

export function StatTile({
  label,
  value,
  icon: Icon,
  href,
}: {
  label: string
  value: number
  icon: LucideIcon
  href: string
}) {
  return (
    <Link href={href} className="group">
      <Card className="gap-2 py-4 transition-colors group-hover:border-primary/40">
        <CardContent className="flex items-center justify-between px-4">
          <div>
            <p className="text-xs uppercase tracking-wide text-muted-foreground">{label}</p>
            <p className="text-2xl font-semibold tabular-nums">{value}</p>
          </div>
          <Icon className="size-5 text-muted-foreground group-hover:text-primary" />
        </CardContent>
      </Card>
    </Link>
  )
}
