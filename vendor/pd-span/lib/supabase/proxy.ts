import { createServerClient } from "@supabase/ssr"
import { NextResponse, type NextRequest } from "next/server"
import { getSupabaseEnv, isSupabaseConfigured } from "@/lib/supabase/env"

const PUBLIC_PATHS = ["/login"]

function isPublicPath(pathname: string): boolean {
  return PUBLIC_PATHS.some((p) => pathname === p || pathname.startsWith(`${p}/`))
}

/**
 * `reason` is a fixed code, never a message from the auth server: the login
 * page maps it to its own text, so nothing attacker-supplied is ever shown.
 */
function redirectToLogin(request: NextRequest, reason?: "session") {
  const { pathname } = request.nextUrl
  const loginUrl = request.nextUrl.clone()
  loginUrl.pathname = "/login"
  loginUrl.search = ""
  if (pathname !== "/") {
    loginUrl.searchParams.set("next", `${pathname}${request.nextUrl.search}`)
  }
  if (reason) loginUrl.searchParams.set("reason", reason)
  return NextResponse.redirect(loginUrl)
}

/** Supabase stores the session in sb-<ref>-auth-token, sometimes split into .0/.1 chunks. */
function hasAuthCookie(request: NextRequest): boolean {
  return request.cookies.getAll().some((c) => /^sb-.+-auth-token(\.\d+)?$/.test(c.name))
}

/**
 * Runs on every request (see proxy.ts): refreshes the Supabase session cookie
 * and redirects anonymous visitors to /login. Server Actions and pages still
 * verify the user themselves; this is the outer wall, not the only one.
 */
export async function updateSession(request: NextRequest) {
  const { pathname } = request.nextUrl
  const isPublic = isPublicPath(pathname)

  // Without connection settings nothing can be verified. Rather than failing
  // every request, send visitors to the login page, which explains what is
  // missing.
  if (!isSupabaseConfigured()) {
    return isPublic ? NextResponse.next({ request }) : redirectToLogin(request)
  }

  let response = NextResponse.next({ request })
  const { url, key } = getSupabaseEnv()

  const supabase = createServerClient(url, key, {
    cookies: {
      getAll() {
        return request.cookies.getAll()
      },
      setAll(cookiesToSet) {
        cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value))
        response = NextResponse.next({ request })
        cookiesToSet.forEach(({ name, value, options }) =>
          response.cookies.set(name, value, options)
        )
      },
    },
  })

  // getClaims verifies the JWT locally (cached JWKS) instead of a round trip.
  const { data, error } = await supabase.auth.getClaims()
  let isSignedIn = !error && Boolean(data?.claims?.sub)

  if (!isSignedIn && error) {
    // Local verification can fail for reasons that say nothing about the
    // session itself, such as an unreachable JWKS endpoint. The auth server is
    // authoritative, so ask it before throwing the officer out.
    const { data: userData, error: userError } = await supabase.auth.getUser()
    isSignedIn = !userError && Boolean(userData?.user)
  }

  // A browser that sent a session cookie and still ends up anonymous was signed
  // out by something it cannot see: an expired session, a cookie left over from
  // another Supabase project, a verification failure. Say so, rather than
  // bouncing it back to an empty form. Visitors with no cookie are just
  // anonymous, which is the ordinary path and gets no message.
  const unverifiable = !isSignedIn && hasAuthCookie(request)

  if (!isSignedIn && !isPublic) {
    return redirectToLogin(request, unverifiable ? "session" : undefined)
  }

  if (isSignedIn && isPublic) {
    const homeUrl = request.nextUrl.clone()
    homeUrl.pathname = "/"
    homeUrl.search = ""
    return NextResponse.redirect(homeUrl)
  }

  return response
}
