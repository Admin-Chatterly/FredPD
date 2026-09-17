import Link from "next/link"
import { CheckIcon, UndoIcon, XIcon } from "lucide-react"
import { removeMembership, setMembershipConfirmed } from "@/app/(app)/memberships/actions"
import { ActionButton } from "@/components/action-button"
import { MembershipBadge, OrganizationTypeBadge } from "@/components/badges"
import { AddMembershipDialog } from "@/components/people/add-membership-dialog"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import type { MembershipRow, OrganizationOption } from "@/lib/data/people"

export function MembershipsSection({
  personId,
  memberships,
  organizationOptions,
}: {
  personId: string
  memberships: MembershipRow[]
  organizationOptions: OrganizationOption[]
}) {
  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between">
        <CardTitle>Organisationer</CardTitle>
        <AddMembershipDialog
          personId={personId}
          organizations={organizationOptions}
          existingIds={memberships.map((m) => m.organization.id)}
        />
      </CardHeader>
      <CardContent>
        {memberships.length === 0 ? (
          <p className="text-sm text-muted-foreground">Inga kända kopplingar.</p>
        ) : (
          <ul className="flex flex-col divide-y divide-border/60">
            {memberships.map((m) => (
              <li key={m.organization.id} className="flex items-start justify-between gap-2 py-2">
                <div className="flex min-w-0 flex-col gap-1">
                  <Link href={`/organizations/${m.organization.id}`} className="font-medium hover:underline">
                    {m.organization.name}
                  </Link>
                  <div className="flex flex-wrap items-center gap-1">
                    <OrganizationTypeBadge type={m.organization.type} />
                    <MembershipBadge isConfirmed={m.is_confirmed} />
                    {m.role ? <span className="text-xs text-muted-foreground">{m.role}</span> : null}
                  </div>
                </div>
                <div className="flex shrink-0 items-center">
                  <ActionButton
                    action={setMembershipConfirmed.bind(null, personId, m.organization.id, !m.is_confirmed)}
                    variant="ghost"
                    size="icon-sm"
                    title={m.is_confirmed ? "Markera som misstänkt" : "Markera som bekräftad"}
                    successMessage={m.is_confirmed ? "Markerad som misstänkt" : "Markerad som bekräftad"}
                  >
                    {m.is_confirmed ? <UndoIcon /> : <CheckIcon />}
                  </ActionButton>
                  <ActionButton
                    action={removeMembership.bind(null, personId, m.organization.id)}
                    variant="ghost"
                    size="icon-sm"
                    title="Ta bort"
                    className="text-muted-foreground hover:text-destructive"
                    confirm={{
                      title: `Ta bort från ${m.organization.name}?`,
                      actionLabel: "Ta bort",
                      destructive: true,
                    }}
                    successMessage="Medlemskapet borttaget"
                  >
                    <XIcon />
                  </ActionButton>
                </div>
              </li>
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  )
}
