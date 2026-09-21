import { DatabaseZapIcon, PlugZapIcon } from "lucide-react"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { SUPABASE_KEY_VARIABLES, SUPABASE_URL_VARIABLES } from "@/lib/supabase/env"

/** Shown when a database query fails; the usual cause right after setup is a missing migration. */
export function SetupHelp({ error }: { error: string }) {
  return (
    <Card className="border-amber-500/40">
      <CardHeader>
        <div className="flex items-center gap-2 text-amber-300">
          <DatabaseZapIcon className="size-5" />
          <CardTitle>Databasen är inte redo</CardTitle>
        </div>
        <CardDescription>
          Appen loggade in dig men kunde inte läsa underrättelsetabellerna. Om det här är ett nytt
          projekt: öppna SQL-editorn i Supabase, kör varje fil i{" "}
          <code className="font-mono text-xs">supabase/migrations/</code> i ordning och ladda om
          sidan.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <pre className="overflow-x-auto rounded-md bg-muted p-3 font-mono text-xs text-muted-foreground">
          {error}
        </pre>
      </CardContent>
    </Card>
  )
}

/** Shown on the login page when the deployment has no Supabase connection settings. */
export function SupabaseNotConfigured() {
  return (
    <Card className="w-full max-w-lg border-amber-500/40">
      <CardHeader>
        <div className="flex items-center gap-2 text-amber-300">
          <PlugZapIcon className="size-5" />
          <CardTitle>Den här driftsättningen är inte kopplad till Supabase</CardTitle>
        </div>
        <CardDescription>
          Servern hittar inte projektets adress och publika nyckel, så ingen kan logga in än.
        </CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-4 text-sm">
        <div>
          <p className="font-medium">Variabler som letas efter</p>
          <p className="text-muted-foreground">Adress: en av</p>
          <pre className="mt-1 rounded-md bg-muted p-2 font-mono text-xs">{SUPABASE_URL_VARIABLES.join("\n")}</pre>
          <p className="mt-2 text-muted-foreground">Nyckel: en av</p>
          <pre className="mt-1 rounded-md bg-muted p-2 font-mono text-xs">{SUPABASE_KEY_VARIABLES.join("\n")}</pre>
        </div>
        <div>
          <p className="font-medium">På Vercel</p>
          <p className="text-muted-foreground">
            Project Settings → Environment Variables. Varje variabel har kryssrutor för miljöer;
            kryssa i Production, Preview och Development. Driftsätt sedan om: Deployments → den
            senaste → Redeploy. Variabler slår igenom först vid en ny driftsättning.
          </p>
        </div>
        <div>
          <p className="font-medium">Lokalt</p>
          <p className="text-muted-foreground">
            Kopiera <code className="font-mono text-xs">.env.example</code> till{" "}
            <code className="font-mono text-xs">.env.local</code> och fyll i båda värdena.
          </p>
        </div>
      </CardContent>
    </Card>
  )
}
