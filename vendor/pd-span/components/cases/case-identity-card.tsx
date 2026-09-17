"use client"

import { useState } from "react"
import { PencilIcon } from "lucide-react"
import { CaseStatusBadge } from "@/components/badges"
import { CaseForm, type CaseFields } from "@/components/cases/case-form"
import { RelativeTime } from "@/components/relative-time"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"

type CaseRecord = CaseFields & { created_at: string; updated_at: string }

export function CaseIdentityCard({
  caseRecord,
  createdBy,
  counts,
}: {
  caseRecord: CaseRecord
  createdBy: string | null
  counts: { people: number; organizations: number; notes: number }
}) {
  const [editing, setEditing] = useState(false)

  return (
    <Card>
      <CardContent>
        {editing ? (
          <CaseForm
            mode="edit"
            caseRecord={caseRecord}
            onDone={() => setEditing(false)}
            onCancel={() => setEditing(false)}
          />
        ) : (
          <div className="flex flex-col gap-3 sm:flex-row sm:items-start">
            <div className="flex min-w-0 flex-1 flex-col gap-3">
              <div className="flex flex-wrap items-center gap-2">
                <h1 className="text-2xl font-semibold tracking-tight">{caseRecord.title}</h1>
                <CaseStatusBadge status={caseRecord.status} />
              </div>
              {caseRecord.description ? (
                <p className="whitespace-pre-wrap text-sm leading-relaxed">
                  {caseRecord.description}
                </p>
              ) : (
                <p className="text-sm text-muted-foreground italic">Ingen beskrivning än.</p>
              )}
              <p className="text-xs text-muted-foreground">
                {counts.people} {counts.people === 1 ? "person" : "personer"} ·{" "}
                {counts.organizations}{" "}
                {counts.organizations === 1 ? "organisation" : "organisationer"} · {counts.notes}{" "}
                {counts.notes === 1 ? "uppgift" : "uppgifter"}
              </p>
              <p className="text-xs text-muted-foreground">
                Öppnat <RelativeTime iso={caseRecord.created_at} />
                {createdBy ? ` av ${createdBy}` : ""} · uppdaterat{" "}
                <RelativeTime iso={caseRecord.updated_at} />
              </p>
            </div>
            <Button variant="outline" size="sm" onClick={() => setEditing(true)}>
              <PencilIcon /> Redigera ärende
            </Button>
          </div>
        )}
      </CardContent>
    </Card>
  )
}
