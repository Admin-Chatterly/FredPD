# PD-span

Underrättelsetavla för en polisavdelning på en FiveM-rollspelsserver: personer
(med eller utan känd identitet), organisationer, uppgifter, fordon, ärenden och
kopplingarna mellan dem. En anslagstavla med snören, fast sökbar.

Teknik: Next.js 16 (App Router, Server Actions) · Supabase (Postgres, Auth,
Storage) · Tailwind 4 + shadcn/ui · Vercel.

## Kom igång

### 1. Supabase-projekt

Skapa ett projekt på supabase.com (gratisnivån räcker; Stockholm är närmaste
region). Sedan:

- **Schema.** Öppna SQL-editorn och kör varje fil i `supabase/migrations/` i
  namnordning, en hel fil i taget. Alternativt via CLI:
  `npx supabase link --project-ref <ref>` och därefter `npx supabase db push`.
- **Inloggning.** Authentication → Sign In / Providers → Email: påslaget.
  Authentication → Settings: slå **av** "Allow new users to sign up" så att bara
  konton du själv skapar kan logga in. Lägg till poliser under Authentication →
  Users → Add user (kryssa i auto-confirm). Ge någon ett anropsnamn genom att
  sätta deras user metadata till `{"callsign": "Enhet 12"}` när du skapar dem,
  eller redigera tabellen `profiles` efteråt.
- **Nycklar.** Project Settings → API: kopiera projektets adress och anon-
  eller publishable-nyckeln.

Frivilligt: `supabase/seed.sql` lägger in några påhittade personer, gäng, fordon,
uppgifter och ett ärende så att det finns något att klicka på. Ta bort dem när du
är klar.

### 2. Miljövariabler

```
NEXT_PUBLIC_SUPABASE_URL=https://<ref>.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=<anon- eller publishable-nyckel>
```

Sätt dem i Vercel-projektet (Settings → Environment Variables) och i
`.env.local` för lokal utveckling (se `.env.example`). Kryssa i **Production,
Preview och Development** för varje variabel i Vercel, annars körs
grenförhandsvisningar utan databas. Variabler slår igenom först vid en ny
driftsättning, så driftsätt om efter att du lagt till dem. Servern godtar även
Supabase-integrationens namn (`SUPABASE_URL`, `SUPABASE_ANON_KEY`). En
okonfigurerad driftsättning visar en installationsnotis på inloggningssidan i
stället för att krascha.

### 3. Driftsättning

Vercel-projektet är kopplat till det här GitHub-repot; pushar till `main`
driftsätts till produktion, andra grenar får förhandsadresser.

## Utveckling

```
pnpm install
pnpm dev          # http://localhost:3000
pnpm check        # eslint + tsc
pnpm build
```

Schemaändringar läggs i en ny fil under `supabase/migrations/`. För att
validera hela schemat mot en slask-Postgres lokalt (kräver `psql` och en
server):

```
DATABASE_URL=postgresql://postgres@127.0.0.1:5432/pdspan_check pnpm db:check
```

Det kör `supabase/dev/shim.sql` (ersättare för Supabases auth- och
storage-scheman), varje migration, seeden och kontrollerna i
`supabase/dev/checks.sql`. Det släpper public-schemat först, så peka aldrig
detta mot ett riktigt projekt.

`pnpm db:check:postgrest` går ett steg längre och kör appens eget datalager,
och de frågeformer dess Server Actions använder, genom en riktig PostgREST mot
samma databas. Det är kontrollen som fångar det TypeScript inte kan: inbäddade
select-satser, ledtrådar för främmande nycklar, filtren `or()` och
`contains()`, RPC-argumentnamn och felkoder.

```
POSTGREST_BIN=/sökväg/till/postgrest \
DATABASE_URL=postgresql://postgres@127.0.0.1:5432/pdspan_check \
pnpm db:check:postgrest
```

