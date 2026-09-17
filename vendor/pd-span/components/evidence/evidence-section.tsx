import { AddEvidenceLinkDialog } from "@/components/evidence/add-evidence-link-dialog"
import { UploadEvidenceDialog } from "@/components/evidence/upload-evidence-dialog"
import { EvidenceCard } from "@/components/evidence/evidence-card"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import type { EvidenceRow, EvidenceTarget } from "@/lib/data/evidence"

export function EvidenceSection({ target, items }: { target: EvidenceTarget; items: EvidenceRow[] }) {
  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between">
        <CardTitle>Bevis</CardTitle>
        <div className="flex gap-2">
          <UploadEvidenceDialog target={target} />
          <AddEvidenceLinkDialog target={target} />
        </div>
      </CardHeader>
      <CardContent>
        {items.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            Inget bifogat. Ladda upp en skärmbild, eller klistra in ett Medal.tv-klipp, en
            videolänk eller en bildadress.
          </p>
        ) : (
          <ul className="flex flex-col gap-2">
            {items.map((item) => (
              <EvidenceCard key={item.id} item={item} />
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  )
}
