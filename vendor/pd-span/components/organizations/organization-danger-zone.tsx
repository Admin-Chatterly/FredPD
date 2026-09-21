"use client"

import { useTransition } from "react"
import { LoaderCircleIcon, Trash2Icon } from "lucide-react"
import { toast } from "sonner"
import { deleteOrganization } from "@/app/(app)/organizations/actions"
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

type Counts = {
  members: number
  notes: number
  caseLinks: number
  evidence: number
}

function plural(n: number, one: string, many = `${one}s`): string {
  return `${n} ${n === 1 ? one : many}`
}

export function OrganizationDangerZone({
  organizationId,
  name,
  counts,
}: {
  organizationId: string
  name: string
  counts: Counts
}) {
  const [pending, startTransition] = useTransition()

  // Var tydlig med vad som blir kvar, eftersom svaret skiljer sig per relation:
  // personer och deras uppgifter stannar, kopplingsrader och bevis gör det inte.
  const kept: string[] = []
  if (counts.members > 0) kept.push(`${plural(counts.members, "medlem", "medlemmar")} blir kvar registrerade`)
  if (counts.notes > 0) kept.push(`${plural(counts.notes, "uppgift", "uppgifter")} sparas men kopplas loss härifrån`)

  const removed: string[] = []
  if (counts.members > 0) removed.push(plural(counts.members, "medlemskap", "medlemskap"))
  if (counts.caseLinks > 0) removed.push(plural(counts.caseLinks, "ärendekoppling", "ärendekopplingar"))
  if (counts.evidence > 0) removed.push(`${plural(counts.evidence, "bevis", "bevis")} som är kopplade till den`)

  function run() {
    startTransition(async () => {
      const result = await deleteOrganization(organizationId)
      if (result && !result.ok) toast.error(result.error)
    })
  }

  return (
    <Card className="border-destructive/30">
      <CardHeader>
        <CardTitle className="text-destructive">Åtgärder på posten</CardTitle>
      </CardHeader>
      <CardContent>
        <AlertDialog>
          <AlertDialogTrigger asChild>
            <Button variant="outline" className="w-full justify-start text-destructive hover:text-destructive">
              <Trash2Icon /> Ta bort organisationen
            </Button>
          </AlertDialogTrigger>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>Ta bort {name}?</AlertDialogTitle>
              <AlertDialogDescription>
                {kept.length > 0 ? `${kept.join(", och ")}. ` : ""}
                {removed.length > 0
                  ? `Detta tar bort ${removed.join(", ")}. `
                  : "Inget annat är kopplat. "}
                Överväg att sätta status till upplöst i stället, då behålls historiken.
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
                Delete
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </CardContent>
    </Card>
  )
}
