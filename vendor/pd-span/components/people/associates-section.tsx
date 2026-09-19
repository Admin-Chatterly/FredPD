import Link from "next/link"
import { XIcon } from "lucide-react"
import { removeAssociate } from "@/app/(app)/people/actions"
import { ActionButton } from "@/components/action-button"
import { MembershipBadge, PersonStatusBadge, UnknownBadge } from "@/components/badges"
import { AddAssociateDialog } from "@/components/people/add-associate-dialog"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import type { AssociateRow } from "@/lib/data/people"
import { isUnidentified, personLabel } from "@/lib/format"

export function AssociatesSection({ personId, associates }: { personId: string; associates: AssociateRow[] }) {
  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between">
        <CardTitle>Kontakter</CardTitle>
        <AddAssociateDialog personId={personId} excludeIds={associates.map((a) => a.other.id)} />
      </CardHeader>
      <CardContent>
        {associates.length === 0 ? (
          <p className="text-sm text-muted-foreground">Inga kända kontakter.</p>
        ) : (
          <ul className="flex flex-col divide-y divide-border/60">
            {associates.map((a) => (
              <li key={a.other.id} className="flex items-start justify-between gap-2 py-2">
                <div className="flex min-w-0 flex-col gap-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <Link href={`/people/${a.other.id}`} className="font-medium hover:underline">
                      {personLabel(a.other)}
                    </Link>
                    {isUnidentified(a.other) ? <UnknownBadge /> : null}
                  </div>
                  <div className="flex flex-wrap items-center gap-1">
                    <PersonStatusBadge status={a.other.status} />
                    <MembershipBadge isConfirmed={a.is_confirmed} />
                    {a.relationship ? (
                      <span className="text-xs text-muted-foreground">{a.relationship}</span>
                    ) : null}
                  </div>
                </div>
                <ActionButton
                  action={removeAssociate.bind(null, personId, a.other.id)}
                  variant="ghost"
                  size="icon-sm"
                  title="Koppla loss"
                  className="shrink-0 text-muted-foreground hover:text-destructive"
                  confirm={{ title: `Koppla loss ${personLabel(a.other)}?`, actionLabel: "Koppla loss", destructive: true }}
                  successMessage="Kontakten bortkopplad"
                >
                  <XIcon />
                </ActionButton>
              </li>
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  )
}
