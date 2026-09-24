# FredPD — installation och driftsättning

Teknisk guide för dig som sätter upp FredPD på servern. Handboken för poliser
finns i [`handbok.sv.md`](handbok.sv.md).

> **Läge just nu:** M0 är klart och M1 pågår. Det som fungerar i dag är
> behörigheter, placeringar i världen, den interna polischatten, fordonsdepån
> och **underrättelsemodulen** (avsnitt 11b). Register, ledningscentral, bevis,
> laboratorium och domstol kommer i M2–M6 (se avsnitt 17 i `FredPD.md`).
>
> **Hela installationen är fyra saker:** kopiera resursen, kör SQL-filerna,
> fyll i `config/server.lua`, och kör uppstartskommandot i spelet.
> Inga convars, ingen Node-tjänst, inget cron-jobb (ADR-010).

---

## 0. Snabblista

Den korta versionen, om du bara vill ha ordningen på stegen. Varje punkt
länkar till sitt eget avsnitt nedan.

1. **Kopiera** `resources/[fredpd]/fredpd` till servern och bygg gränssnittet
   ([avsnitt 2](#2-steg-1--hämta-och-bygg)).
2. **Köra SQL:en** — `database/combined/fredpd_all.sql` i ett svep
   ([avsnitt 3](#3-steg-2--databas)).
3. **Lägg till resursen** i `server.cfg` ([avsnitt 4](#4-steg-3--servercfg)).
4. **Fyll i `config/server.lua`** — Discord-token, guild-ID, myndighet
   ([avsnitt 5](#5-steg-4--konfigurationsfilen)). Testar du bara lokalt kan du
   hoppa över Discord helt just nu — se rutan om jobb-fallbacken i samma
   avsnitt.
5. **Starta resursen och kör uppstartskommandot** i spelet eller konsolen
   ([avsnitt 6](#6-steg-5--uppstart)). Det gör dig till första administratör.
6. **Lägg in fordon i fordonsdepån** ([avsnitt 7](#7-steg-6--fordonsflottan))
   och **placera ut terminaler i världen**
   ([avsnitt 8](#8-steg-7--placera-ut-systemet-i-världen)).
7. **Koppla resten av rollerna** till behörighetsgrupper från
   Administration → Discord-roller ([avsnitt 9](#9-steg-8--resten-av-rollerna)).

Kör du fast — session öppnas inte, MDT:n visar fel, en roll ger inte det den
ska — gå direkt till [avsnitt 10, Felsökning](#10-felsökning), eller kör
`fredpd_superuser <spelar-id>` i konsolen för att alltid komma in
([avsnitt 9b](#9b-nödåtkomst--superuser-från-konsolen)).

---

## 1. Krav

### På spelservern

| Resurs | Krävs? | Används till |
| --- | --- | --- |
| `es_extended` (ESX) | **Ja** | Karaktärer, namn, jobb |
| `ox_lib` | **Ja** | Callbacks, menyer, dialoger |
| `oxmysql` | **Ja** | Databasåtkomst |
| `ox_target` | Nej, men rekommenderas | Kontrollera ID, bötfäll, gripa, köra reg.nr och beslagta fordon direkt på personen eller bilen |
| `p_policejob` | Nej | Grad, och fängelset en dom skickas till (`JailPlayer`) |
| `piotreq_jobcore` | Nej, men behövs för tjänst med pScripts | Tjänstestatus: pScripts håller tjänst där, inte i `p_policejob`. Utan den läses tjänst från ESX (`job.onDuty`) |
| `esx_billing` | Nej | Ordningsböter skickas som riktiga fakturor och markeras betalda av sig själva |
| `esx_society` | Nej | Fordonsdepån registrerar bilar på myndigheten; böter betalas in till myndighetens konto |
| `esx_textui` | Nej | "Tryck E"-rutan (annars används ox_lib) |
| `esx_menu_dialog` | Nej | Menyer i världen (annars används ox_lib) |

Alla utom de tre första är frivilliga. Saknas någon av dem loggar FredPD en
varning vid start och fortsätter — varje villkor de svarar på faller då tillbaka
till "nej", aldrig till "ja".

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

Kör **`database/combined/fredpd_all.sql`** mot ditt ESX-schema, i ett svep —
i HeidiSQL: *Arkiv → Kör SQL-fil*, eller från kommandoraden:

```bash
mysql -u root DITT_ESX_SCHEMA < database/combined/fredpd_all.sql
```

Filen innehåller alla migrationer och seeds i rätt ordning. Den är säker att
köra om: kör den igen efter varje uppdatering, också på en databas där en
tidigare körning stannade halvvägs — den fortsätter där den tog slut. CI kör den
mot MariaDB 11.4 två gånger i rad på varje ändring, så den går igenom utan fel.

Kör **inte** migrationerna en och en. Fyra av dem (`0026`, `0033`, `0035`,
`0037`) har en sats som MariaDB inte kan köra. Migrationerna är
**append-only** — en fil som en gång levererats ändras aldrig — så de satserna
är rättade i huvudfilen när den sätts ihop, inte i källfilerna (ADR-024). Fick du
``SQL-fel (1064) … FOREIGN KEY (`loadout_id`)`` från en äldre version av
huvudfilen: kör den nya, den rättar det.

Seed-filerna går att köra om hur många gånger som helst utan att det blir
dubbletter.

Alla tabeller heter `fpd_*`. FredPD läser ESX:s egna tabeller och skriver i två
av dem, och databasanvändaren FredPD ansluter med behöver då de rättigheterna:

| Tabell | Rättighet | Varför |
| --- | --- | --- |
| `users`, `owned_vehicles` | `SELECT` | Förifyller personer och fordon från ESX |
| `owned_vehicles` | `UPDATE` | Ett beslagtaget fordon står inte i garaget förrän det lämnas ut (ADR-016) |
| `billing` | `SELECT`, `DELETE` | Ser att en bot är betald, och drar tillbaka fakturan när boten makuleras (ADR-015) |

Använder du samma databasanvändare som ESX har den redan allt detta.

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
| `evidence_tech` | — | Skapa och bearbeta brottsplatser, säkra spår |
| `property_officer` | — | Ta in, flytta och kvittera ut bevis i beslagsrummet |
| `lab_analyst` | — | Arbeta i laboratoriekön och utföra analyser |
| `lab_supervisor` | `lab_analyst` | Dessutom granska och frisläppa analysrapporter |

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
ensure ox_target
# Frivilliga, men gör mest nytta: fängelse, fakturor, myndighetens konto.
ensure p_policejob
ensure esx_billing
ensure esx_society

ensure fredpd_assets
ensure fredpd
ensure fredpd_forensics
```

Inga convars behövs. All konfiguration ligger i en enda fil — se nästa steg.

> `fredpd_forensics` (spår, bevisinsamling, fingeravtrycksläsare) kräver
> `ox_target`. `fredpd_surveillance` kräver `pma-voice` — starta den bara om
> servern har det, annars vägrar FXServer starta den och fyller konsolen med
> fel som ser ut som en trasig installation. Bevisregistret i sig ligger i
> kärnresursen (ADR-011), inte i dem.

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

### Testa lokalt utan Discord ännu

Har du inte satt upp Discord-botten än — vanligast på en lokal testserver —
lämna `discord.token`/`discord.guildId` tomma. FredPD:s behörigheter kommer
fortfarande bara från Discord-roller (invariant 2) i alla andra lägen, men så
länge Discord *inte* är ifyllt alls faller `discord.localJobFallback` in:
håller karaktären ESX-jobbet där (`'police'` som standard) får den samma
behörigheter som gruppen `patrol_basic` — nog för att öppna register och se
gränssnittet fungera, aldrig Administration. Sätt värdet till `''` för att
stänga av det helt. Fyll i Discord-uppgifterna senare och fallbacken
försvinner av sig själv.

---

## 6. Steg 5 — Uppstart

Ingen SQL. Starta resursen och läs konsolen:

```
[fredpd] ------------------------------------------------------------
[fredpd] This install is not set up yet.
[fredpd] Join the server, then run one of these:
[fredpd]   in the game chat:   /fredpd setup K7M2QXR4PT9B <discord role id>
[fredpd]   in this console:    fredpd_setup <player id> <discord role id>
...
```

Gå in i spelet. Kör sedan `fredpd_setup <ditt spelar-id>` i konsolen — den
listar dina Discord-roller med namn:

```
[fredpd] Discord roles held by Rami:
[fredpd]   1284…0021  Serverchef
[fredpd]   1284…0044  Polis
[fredpd]   1284…0100  Medlem
```

Välj **en** roll och kör `fredpd_setup <spelar-id> 1284…0021`, eller i spelet
`/fredpd setup K7M2QXR4PT9B 1284…0021`.

> **Välj rätt roll.** Alla som har den rollen blir FredPD-administratörer, med
> rätt att läsa loggboken och dela ut behörigheter vidare. Välj en lednings-
> eller stabsroll — aldrig `Medlem`, `Whitelistad` eller något annat som hela
> servern har. Uppstarten accepterar bara en roll du själv har, så ett
> feltryck kan inte ge bort administration till något helt annat.

Då skapas myndigheten, du läggs in i personalregistret med det Discord-ID FiveM
redan känner dig som, knuten till den karaktär du står på, och den valda rollen
kopplas till **både** `admin`-gruppen och `command`.

Den andra kopplingen är inte en bonus — den är nödvändig. `admin` ärver
medvetet ingen polisgrupp (avsnitt 3, "att administrera är inte samma sak
som att vara behörig att läsa register"), och varje vanlig koppling som görs
sedan (från Administration i MDT:n) vägrar ge bort mer än den som kopplar
redan själv har. `command` ärver hela kedjan (`supervisor`, `patrol`,
`patrol_basic`), så du kan direkt efter uppstarten koppla era Discordroller
till `patrol`, `supervisor` och så vidare från Administration → Rollkoppling.

Nya poliser behöver ingen manuell rad i personalregistret. Första gången någon
vars Discordroller ger behörighet öppnar FredPD läggs hen in automatiskt,
knuten till den karaktär hen står på (som måste ha jobbet `police`, se
`roster.requireJob` i `config/server.lua`), och får en anropssignal enligt
`roster.callsignFormat`. Ett befäl kan ändra anropssignalen under Personal.

Koden skrivs bara ut i serverkonsolen. Det är hela poängen: på en publik server
ska inte den första som gissar kommandot bli administratör.

Uppstarten vägrar så fort det finns någon i `fpd_officers`. Det finns exakt en
första gång.

> `fpd_discord_members` fylls av rollsynken i `server/core/discord.lua`, som
> uppdaterar hela guilden med några minuters mellanrum och varje spelare när
> hen ansluter. Du ska aldrig röra den tabellen för hand, och framför allt
> aldrig sätta `synced_at` med ett schemalagt jobb — den kolumnen är hur FredPD
> avgör om rollistan alls går att lita på (avsnitt 4.2).

---

## 7. Steg 6 — Fordonsflottan

Fordonsdepån visar inga bilar förrän du lagt in dem. Enklast är MDT:n:
**Administration → Fordonspark** (kräver `garage.fleet.manage`). Vill du hellre
lägga in raderna direkt i databasen ser det ut så här:

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
terminal i domstolen, fordonsdepå, bevisbänk eller **polisens reception**.

En **övervakningskamera** placeras där kameran sitter, med den riktning du
själv står i. Den öppnar ingenting där den sitter; den ses från en
stationsterminal eller ledningsplatsen (Register → Kameror). Kroppskameror är
utdelade `bodycam` i personalregistret, och fordonskameror är myndighetens
fordon. Stillbilder kräver gatewayen och screenshot-basic (se 11c).

Receptionen är den enda placeringen som **alla spelare** kan använda, inte bara
poliser (7.29, ADR-023). Där ser besökaren sina egna ordningsböter och de
åtalsbeslut och domar som gäller dem, och kan lämna in en anmälan om stöld
eller ett klagomål på polisen. Poliserna läser anmälningarna under fliken
*Från allmänheten* i registret. Klagomål läses bara av den som har
internutredningens behörighet (`ia.case.view`, och `ia.case.manage` för att
avsluta). Ge den gruppen även `public.report.view`, som är dörren till listan.

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

## 9b. Nödåtkomst — superuser från konsolen

Uppstarten (steg 5) ger den första administratören både `admin` och
`patrol_basic` — tillräckligt för att öppna MDT:n och komma åt Administration
själv. Men om en rollkoppling ändå går fel, en grupp blir felkonfigurerad, eller
en administratör låser ut sig själv från Administration, finns nu en väg in
som inte beror på att MDT:n fungerar: `fredpd_superuser`, körd i
**serverkonsolen** — ingenting i spelet kan nå den, med avsikt.

```
fredpd_superuser <spelar-id>                    -- ger superuser direkt och permanent, ingen Discord krävs
fredpd_superuser <spelar-id> <roll-id>           -- ger även rollen gruppen superuser (kräver Discord)
fredpd_superuser_roles <spelar-id>               -- listar spelarens Discord-roller, för att välja ett roll-ID
fredpd_superuser_list                            -- visar vilka som har superuser just nu
fredpd_superuser_revoke <spelar-id | discord-id>  -- tar bort superuser
```

`superuser` sätts som en flagga på personalraden (`fpd_officers.superuser`),
inte som en Discord-roll — det är skillnaden mot tidigare version av det här
kommandot. Den håller därför **permanent**, oavsett om Discord-botten senare
går ner, tappar sin token, eller aldrig konfigureras alls: `Session.open`
läser flaggan direkt och behöver ingen Discord-rollsnapshot för den. Det andra
formet (med ett roll-ID) fungerar bara när Discord är konfigurerat och verifierar
rollen live innan den kopplas — men den permanenta flaggan sätts ändå, så att
tappa eller ta bort den rollen i efterhand ändrar inte grantet.

`superuser` är inte ett steg ovanför `command` eller `admin` i den vanliga
behörighetstrappan — det är ett enda jokertecken, `*`, som `Perms.satisfies`
känner igen som "vad som än frågas efter". Att koppla en roll till `superuser`
via Administration eller gruppredigeraren vägras av samma skäl som allt annat
man inte redan själv har (se steg 9 ovan) — ingen kommer åt den utan att redan
ha den, förutom via konsolen.

Precis som `fredpd_setup` slår `fredpd_superuser` igenom omedelbart: ingen
omstart, ingen omanslutning krävs.

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
| *"Du måste vara i tjänst"*, fast du stämplat in | Kör `fredpd_duty <server-id>` i serverkonsolen. Den visar vad varje tjänstekälla svarar: `piotreq_jobcore`, `p_policejob`, ESX:s `job.onDuty` och FredPD:s egen flagga. Svarar ingen, eller fel resurs: ställ in `duty` i `config/server.lua` |

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

## 11c. Fotografier och signalementsfoton (valfritt)

Fotografier på personer och signalementsfoton vid inskrivningen går genom
gateway-tjänsten (ADR-019). Utan den fungerar allt annat, och knappen säger
varför den inte kan ta bilden.

1. **screenshot-basic** måste vara installerad och startad före `fredpd`.
2. **Gatewayen** körs med bland annat:
   - `FREDPD_GATEWAY_SECRET`, samma hemlighet som `set fredpd:gateway_secret`
     i `server.cfg`;
   - `FREDPD_MEDIA_BASE_URL`, den adress spelarnas klient når gatewayen på,
     t.ex. `https://media.example.se`;
   - `FREDPD_MEDIA_ALLOWED_ORIGIN`, standard `https://cfx-nui-fredpd`. Byt
     bara om resursen heter något annat.
3. **MDT:n byggs med samma adress**, annars stoppar dess säkerhetspolicy varje
   bild:

   ```bash
   VITE_MEDIA_HOST=https://media.example.se pnpm build
   ```
4. I `config/server.lua`, under `gateway`, sätt `enabled = true`, och sätt
   `set fredpd:gateway_media_url "https://media.example.se"` i `server.cfg`.

Signalementsfotot tas vid inskrivningsterminalen, med personen stående
bredvid: **Inskrivning → välj inskrivningen → Ta signalementsfoto**. Andra
fotografier (fält, ärr, märke, tatuering) tas från personens registerkort.

## 11d. Utskrifter (valfritt)

Ordningsböter, anmälningar och loggar över frihetsberövanden kan skrivas ut
(ADR-020): som en **papperskopia** i spelet, eller som en **PDF** från
gateway-tjänsten.

Papperskopian är ett föremål i ox_inventory. Lägg till det i
`ox_inventory/data/items.lua`:

```lua
['fredpd_paper'] = {
    label = 'Papper',
    weight = 10,
    stack = false,
    close = true,
    client = { export = 'fredpd.readPaper' },
},
```

Den som har pappret kan läsa det, även utan MDT, precis som med ett riktigt
papper. Heter föremålet något annat, ändra `documents.paperItem` i
`config/server.lua`. PDF kräver gatewayen (se 11c).

## 11e. Anställa, befordra och avskeda via Discord (valfritt)

Från personalregistret kan befälet anställa, befordra, degradera och avskeda
genom att ändra en **Discord-roll** (ADR-022). FredPD delar aldrig ut en
behörighet själv: rollen ändras i Discord, och FredPD läser tillbaka den som
vanligt. Det kräver gatewayen (se 11c) och en **egen bot** som får ändra
roller. Använd inte samma bot som läser rollerna.

1. Skapa en ny bot i Discord Developer Portal och bjud in den med behörigheten
   **Manage Roles** och inget annat.
2. Dra botens roll i serverns rollista så att den ligger **ovanför** varje roll
   den ska hantera, men **under** alla administratörsroller.
3. I gatewayens miljö:

   ```
   FREDPD_ROLE_ACTIONS_ENABLED=true
   DISCORD_ROLE_BOT_TOKEN=<botens token>
   DISCORD_GUILD_ID=<serverns id>
   FREDPD_ROLE_ACTIONS_ALLOWED=<roll-id>,<roll-id>
   ```

4. I `config/server.lua`, samma roller:

   ```lua
   roleActions = {
       enabled = true,
       roles = {
           { id = '<roll-id för anställd>', kind = 'hire' },
           { id = '<roll-id för en grad>', kind = 'rank' },
       },
   },
   ```

`hire` är rollen som gör någon till anställd (anställa, avskeda) och kräver
`personnel.hire`. `rank` är en tjänstegrad (befordra, degradera) och kräver
`personnel.promote`. Båda ges till `command` i standardinställningen.

Ingen kan ändra sina egna roller, ge en roll som är värd mer än vad hen själv
har, eller ändra rollerna för någon som har behörigheter hen själv saknar. Varje
ändring kräver ett skäl, som sparas i FredPD:s granskningslogg och i Discords.
Lägg **aldrig** en administratörsroll i listorna: gatewayen vägrar röra en roll
som inte står i dess egen lista, oavsett vad FXServer ber om.

## 12. Vad som inte är byggt ännu

Var beredd på det här — det är inte fel, det är kommande arbete:

- **Migrationskörare.** Migrationerna körs för hand tills vidare.
- **Uppladdade bilder som bevis** i underrättelsemodulen är inte kopplade till
  gatewayen ännu (fotografier av personer är det, se 11c). Externa länkar
  (Medal, YouTube, Streamable, bildadresser) fungerar.
- **Kommandoraden** (Ctrl+K i MDT:n) kan söka (`REG`, `N`, `VAP`, `TEL`, `ADR`),
  sätta status (`ST ER`), ansluta till närmaste händelse (`TILL`) och avsluta den
  (`KLAR`). Att öppna en händelse, anmälan eller ett bevis med nummer, skicka
  meddelanden och skapa poster med `NY` är inte byggt.
- **Fängelsets tidsenhet.** p_policejobs `JailPlayer` dokumenterar inte om
  `jail` är minuter. FredPD skickar minuter; justera `jail.minutesPerMonth` i
  `config/server.lua` om fängelset räknar annorlunda.
