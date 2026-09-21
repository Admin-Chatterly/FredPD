"use client"

import { useTransition } from "react"
import { LoaderCircleIcon, Trash2Icon } from "lucide-react"
import { toast } from "sonner"
import { deleteCase } from "@/app/(app)/cases/actions"
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
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"

export function CaseDangerZone({
  caseId,
  title,
  counts,
}: {
  caseId: string
  title: string
  counts: { links: number; notes: number }
}) {
  const [pending, startTransition] = useTransition()

  function run() {
    startTransition(async () => {
      const result = await deleteCase(caseId)
      if (result && !result.ok) toast.error(result.error)
    })
  }

  return (
    <Card className="border-destructive/30">
      <CardHeader>
        <CardTitle className="text-destructive">Ärendeåtgärder</CardTitle>
      </CardHeader>
      <CardContent>
        <AlertDialog>
          <AlertDialogTrigger asChild>
            <Button
              variant="outline"
              className="w-full justify-start text-destructive hover:text-destructive"
            >
              <Trash2Icon /> Radera ärendet
            </Button>
          </AlertDialogTrigger>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>Radera {title}?</AlertDialogTitle>
              <AlertDialogDescription>
                {counts.links > 0
                  ? `${counts.links} ${counts.links === 1 ? "koppling" : "kopplingar"} till personer och organisationer tas bort, men posterna finns kvar i registret. `
                  : "Ingenting är kopplat till det. "}
                {counts.notes > 0
                  ? `${counts.notes} ${counts.notes === 1 ? "uppgift" : "uppgifter"} som loggats på ärendet behålls men kopplas loss, så underrättelserna finns kvar. `
                  : ""}
                Överväg att avsluta ärendet i stället om det kan komma tillbaka.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Avbryt</AlertDialogCancel>
              <AlertDialogAction
                onClick={run}
                disabled={pending}
                className="bg-destructive text-white hover:bg-destructive/90"
              >
                {pending ? <LoaderCircleIcon className="animate-spin" /> : null}
                Radera
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </CardContent>
    </Card>
  )
}
