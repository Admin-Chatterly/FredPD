# FredPD — installation och driftsättning

Teknisk guide för dig som sätter upp FredPD på servern. Handboken för poliser
finns i [`handbok.sv.md`](handbok.sv.md).

> **Läge just nu:** M0 är klart och M1 pågår. Det som fungerar i dag är
> behörigheter, placeringar i världen, den interna polischatten, fordonsdepån
> och **underrättelsemodulen** (avsnitt 11b). Register, ledningscentral, bevis,
> laboratorium och domstol kommer i M2–M6 (se avsnitt 17 i `FredPD.md`).
>
> **Hela installationen är fyra saker:** kopiera resursen, fyll i
> `config/server.lua`, kör en SQL-fil, och kör uppstartskommandot i spelet.
> Inga convars, ingen Node-tjänst, inget cron-jobb (ADR-010).

---

## 1. Krav

### På spelservern

| Resurs | Krävs? | Används till |
| --- | --- | --- |
| `es_extended` (ESX) | **Ja** | Karaktärer, namn, jobb |
| `ox_lib` | **Ja** | Callbacks, menyer, dialoger |
| `oxmysql` | **Ja** | Databasåtkomst |
| `p_policejob` | Nej | Tjänstestatus, grad, beslag |
| `esx_society` | Nej | Fordonsdepån registrerar bilar på myndigheten |
| `esx_textui` | Nej | "Tryck E"-rutan (annars används ox_lib) |
| `esx_menu_dialog` | Nej | Menyer i världen (annars används ox_lib) |

De fyra sista är frivilliga. Saknas någon av dem loggar FredPD en varning vid
start och fortsätter — varje villkor de svarar på faller då tillbaka till
"nej", aldrig till "ja".

### På maskinen

- **MariaDB 11.4** eller nyare (samma databas som ESX använder — FredPD:s
  tabeller har prefixet `fpd_` och krockar inte).
- **Node.js 24** (se `.nvmrc`) och **pnpm**, för att bygga gränssnittet.
- Git.

---

## 2. Steg 1 — Hämta och bygg

Gränssnittet (MDT:n) är ett Svelte-projekt som byggs in i resursen. Det ligger
inte färdigbyggt i repot, så **bygget måste köras innan resursen startas**,
annars finns ingen `web/dist` och FiveM hittar ingen `ui_page`.

```bash
git clone https://github.com/Admin-Chatterly/FredPD.git
cd FredPD

pnpm install
pnpm build
```

`pnpm build` gör tre saker i tur och ordning: genererar Lua-schemat från
TypeScript, bygger MDT:n till `resources/[fredpd]/fredpd/web/dist`, och bygger
gateway-tjänsten.

Kopiera sedan mappen `resources/[fredpd]/` till serverns resursmapp.

---

## 3. Steg 2 — Databas

Två filer, i den här ordningen — hela schemat ligger i en enda migration:

```bash
mysql -u root DITT_ESX_SCHEMA < database/migrations/0001_fredpd.sql
mysql -u root DITT_ESX_SCHEMA < database/seeds/0001_permissions.sql
```

Kommer det fler migrationer i senare versioner körs de i nummerordning efter
den här. Då går det lika bra att köra hela mappen — inget händer när en
migration körs igen:

```bash
for f in database/migrations/*.sql; do mysql -u root DITT_ESX_SCHEMA < "$f"; done
for f in database/seeds/*.sql;      do mysql -u root DITT_ESX_SCHEMA < "$f"; done
```

Migrationerna är **append-only**: en fil som en gång körts ändras aldrig, den
rättas med en ny migration. Seed-filen går att köra om hur många gånger som
helst utan att det blir dubbletter.

Alla tabeller heter `fpd_*`, så inget i ditt befintliga ESX-schema rörs.

Seed-filen skapar behörighets**grupperna**, men kopplar inga Discord-roller till
dem. Roll-ID:n är unika för just din Discord-server, så den kopplingen görs i
spelet (steg 7). En nyinstallerad server ger därför ingen behörighet till någon
förrän du gjort det — vilket är rätt utgångsläge.

### Grupper som seedas

| Grupp | Ärver | Ger |
| --- | --- | --- |
| `patrol_basic` | — | Läsa MDT:n, interna kanalen |
| `patrol` | `patrol_basic` | Fordonsdepån, slagningar |
| `supervisor` | `patrol` | Se alla myndigheters chattrafik |
| `command` | `supervisor` | Loggboken, personal |
| `dispatch` | `patrol_basic` | Ledningsplatsen |
| `admin` | — | Konfigurera FredPD |
| `intel_analyst` | — | Läsa och skriva underrättelseregistret |
| `intel_handler` | `intel_analyst` | Dessutom se skyddade källor och slå ihop dubbletter |
| `intel_command` | `intel_handler` | Dessutom radera poster ur registret |

