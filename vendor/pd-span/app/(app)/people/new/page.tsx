import Link from "next/link"
import { ArrowLeftIcon } from "lucide-react"
import { PersonForm } from "@/components/people/person-form"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"

export const metadata = { title: "Ny person" }

export default function NewPersonPage() {
  return (
    <div className="mx-auto flex w-full max-w-2xl flex-col gap-4">
      <Button asChild variant="ghost" size="sm" className="w-fit">
        <Link href="/people">
          <ArrowLeftIcon /> Personer
        </Link>
      </Button>
      <Card>
        <CardHeader>
          <CardTitle>Ny person</CardTitle>
          <CardDescription>
            Allt är frivilligt. Ett signalement räcker; fyll i namn, alias och kopplingar efter hand som
            uppgifterna kommer in.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <PersonForm mode="create" />
        </CardContent>
      </Card>
    </div>
  )
}
