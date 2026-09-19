"use client"

import { useState } from "react"
import { PlusIcon } from "lucide-react"
import { OrganizationForm } from "@/components/organizations/organization-form"
import { Button } from "@/components/ui/button"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog"

export function NewOrganizationDialog() {
  const [open, setOpen] = useState(false)
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button>
          <PlusIcon /> Ny organisation
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Ny organisation</DialogTitle>
          <DialogDescription>
            Gäng, liga, kartell eller företag. Bara namnet krävs.
          </DialogDescription>
        </DialogHeader>
        <OrganizationForm mode="create" />
      </DialogContent>
    </Dialog>
  )
}
