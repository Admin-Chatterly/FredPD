"use client"

import { useActionState } from "react"
import { LoaderCircleIcon, ShieldIcon } from "lucide-react"
import { signIn, type LoginState } from "@/app/login/actions"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"

const initialState: LoginState = {}

export function LoginForm({ next, notice }: { next: string; notice?: string | null }) {
  const [state, formAction, pending] = useActionState(signIn, initialState)

  return (
    <Card className="w-full max-w-sm">
      <CardHeader className="text-center">
        <div className="mx-auto mb-2 flex size-12 items-center justify-center rounded-full bg-primary/15 text-primary">
          <ShieldIcon className="size-6" />
        </div>
        <CardTitle className="text-xl">PD-span Underrättelser</CardTitle>
        <CardDescription>Behörighet krävs. Logga in med ditt tjänstekonto.</CardDescription>
      </CardHeader>
      <CardContent>
        <form action={formAction} className="flex flex-col gap-4">
          <input type="hidden" name="next" value={next} />
          {notice && !state.error ? (
            <p role="status" className="rounded-md bg-amber-500/10 px-3 py-2 text-sm text-amber-300">
              {notice}
            </p>
          ) : null}
          <div className="flex flex-col gap-2">
            <Label htmlFor="email">E-post</Label>
            <Input
              id="email"
              name="email"
              type="email"
              autoComplete="username"
              required
              autoFocus
            />
          </div>
          <div className="flex flex-col gap-2">
            <Label htmlFor="password">Lösenord</Label>
            <Input
              id="password"
              name="password"
              type="password"
              autoComplete="current-password"
              required
            />
          </div>
          {state.error ? (
            <p role="alert" className="text-sm text-destructive">
              {state.error}
            </p>
          ) : null}
          <Button type="submit" disabled={pending} className="w-full">
            {pending ? <LoaderCircleIcon className="animate-spin" /> : null}
            Logga in
          </Button>
        </form>
      </CardContent>
    </Card>
  )
}
