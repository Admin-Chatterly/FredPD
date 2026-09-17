"use server"

import { z } from "zod"
import { redirect } from "next/navigation"
import { createClient } from "@/lib/supabase/server"
import { describeSignInError } from "@/lib/auth-errors"
import { isSupabaseConfigured } from "@/lib/supabase/env"
import { safeNextPath } from "@/lib/auth"

export type LoginState = { error?: string }

const loginSchema = z.object({
  email: z.email(),
  password: z.string().min(1),
  next: z.string().optional(),
})

export async function signIn(_prev: LoginState, formData: FormData): Promise<LoginState> {
  const parsed = loginSchema.safeParse({
    email: formData.get("email"),
    password: formData.get("password"),
    next: formData.get("next") ?? undefined,
  })
  if (!parsed.success) {
    return { error: "Fyll i e-postadress och lösenord." }
  }
  if (!isSupabaseConfigured()) {
    return { error: "Supabase är inte konfigurerat för den här driftsättningen. Se meddelandet på inloggningssidan." }
  }

  const supabase = await createClient()
  const { error } = await supabase.auth.signInWithPassword({
    email: parsed.data.email,
    password: parsed.data.password,
  })
  if (error) {
    return { error: describeSignInError(error) }
  }

  redirect(safeNextPath(parsed.data.next))
}

export async function signOut() {
  if (isSupabaseConfigured()) {
    const supabase = await createClient()
    await supabase.auth.signOut()
  }
  redirect("/login")
}