Binären är en enda statisk fil från
[PostgRESTs releaser](https://github.com/PostgREST/postgrest/releases);
Linux-filen heter `postgrest-<version>-linux-static-x86-64.tar.xz`. Samma skript
körs mot det skarpa projektet när `NEXT_PUBLIC_SUPABASE_URL`,
`NEXT_PUBLIC_SUPABASE_ANON_KEY`, `E2E_EMAIL` och `E2E_PASSWORD` är satta:
`pnpm exec tsx supabase/dev/postgrest-check.ts`. Det städar upp allt det skapar.

`lib/database.types.ts` är skriven för hand så att den matchar migrationerna.
När du har en databasadress kan du generera om den:
`SUPABASE_DB_URL=postgresql://... pnpm types:gen`.

## Datamodell

| Tabell | Vad det är |
| --- | --- |
| `people` | Misstänkta och personer av intresse. Alla fält utom `id` är frivilliga; en rad kan bestå av enbart ett signalement. `status` är ett av värdena i `lib/constants.ts`. Ett foto, när det finns, ligger i den privata lagringen precis som bevis. |
| `organizations` | Gäng, ligor, karteller, företag. |
| `memberships` | Personer ↔ organisationer, med roll och en flagga för bekräftat/misstänkt. Hanteras från båda hållen. |
| `associates` | Person ↔ person-kopplingar, oriktade, en rad per par. |
| `notes` | Underrättelseloggen. Kopplas till en person, en organisation, ett ärende, valfri blandning, eller ingenting alls — vilket är hur ett tips hamnar i registret innan någon vet vem det handlar om. Taggar, källa, tillförlitlighet och vem som skrev det (från sessionen). Bläddra och filtrera allt på `/intel`. |
| `vehicles` | Registreringsnummer och modeller, valfritt knutna till en person. Skyltar lagras med versaler. |
| `cases` / `case_links` | En utredning och personerna och organisationerna i den, var och en med en roll i just det ärendet. En koppling pekar på exakt en av de två, vilket databasen upprätthåller. |
| `evidence` | Antingen en uppladdad bild i den privata lagringen `intel` eller en extern länk (Medal.tv-klipp, YouTube, Streamable, bildadresser), kopplad till en person, organisation eller ett ärende. Klipplänkar spelas upp direkt i sidan; uppladdningar visas via kortlivade signerade adresser och blir aldrig publika. |
| `profiles` | En rad per inloggning, med polisens anropsnamn. |

Att radera en organisation behåller underrättelserna: uppgifter kopplas loss i
stället för att raderas, och medlemmarna behåller sina egna poster. Medlemskap,
ärendekopplingar och bevis som hänger på organisationen följer med den.

Taggar finns bara på uppgifter, så alla taggfilter i appen går genom dem:
`/intel?tag=x` för underrättelserna själva, `/people?tag=x` och
`/organizations?tag=x` för alla som har en uppgift med den taggen.

Ctrl+K (eller cmd+K) öppnar en enda sökning över personer, alias, signalement,
registreringsnummer, territorier, uppgiftstexter och taggar, grupperad per typ.
Träffar som saknar egen sida, ett fordon eller en uppgift, öppnar posten de hör
till.

`/board` ritar anslagstavlan: personer och organisationer som noder, medlemskap
och kontakter som kanter, utlagda av en kraftsimulering och klickbara vidare
till varje post. En graf över hela servern är oläslig, så tavlan avgränsas till
ett ärende eller en organisation, med alla i registret tillgängligt när du
uttryckligen väljer det. Kanter ritas bara mellan noder som finns på tavlan, så
en koppling pekar aldrig på något utanför bilden.

Vyerna `people_overview`, `organizations_overview` och `cases_overview` ligger
bakom listsidorna. Funktioner: `search_all(term)` för global sökning,
`merge_people(keep, drop)` för att slå ihop en dubblett (till exempel en okänd
post som visar sig vara någon som redan finns i registret) med en annan post,
och `distinct_tags()` för taggfiltret.

## Åtkomstmodell

Varje tabell har Row Level Security påslaget. Bara inloggade användare (rollen
`authenticated`) kan läsa eller skriva; anon-nyckeln ser ingenting.
Lagringsutrymmet är privat: uppladdningar går direkt från webbläsaren till
Storage, så en stor bild passerar aldrig servern, och de läses bara tillbaka via
signerade adresser som skapas per anrop. Sidans proxy skickar anonyma besökare
till `/login`, och varje Server Action kontrollerar sessionen på nytt.