`admin` ärver medvetet **inte** `patrol`. Att administrera systemet är inte
samma sak som att vara behörig att läsa register. Behöver du båda sakerna ger du
dig själv båda grupperna, synligt och avsiktligt.

---

## 4. Steg 3 — server.cfg

Starta beroendena före FredPD:

```cfg
ensure ox_lib
ensure oxmysql
ensure es_extended

ensure fredpd
ensure fredpd_assets
ensure fredpd_forensics
ensure fredpd_surveillance
```

Inga convars behövs. All konfiguration ligger i en enda fil — se nästa steg.

> Kör inte `ensure fredpd_forensics` eller `fredpd_surveillance` ännu. De är
> tomma skal för M3 och M5 och kräver `ox_target` respektive `pma-voice`, så
> utan dem vägrar FXServer starta dem och fyller konsolen med fel som ser ut som
> en trasig installation.

---

## 5. Steg 4 — Konfigurationsfilen

**Det här är den enda filen du redigerar:**
`resources/[fredpd]/fredpd/config/server.lua`.

Den ligger i `server_scripts` och står *inte* i `files {}`, så ingenting i den
når spelarna — därför får bottoken bo där (invariant 7).

### Skapa Discord-botten (en gång, ca 3 minuter)

1. <https://discord.com/developers/applications> → **New Application**
2. **Bot** → **Reset Token** → kopiera token
3. **Bot** → **Privileged Gateway Intents** → slå på **SERVER MEMBERS INTENT**
4. **Installation** → bjud in botten till din Discord-server (den behöver inga
   rättigheter alls — den läser bara medlemslistan)

Guild-ID: högerklicka servern i Discord → **Kopiera server-ID**. Kräver
Utvecklarläge: Inställningar → Avancerat → Utvecklarläge.

### Fyll i

```lua
discord = {
    token   = 'DIN_BOT_TOKEN',
    guildId = 'DITT_GUILD_ID',
    refreshMinutes = 10,
    ...
},

agency = {
    id        = 'lspd',
    name      = 'Los Santos Police Department',
    shortName = 'LSPD',
},
```

Språk och tidszon står i `config/shared.lua` och är redan satta till `sv` och
`Europe/Stockholm`.

I `production` vägrar resursen starta utan token, guild-ID och myndighet. Utan
dem får nämligen ingen någon behörighet alls, och det är svårare att felsöka än
en server som inte startar.

**Gateway-tjänsten behöver du inte.** Den är avstängd som standard och FXServer
anropar den aldrig. Rollsynken sköts numera av resursen själv (ADR-010). Node
behövs bara för att *bygga* gränssnittet, inte för att köra det.

---

## 6. Steg 5 — Uppstart

Ingen SQL. Starta resursen och läs konsolen:

```
[fredpd] ------------------------------------------------------------
[fredpd] This install is not set up yet.
[fredpd] Join the server, then type this in the game chat:
[fredpd]     /fredpd setup K7M2QX
[fredpd] Or run `fredpd_setup` here in the console while you are in game.
[fredpd] ------------------------------------------------------------
```

Gå in i spelet och skriv `/fredpd setup K7M2QX` i chatten. Då skapas
myndigheten, du läggs in i personalregistret med det Discord-ID FiveM redan
känner dig som, och **alla** dina Discord-roller kopplas till `admin`-gruppen.

Koden skrivs bara ut i serverkonsolen. Det är hela poängen: på en publik server
ska inte den första som gissar kommandot bli administratör. Har du konsolen
framme går det lika bra att köra `fredpd_setup` där medan du är inne i spelet —
då behövs ingen kod.

Uppstarten vägrar så fort det finns någon i `fpd_officers`. Det finns exakt en
första gång.

> `fpd_discord_members` fylls av rollsynken i `server/core/discord.lua`, som
> uppdaterar hela guilden med några minuters mellanrum och varje spelare när
> hen ansluter. Du ska aldrig röra den tabellen för hand, och framför allt
> aldrig sätta `synced_at` med ett schemalagt jobb — den kolumnen är hur FredPD
> avgör om rollistan alls går att lita på (avsnitt 4.2).

---

