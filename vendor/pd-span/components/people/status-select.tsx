"use client"

import { useState, useTransition } from "react"
import { toast } from "sonner"
import { updatePersonStatus } from "@/app/(app)/people/actions"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import { PERSON_STATUSES, PERSON_STATUS_LABELS, PERSON_STATUS_STYLES, type PersonStatus } from "@/lib/constants"
import { cn } from "@/lib/utils"

export function StatusSelect({ personId, status }: { personId: string; status: string }) {
  const [value, setValue] = useState(status)
  const [pending, startTransition] = useTransition()
  const current = (PERSON_STATUSES as readonly string[]).includes(value) ? (value as PersonStatus) : "unknown"

  function onChange(next: string) {
    const previous = value
    setValue(next)
    startTransition(async () => {
      const result = await updatePersonStatus(personId, next)
      if (!result.ok) {
        setValue(previous)
        toast.error(result.error)
      }
    })
  }

  return (
    <Select value={value} onValueChange={onChange} disabled={pending}>
      <SelectTrigger
        className={cn("w-52 font-medium", PERSON_STATUS_STYLES[current])}
        aria-label="Status"
      >
        <SelectValue />
      </SelectTrigger>
      <SelectContent>
        {PERSON_STATUSES.map((s) => (
          <SelectItem key={s} value={s}>
            {PERSON_STATUS_LABELS[s]}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )
}
