import Link from "next/link"
import { Button } from "@/components/ui/button"

export default function OrganizationNotFound() {
  return (
    <div className="flex flex-col items-center gap-3 py-24 text-center">
      <h1 className="text-xl font-semibold">Organisationen finns inte</h1>
      <Button asChild variant="secondary">
        <Link href="/organizations">Tillbaka till organisationer</Link>
      </Button>
    </div>
  )
}
