"use client"

import { useTransition, type ComponentProps } from "react"
import { LoaderCircleIcon } from "lucide-react"
import { toast } from "sonner"
import type { ActionResult } from "@/app/(app)/people/actions"
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog"
import { Button } from "@/components/ui/button"

type Props = Omit<ComponentProps<typeof Button>, "onClick" | "type"> & {
  /** En server-action som rapporterar lyckat resultat eller ett felmeddelande. */
  action: () => Promise<ActionResult | void>
  successMessage?: string
  confirm?: { title: string; description?: string; actionLabel?: string; destructive?: boolean }
}

/** Kör en server-action från en knapp, med återkoppling och valfri bekräftelse. */
export function ActionButton({ action, successMessage, confirm, children, disabled, ...button }: Props) {
  const [pending, startTransition] = useTransition()

  function run() {
    startTransition(async () => {
      const result = await action()
      if (result && !result.ok) {
        toast.error(result.error)
      } else if (successMessage) {
        toast.success(successMessage)
      }
    })
  }

  const content = (
    <>
      {pending ? <LoaderCircleIcon className="animate-spin" /> : null}
      {children}
    </>
  )

  if (!confirm) {
    return (
      <Button type="button" {...button} disabled={disabled || pending} onClick={run}>
        {content}
      </Button>
    )
  }

  return (
    <AlertDialog>
      <AlertDialogTrigger asChild>
        <Button type="button" {...button} disabled={disabled || pending}>
          {content}
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{confirm.title}</AlertDialogTitle>
          {confirm.description ? (
            <AlertDialogDescription>{confirm.description}</AlertDialogDescription>
          ) : null}
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Avbryt</AlertDialogCancel>
          <AlertDialogAction
            onClick={run}
            className={confirm.destructive ? "bg-destructive text-white hover:bg-destructive/90" : undefined}
          >
            {confirm.actionLabel ?? "Bekräfta"}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}
