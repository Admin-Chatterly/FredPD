# FredPD — installation och driftsättning

Teknisk guide för dig som sätter upp FredPD på servern. Handboken för poliser
finns i [`handbok.sv.md`](handbok.sv.md).

> **Läge just nu:** M0 är klart och M1 pågår. Det som fungerar i dag är
> behörigheter, placeringar i världen, den interna polischatten och
> fordonsdepån. Register, ledningscentral, bevis, laboratorium och domstol
> kommer i M2–M6 (se avsnitt 17 i `FredPD.md`).
>
> **Discord-boten är ännu inte byggd.** Tills den är det måste rollerna föras in
> för hand i `fpd_discord_members` — se steg 6. Utan den raden får ingen
> behörighet till någonting.

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

Kör migrationerna i nummerordning, och därefter seed-filerna:

```bash
for f in database/migrations/*.sql; do mysql -u root DITT_ESX_SCHEMA < "$f"; done
for f in database/seeds/*.sql;      do mysql -u root DITT_ESX_SCHEMA < "$f"; done
```

Migrationerna är **append-only**: en fil som en gång körts ändras aldrig, den
rättas med en ny migration. Seed-filerna går att köra om hur många gånger som
helst utan att det blir dubbletter.

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

Lägg till convars:

```cfg
## Miljö: development | staging | production
set fredpd:env production

## Delad hemlighet mot gateway-tjänsten.
## Använd `set`, ALDRIG `setr` — `setr` skickar värdet till varje spelare.
## Skapa en med: openssl rand -hex 32
set fredpd:gateway_secret "DIN_HEMLIGHET"
set fredpd:gateway_url    "http://127.0.0.1:3080"

## Din Discord-server (guild-ID).
set fredpd:discord_guild "DITT_GUILD_ID"

## Dessa två läses även av klienten och måste därför vara `setr`.
setr fredpd:locale sv
setr fredpd:timezone Europe/Stockholm
```

I `production` vägrar resursen starta om `fredpd:gateway_secret` eller
`fredpd:discord_guild` saknas. I `development` startar den ändå, med en varning
i konsolen, så att gränssnittet går att arbeta med utan gateway.

---

## 5. Steg 4 — Gateway-tjänsten

Gateway:n är en Node-tjänst som körs på samma maskin och sköter Discord-synk,
media, PDF och schemalagda jobb. Den lyssnar bara på `127.0.0.1`.

```bash
cp .env.example .env
```

Fyll i:

```
FREDPD_ENV=production
FREDPD_GATEWAY_HOST=127.0.0.1
FREDPD_GATEWAY_PORT=3080

# Måste vara exakt samma sträng som `set fredpd:gateway_secret` i server.cfg.
FREDPD_GATEWAY_SECRET=DIN_HEMLIGHET

DISCORD_BOT_TOKEN=
DISCORD_GUILD_ID=

DATABASE_URL=mysql://användare:lösenord@127.0.0.1:3306/ditt_schema
```

Starta:

```bash
node gateway/dist/index.js
```

Tjänsten vägrar starta utan hemlighet — en osignerad gateway skulle låta vad som
helst på maskinen ändra roller och skapa mediatokens.

Lägg den under systemd i skarp drift, med automatisk omstart. Hälsokontroll:
`curl http://127.0.0.1:3080/health`.

> Discord-boten som fyller `fpd_discord_members` är **inte byggd ännu**. Tills
> den är det gör gateway-tjänsten ingen nytta för behörigheterna, och steg 6
> nedan är hur du kommer runt det.

---

## 6. Steg 5 — Grundregistrering

Fyra rader, en gång. Allt därefter konfigureras inifrån spelet.

