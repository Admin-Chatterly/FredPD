/** Shape shared by every form action driven through useActionState. */
export type FormState = {
  ok?: boolean
  error?: string
  /** Bumped on success so forms can reset themselves. */
  version?: number
}

export type ActionResult = { ok: true } | { ok: false; error: string }