## 7. Steg 6 — Fordonsflottan

Fordonsdepån visar inga bilar förrän du lagt in dem. Det finns ingen
flotteditor i gränssnittet ännu, så raderna läggs in i databasen.

```sql
INSERT INTO fpd_fleet (agency_id, model, label_key, permission, certification, livery, sort_order)
VALUES
    ('lspd', 'police',  'fleet.cruiser',     NULL,             NULL,   0, 10),
    ('lspd', 'police2', 'fleet.interceptor', 'garage.pursuit', NULL,   0, 20),
    ('lspd', 'polmav',  'fleet.helicopter',  NULL,             'air',  0, 90);
```

| Kolumn | Betydelse |
| --- | --- |
| `model` | Spawn-namnet i GTA |
| `label_key` | **Språknyckel**, inte ett namn — se varningen nedan |
| `permission` | Extra behörighet utöver `garage.vehicle.draw` |
| `certification` | Krävd behörighetsbevis. Certifieringar byggs i M6, så en rad med värde här visas inte för någon ännu |
| `livery` | Lackering, eller `NULL` |
| `sort_order` | Ordning i menyn |

> **`label_key` går genom språkfilerna.** Skriver du `'Polisbil'` direkt i
> kolumnen visas texten `Polisbil` som en saknad nyckel, inte som ett namn. Lägg
> till nyckeln i **både** `locales/en.json` och `locales/sv.json`:
>
> ```json
> "fleet": {
>   "cruiser": "Radiobil",
>   "interceptor": "Civil snabbgående",
>   "helicopter": "Helikopter"
> }
> ```
>
> Kör sedan `pnpm i18n:check` — den fäller bygget om en nyckel saknas i något av
> språken.

---

## 8. Steg 7 — Placera ut systemet i världen

Ingenting har koordinater i en konfigurationsfil. Terminaler, laboratoriebänkar
och fordonsdepåns tjänsteman placeras ut i spelet, av dig, där de faktiskt ska
stå.

Gå in i spelet och skriv `/fredpd placement`:

| Val | Gör |
| --- | --- |
| **Ny här — område** | En cirkel på marken, utan föremål |
| **Ny här — koppla till föremålet jag tittar på** | Riktar du blicken rakt mot en skrivbordsdator kopplas terminalen exakt dit |
| **Ny här — placera en person** | Skapar en gestalt. Så här görs fordonsdepån. Frågar efter modellnamn, t.ex. `s_m_y_cop_01` |
| **Flytta den närmaste hit** | |
| **Stäng av den närmaste** | Stänger av utan att radera |
| **Ta bort den närmaste** | Kräver bekräftelse |

Därefter väljer du vad placeringen ska öppna: stationsterminal, terminal i
beslagsrummet, laboratorieterminal, terminal för inskrivning, ledningsplats,
terminal i domstolen, fordonsdepå eller bevisbänk.

**En placering är en ingång, aldrig en behörighet.** Att koppla ett föremål till
laboratorieterminalen ger ingen tillgång till laboratoriet — det avgörs
fortfarande av Discord-rollerna, på servern. Tar du bort en placering tar du bort
en dörr, inte en behörighet.

Servern kontrollerar dessutom att spelaren verkligen står vid placeringen när ett
anrop görs "därifrån". Utan den kontrollen vore "bara i beslagsrummet" inte värt
någonting, eftersom vilken klient som helst kunde påstå sig stå där.

---

## 9. Steg 8 — Resten av rollerna

Öppna MDT:n och gå till **Administration → Discord-roller**. Klistra in roll-ID,
välj behörighetsgrupp, tryck Lägg till.

Det slår igenom omedelbart för alla som är inloggade: ger du någon en roll dyker
sidorna upp utan omstart, tar du bort den försvinner de direkt.

En administratör kan **inte** dela ut mer än hen själv har. Försöker du koppla en
roll till en grupp som är värd mer än din egen behörighet vägras det och
antecknas i loggboken.

---

## 10. Felsökning