```sql
-- 1. Myndigheten.
INSERT INTO fpd_agencies (id, name, short_name)
VALUES ('lspd', 'Los Santos Police Department', 'LSPD');

-- 2. Du själv i personalregistret, med ditt Discord-ID.
--    Hämtas i Discord: Användarinställningar -> Avancerat -> Utvecklarläge,
--    högerklicka sedan på ditt namn -> Kopiera användar-ID.
INSERT INTO fpd_officers (discord_id, agency_id, callsign, name)
VALUES ('DITT_DISCORD_ID', 'lspd', '12-40', 'A. Lindqvist');

-- 3. Dina Discord-roller.
--    Den här raden skrivs normalt av boten. Tills den finns lägger du in den
--    själv. Utan den här raden har du inga roller, och därmed ingen behörighet
--    till någonting alls.
--    Högerklicka rollen i Serverinställningar -> Roller -> Kopiera roll-ID.
INSERT INTO fpd_discord_members (discord_id, roles, synced_at)
VALUES ('DITT_DISCORD_ID', '["DITT_ROLL_ID"]', NOW());

-- 4. Rollen kopplas till admin-gruppen. Det här är den enda kopplingen du
--    någonsin behöver skriva för hand — resten görs i MDT:n.
INSERT INTO fpd_role_map (discord_role_id, discord_role_name, group_key, agency_id)
VALUES ('DITT_ROLL_ID', 'FredPD Admin', 'admin', 'lspd');
```

`roles` är en JSON-lista. Har du flera roller: `'["111...","222..."]'`.

> **Viktigt så länge boten saknas:** `synced_at` styr hur färsk FredPD anser att
> rollistan är. Är den äldre än 15 minuter vägras känsliga åtgärder, och äldre än
> 6 timmar går sessionen i skrivskyddat läge. Kör
> `UPDATE fpd_discord_members SET synced_at = NOW();` när du ska administrera.

Starta om resursen: `restart fredpd`.

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
| *"Du är inte inloggad"* när MDT:n öppnas | Du saknas i `fpd_officers`, eller står på en annan karaktär än den som är knuten till kontot |
| MDT:n öppnas men listan till vänster är tom | Ingen roll är kopplad, eller så saknas raden i `fpd_discord_members` (steg 5, punkt 3) |
| *"Dina Discord-roller ger inte behörighet"* på `/fredpd placement` | Din roll saknar `admin`-gruppen |
| *"Dina behörigheter är inaktuella"* | `synced_at` är äldre än 15 minuter. Kör `UPDATE fpd_discord_members SET synced_at = NOW();` |
| Ingenting syns ute i världen | Inga placeringar är skapade ännu. Det är det normala utgångsläget |
| Fordonsdepån är tom | `fpd_fleet` saknar rader för din myndighet (steg 6) |
| Fordonsmenyn visar `fleet.cruiser` i stället för ett namn | Språknyckeln saknas i `en.json`/`sv.json` |
| Resursen startar inte, klagar på tabeller | Migrationerna är inte körda |
| Resursen startar inte i produktion | `fredpd:gateway_secret` eller `fredpd:discord_guild` saknas |

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

## 12. Vad som inte är byggt ännu

Var beredd på det här — det är inte fel, det är kommande milstolpar:

- **Discord-boten och rollsynkningen.** Steg 5 punkt 3 är tillfällig.
- **Migrationskörare.** Migrationerna körs för hand tills vidare.
- **Flotteditor i gränssnittet.** `fpd_fleet` redigeras i databasen.
- **Certifieringar** (M6). En flottrad med `certification` visas för ingen ännu.
- **Register, ledningscentral, bevis, laboratorium, domstol, underrättelser** —
  M2 till M6.
- **Beslag** ligger kvar hos `p_policejob` och är inte tänkt att flytta.

Ingenting av Lua-koden har ännu körts på en riktig FiveM-server. Logiken täcks av
enhetstester, men de delar som använder spelets egna funktioner — att skapa
gestalter, sikta på föremål, ta fokus till gränssnittet — är oprövade i skarpt
läge. Räkna med att det är där de första problemen dyker upp.
