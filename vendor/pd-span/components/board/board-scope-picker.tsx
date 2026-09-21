"use client"

import { useRouter } from "next/navigation"
import { useTransition } from "react"
import { LoaderCircleIcon } from "lucide-react"
import {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectLabel,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import type { BoardScopeOptions } from "@/lib/data/board"

/**
 * One select drives the whole board. The value encodes the kind and the id, so
 * cases and organizations can share a list without colliding.
 */
export function BoardScopePicker({
  value,
  options,
}: {
  value: string
  options: BoardScopeOptions
}) {
  const router = useRouter()
  const [pending, startTransition] = useTransition()

  function onChange(next: string) {
    startTransition(() => router.replace(next === "all" ? "/board" : `/board?scope=${next}`))
  }

  return (
    <div className="flex items-center gap-2">
      <Select value={value} onValueChange={onChange}>
        <SelectTrigger className="w-72" aria-label="Vad som visas på tavlan">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">Alla i registret</SelectItem>
          {options.cases.length > 0 ? (
            <SelectGroup>
              <SelectLabel>Ärenden</SelectLabel>
              {options.cases.map((c) => (
                <SelectItem key={c.id} value={`case:${c.id}`}>
                  {c.title}
                </SelectItem>
              ))}
            </SelectGroup>
          ) : null}
          {options.organizations.length > 0 ? (
            <SelectGroup>
              <SelectLabel>Organisationer</SelectLabel>
              {options.organizations.map((o) => (
                <SelectItem key={o.id} value={`organization:${o.id}`}>
                  {o.name}
                </SelectItem>
              ))}
            </SelectGroup>
          ) : null}
        </SelectContent>
      </Select>
      {pending ? <LoaderCircleIcon className="size-4 animate-spin text-muted-foreground" /> : null}
    </div>
  )
}
