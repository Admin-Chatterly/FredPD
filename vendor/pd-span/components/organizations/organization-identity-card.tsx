"use client"

import { useState } from "react"
import { MapPinIcon, PencilIcon } from "lucide-react"
import { OrganizationStatusBadge, OrganizationTypeBadge } from "@/components/badges"
import {
  OrganizationForm,
  type OrganizationFields,
} from "@/components/organizations/organization-form"
import { RelativeTime } from "@/components/relative-time"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"

type Organization = OrganizationFields & {
  created_at: string
  updated_at: string
}

export function OrganizationIdentityCard({
  organization,
  createdBy,
}: {
  organization: Organization
  createdBy: string | null
}) {
  const [editing, setEditing] = useState(false)

  return (
    <Card>
      <CardContent>
        {editing ? (
          <OrganizationForm
            mode="edit"
            organization={organization}
            onDone={() => setEditing(false)}
            onCancel={() => setEditing(false)}
          />
        ) : (
          <div className="flex flex-col gap-3 sm:flex-row sm:items-start">
            <div className="flex min-w-0 flex-1 flex-col gap-3">
              <div className="flex flex-wrap items-center gap-2">
                <h1 className="text-2xl font-semibold tracking-tight">{organization.name}</h1>
                <OrganizationTypeBadge type={organization.type} />
                <OrganizationStatusBadge status={organization.status} />
              </div>
              {organization.territory ? (
                <p className="flex items-center gap-1.5 text-sm text-muted-foreground">
                  <MapPinIcon className="size-4" /> {organization.territory}
                </p>
              ) : null}
              {organization.notes ? (
                <p className="whitespace-pre-wrap text-sm leading-relaxed">{organization.notes}</p>
              ) : (
                <p className="text-sm italic text-muted-foreground">Inga anteckningar om själva organisationen.</p>
              )}
              <p className="text-xs text-muted-foreground">
                Öppnad <RelativeTime iso={organization.created_at} />
                {createdBy ? ` av ${createdBy}` : ""} · ändrad{" "}
                <RelativeTime iso={organization.updated_at} />
              </p>
            </div>
            <Button variant="outline" size="sm" className="shrink-0" onClick={() => setEditing(true)}>
              <PencilIcon /> Ändra
            </Button>
          </div>
        )}
      </CardContent>
    </Card>
  )
}
