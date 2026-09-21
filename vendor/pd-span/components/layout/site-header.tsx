"use client"

import Link from "next/link"
import { usePathname } from "next/navigation"
import { LogOutIcon, ShieldIcon } from "lucide-react"
import { signOut } from "@/app/login/actions"
import { LogIntelButton } from "@/components/notes/log-intel-button"
import { GlobalSearch } from "@/components/search/global-search"
import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"

const NAV = [
  { href: "/", label: "Översikt" },
  { href: "/people", label: "Personer" },
  { href: "/organizations", label: "Organisationer" },
  { href: "/intel", label: "Underrättelser" },
  { href: "/cases", label: "Ärenden" },
  { href: "/board", label: "Tavlan" },
] as const

export function SiteHeader({ callsign }: { callsign: string }) {
  const pathname = usePathname()

  return (
    <header className="sticky top-0 z-40 border-b border-border/60 bg-background/90 backdrop-blur">
      <div className="mx-auto flex h-14 w-full max-w-6xl items-center gap-4 px-4 sm:px-6">
        <Link href="/" className="flex items-center gap-2 font-semibold tracking-tight">
          <ShieldIcon className="size-5 text-primary" />
          <span>PD-span</span>
          <span className="hidden text-muted-foreground sm:inline">Underrättelser</span>
        </Link>
        <nav className="flex flex-1 items-center gap-1 overflow-x-auto">
          {NAV.map((item) => {
            const active =
              item.href === "/" ? pathname === "/" : pathname.startsWith(item.href)
            return (
              <Link
                key={item.href}
                href={item.href}
                className={cn(
                  "rounded-md px-3 py-1.5 text-sm transition-colors hover:bg-accent hover:text-accent-foreground",
                  active ? "bg-accent text-accent-foreground" : "text-muted-foreground"
                )}
              >
                {item.label}
              </Link>
            )
          })}
        </nav>
        <div className="flex items-center gap-2">
          <GlobalSearch />
          <LogIntelButton />
          <span className="hidden text-sm text-muted-foreground lg:inline">{callsign}</span>
          <form action={signOut}>
            <Button type="submit" variant="ghost" size="sm" title="Logga ut">
              <LogOutIcon />
              <span className="sr-only">Logga ut</span>
            </Button>
          </form>
        </div>
      </div>
    </header>
  )
}
