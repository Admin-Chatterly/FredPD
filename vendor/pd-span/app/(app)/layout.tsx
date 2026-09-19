import { redirect } from "next/navigation"
import { SiteHeader } from "@/components/layout/site-header"
import { getCurrentProfile } from "@/lib/auth"

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const profile = await getCurrentProfile()
  if (!profile) redirect("/login")

  return (
    <div className="flex min-h-full flex-1 flex-col">
      <SiteHeader callsign={profile.callsign} />
      <main className="mx-auto w-full max-w-6xl flex-1 px-4 py-6 sm:px-6">{children}</main>
    </div>
  )
}
