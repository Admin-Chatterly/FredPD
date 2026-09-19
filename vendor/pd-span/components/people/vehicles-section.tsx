import { Trash2Icon, UnlinkIcon } from "lucide-react"
import { deleteVehicle, unlinkVehicle } from "@/app/(app)/people/actions"
import { ActionButton } from "@/components/action-button"
import { AddVehicleDialog } from "@/components/people/add-vehicle-dialog"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import type { Tables } from "@/lib/database.types"

export function VehiclesSection({ personId, vehicles }: { personId: string; vehicles: Tables<"vehicles">[] }) {
  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between">
        <CardTitle>Fordon</CardTitle>
        <AddVehicleDialog personId={personId} />
      </CardHeader>
      <CardContent>
        {vehicles.length === 0 ? (
          <p className="text-sm text-muted-foreground">Inga registrerade fordon.</p>
        ) : (
          <ul className="flex flex-col divide-y divide-border/60">
            {vehicles.map((v) => (
              <li key={v.id} className="flex items-start justify-between gap-2 py-2">
                <div className="flex min-w-0 flex-col">
                  <span className="font-mono text-base font-semibold tracking-wider">{v.plate ?? "INGET REGNR"}</span>
                  <span className="text-sm text-muted-foreground">
                    {[v.color, v.model].filter(Boolean).join(" ") || "Okänd modell"}
                  </span>
                  {v.notes ? <span className="text-xs text-muted-foreground">{v.notes}</span> : null}
                </div>
                <div className="flex shrink-0 items-center">
                  <ActionButton
                    action={unlinkVehicle.bind(null, v.id, personId)}
                    variant="ghost"
                    size="icon-sm"
                    title="Koppla loss (fordonet finns kvar utan ägare)"
                    successMessage="Fordonet bortkopplat"
                  >
                    <UnlinkIcon />
                  </ActionButton>
                  <ActionButton
                    action={deleteVehicle.bind(null, v.id, personId)}
                    variant="ghost"
                    size="icon-sm"
                    title="Ta bort"
                    className="text-muted-foreground hover:text-destructive"
                    confirm={{
                      title: `Ta bort ${v.plate ?? "fordonet"}?`,
                      description: "Koppla loss i stället om du bara vill lossa det från personen.",
                      actionLabel: "Ta bort",
                      destructive: true,
                    }}
                    successMessage="Fordonet borttaget"
                  >
                    <Trash2Icon />
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
