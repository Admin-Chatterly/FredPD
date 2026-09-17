"use client"

import { useState } from "react"
import { PlusIcon } from "lucide-react"
import { CaseForm } from "@/components/cases/case-form"
import { Button } from "@/components/ui/button"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog"

export function NewCaseDialog() {
  const [open, setOpen] = useState(false)
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button>
          <PlusIcon /> Nytt ärende
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Nytt ärende</DialogTitle>
          <DialogDescription>
            En utredning som samlar de personer och organisationer som är inblandade.
          </DialogDescription>
        </DialogHeader>
        <CaseForm mode="create" />
      </DialogContent>
    </Dialog>
  )
}