| Symptom | Orsak |
| --- | --- |
| Konsolen upprepar *"This install is not set up yet"* | Uppstarten är inte körd. Den skrivs ut vid varje start tills den lyckats |
| *"Fel uppstartskod"* | Koden byts vid varje omstart av resursen. Ta den senaste ur konsolen |
| *"Du har inga roller i den Discord-servern"* | Botten ser dig, men du har ingen roll. Ge dig själv en och kör uppstarten igen |
| *"Discord gick inte att nå"* | Fel token eller guild-ID, eller så saknar botten **Server Members**-intentet |
| *"Du är inte inloggad"* när MDT:n öppnas | Du saknas i `fpd_officers`, eller står på en annan karaktär än den som är knuten till kontot |
| MDT:n öppnas men listan till vänster är tom | Ingen av dina roller är kopplad till en grupp |
| *"Dina Discord-roller ger inte behörighet"* på `/fredpd placement` | Din roll saknar `admin`-gruppen |
| *"Dina behörigheter är inaktuella"* | Rollsynken har inte lyckats på över 15 minuter. Konsolen skriver ut varför |
| Ingenting syns ute i världen | Inga placeringar är skapade ännu. Det är det normala utgångsläget |
| Fordonsdepån är tom | `fpd_fleet` saknar rader för din myndighet (steg 7) |
| Fordonsmenyn visar `fleet.cruiser` i stället för ett namn | Språknyckeln saknas i `en.json`/`sv.json` |
| Resursen startar inte, klagar på tabeller | Migrationen är inte körd |
| Resursen startar inte i produktion | `discord.token`, `discord.guildId` eller `agency` saknas i `config/server.lua` |

Loggboken (`fpd_audit_log`) innehåller även nekade försök, med skäl. Den är ofta
snabbaste vägen till varför något vägras.

---

## 11. Vid utveckling

```bash
pnpm dev:web      # MDT:n i en vanlig webbläsare, mot testdata — ingen spelserver
pnpm check        # eslint, typkontroll, svelte-check, språkfiler
pnpm test         # enhetstester (Vitest)
pnpm test:lua     # enhetstester för Lua (busted)
pnpm lint:lua     # luacheck
pnpm test:e2e     # gränssnittstester i webbläsare (Playwright)
pnpm schema:gen   # generera om Lua-schemat — checka in resultatet
```

`pnpm dev:web` är snabbaste sättet att se gränssnittet. Det kör mot fasta
testdata utan spelserver. Frågeparametrar: `?locale=sv`, `?latency=400`,
`?fail=forbidden`.

---

## 11b. Underrättelsemodulen

Underrättelseregistret — personer, organisationer, uppgifter, fordon, ärenden
och kopplingarna mellan dem — ligger i serverns egen databas (tabellerna
`fpd_intel_*`, som skapas av samma migration som resten). Det som tidigare låg
i PD-Span finns nu här och sparas på servern.

Den befintliga datan i PD-Span flyttas **inte** över: modulen börjar tom och
registret byggs upp i spelet.

Två saker skiljer den från PD-Span, båda avsiktligt:

- **Skyddade källor.** En uppgift från en informatör, telefonavlyssning eller
  spaning visar *att* den har en källa, men inte vilken, för den som saknar
  `intel.source.view`. Själva uppgiften är fortfarande läsbar. I PD-Span såg
  alla med ett konto varje källa.
- **Läsningar loggas.** Att öppna en person eller lista registret hamnar i
  loggboken. PD-Span kunde inte svara på vem som läst vad.

Ge någon behörighet genom att koppla en Discord-roll till `intel_analyst`,
`intel_handler` eller `intel_command` i MDT:n.

## 12. Vad som inte är byggt ännu

Var beredd på det här — det är inte fel, det är kommande milstolpar:

- **Migrationskörare.** Migrationen körs för hand tills vidare.
- **Flotteditor i gränssnittet.** `fpd_fleet` redigeras i databasen.
- **Tomma sidor i listan.** Ger du någon `patrol` eller `dispatch` dyker
  *Register* och *Kommunikation* upp i listan till vänster utan att ha någon
  sida bakom sig ännu.
- **Certifieringar** (M6). En flottrad med `certification` visas för ingen ännu.
- **Register, ledningscentral, bevis, laboratorium, domstol** — M2 till M6.
- **Länkdiagrammet** (`/board` i PD-Span) är ännu inte byggt i MDT:n.
- **Uppladdade bilder som bevis** kräver gateway-tjänstens mediadel, som inte är
  byggd. Externa länkar (Medal, YouTube, Streamable, bildadresser) fungerar.
- **Beslag** ligger kvar hos `p_policejob` och är inte tänkt att flytta.

Ingenting av Lua-koden har ännu körts på en riktig FiveM-server. Logiken täcks av
enhetstester, men de delar som använder spelets egna funktioner — att skapa
gestalter, sikta på föremål, ta fokus till gränssnittet — är oprövade i skarpt
läge. Räkna med att det är där de första problemen dyker upp.
