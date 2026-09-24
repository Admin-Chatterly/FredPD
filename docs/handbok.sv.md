# FredPD — Tjänstehandbok

**Utgiven av systemförvaltningen · Gäller från tillträdesdagen · Läses av samtliga i yttre och inre tjänst**

---

Den här handboken beskriver hur du använder FredPD i tjänsten. Den tekniska
installationsguiden finns på annat håll och angår dig inte.

Läs igenom den innan ditt första pass. Det mesta är självklart efter en kvart,
men två saker bör du ta med dig redan nu:

**Systemet vet vem du är.** Du skriver aldrig in ditt eget anropsnamn någonstans.
Det hämtas ur din inloggning. Ingen kan uppträda som någon annan i FredPD.

**Allt lämnar spår.** Varje slagning, varje utkvitterat fordon, varje nekad
åtgärd hamnar i loggboken med tidpunkt och tjänstenummer. Det är inte till för
att sätta dit någon — det är till för att du i efterhand ska kunna visa vad du
gjorde och varför. Behandla det som vilken tjänsteanteckning som helst.

---

## 1. Behörighet

Din behörighet styrs av dina roller i myndighetens Discord. Ingenting annat.

Det betyder tre saker i praktiken:

- Blir du befordrad syns det i FredPD så fort rollen är satt. Du behöver inte
  logga ut.
- Blir en roll borttagen försvinner sidorna **direkt**, mitt i passet. Sitter du
  med terminalen uppe ser du dem försvinna.
- Din tjänstegrad i polisjobbet ger dig ingenting i FredPD. Den avgör om du är
  i tjänst, inte vad du får läsa.

Saknar du något du borde ha: vänd dig till befäl eller systemansvarig. Felet
ligger i rollistan, inte i systemet.

### Har du inte tillgång till något?

| Meddelande | Vad det betyder |
| --- | --- |
| *"Du är inte inloggad"* | Du står inte i personalregistret, eller så är du inne på fel karaktär |
| *"Dina Discord-roller ger inte behörighet till det här"* | Du saknar behörighet. Kontakta befäl |
| *"Det här går bara att göra på rätt plats, i tjänst eller i rätt enhet"* | Du står på fel ställe, eller är inte i tjänst |
| *"Dina behörigheter är inaktuella"* | Kontakten med Discord har brutits. Anmäl det — tills den är återställd är känsliga åtgärder spärrade |
| *"För många anrop"* | Du har gjort samma sak för många gånger på kort tid. Vänta några sekunder |

Att en åtgärd vägras är i regel inte ett fel. Det är systemet som gör vad det ska.

---

## 2. Öppna FredPD, och terminalerna

**Tryck F6** var du än är för att öppna FredPD (MDT:n), och F6 igen för att
stänga. Tangenten går att byta under Inställningar → Tangentbindningar → FiveM.
Därifrån slår du, skriver anmälan och ser händelser.

Vissa saker kräver ändå en fysisk plats, precis som med riktig
myndighetsutrustning. Gå fram till en terminal. När du är tillräckligt nära
dyker det upp en uppmaning på skärmen. **Tryck E.** FredPD öppnas då direkt på
rätt sida för terminalen.

| Terminal | Var den står | Vad den används till |
| --- | --- | --- |
| Stationsterminal | På stationerna | Allmänt arbete |
| Terminal i beslagsrummet | I beslagsrummet | Inlämning och utlämning av beslag |
| Laboratorieterminal | I laboratoriet | Analys och granskning |
| Terminal för inskrivning | I arresten | Inskrivning, fotografering |
| Ledningsplats | På ledningscentralen | Händelser och enheter |
| Terminal i domstolen | I domstolsbyggnaden | Förhandlingar och beslut |

Vissa saker går **bara** att göra vid rätt terminal. Beslag lämnas in i
beslagsrummet, inte från radiobilen. Det är avsiktligt, och servern kontrollerar
att du verkligen står där — det räcker inte att påstå det.

Står ingen terminal där du tycker att det borde stå en: säg till. De placeras ut
av systemansvarig och går att flytta.

> Delar av modulerna ovan är ännu inte tagna i drift. Beslagsrum, laboratorium,
> arrest och domstol öppnar i takt med att de införs. Terminalen står redan där,
> den svarar bara ännu inte.

---

## 3. Den interna kanalen

Den viktigaste funktionen i handboken, och den enklaste.

```
/pd <meddelande>
```

Skriv `/pd` följt av det du vill säga. Meddelandet går ut i den vanliga
chattrutan — **men bara till poliser.** Civila ser ingenting, även om de har
samma chattruta öppen.

Ditt anropsnamn och namn sätts av systemet och läggs till automatiskt:

```
12-40 | A. Lindqvist    registreringsnummer 4XYZ123 färdas norrut på Alta Street
```

### Varför den finns

Radion är förstahandsvalet och ska förbli det. Den interna kanalen är till för
det som måste bli **exakt**: registreringsnummer, adresser, personnummer,
anropssignaler. Sådant som är lätt att höra fel över radio och dyrt att höra fel
på.

Du behöver inte öppna terminalen för att läsa kanalen. Det är hela poängen —
ingen hinner öppna en surfplatta mitt under ett förföljande.

### Ordningsregler

- Kanalen är **tjänstekanal**. Skriv i den som du talar i radio.
- Allt sparas och går att läsa i efterhand av den som har behörighet.
- Färgkoder och formatering filtreras bort. Du kan inte färglägga din text, och
  du kan inte få den att se ut som att någon annan skrivit den.
- Kanalen går till din egen myndighet. Yttre befäl och uppåt ser samtliga
  myndigheters trafik.

---

## 4. Fordonsdepån

Vid depån står en tjänsteman. Gå fram och **tryck E**.

### Kvittera ut

Du får en lista över de fordon **du** får köra. Andra fordon visas inte — en
lista full av bilar du ändå inte får ta är till ingen nytta. Välj ett, så ställs
det fram och du sätter dig i det. Registreringsnumret tilldelas av myndigheten.

Vissa fordon kräver särskild behörighet eller utbildning. Saknas den står bilen
inte i din lista.

**Du måste vara i tjänst.** Depån lämnar inte ut fordon till någon som är ledig.

### Lämna tillbaka

Kör fram till depån, välj **Lämna tillbaka ett fordon**. Sitter du i bilen tas
den; annars tas den närmaste.

Bara fordon som depån faktiskt lämnat ut kan lämnas in. Ett fordon du hittat på
gatan går inte att kvittera in här, och ett fordon som redan lämnats tillbaka
går inte att lämna tillbaka en gång till.

### Vad som antecknas

Varje utkvittering och varje återlämning förs in med tid, tjänstenummer, modell
och registreringsnummer. Befäl ser vilka fordon som är ute och hos vem.

Ett fordon som står kvar på dig när passet är slut syns. Lämna tillbaka det.

> Beslagtagna fordon hanteras inte här. Beslag och bärgning ligger kvar i det
> ordinarie polisjobbet.

---

## 5. Terminalen — vad du ser

Överst står myndighetens namn. Till vänster listan över de moduler du har
behörighet till. Nederst din anropssignal, ditt namn och om du är i tjänst.

Listan till vänster visar **bara** det du får öppna. Ser du inte en modul har du
inte behörighet till den — den är inte gömd, den finns inte för dig.

Stäng med **Esc** eller knappen uppe till höger.

Ändras din behörighet medan du sitter med terminalen uppe ritas listan om på en
gång. Det är inte ett fel.

---

## 6. För befäl och systemansvariga

Det här avsnittet angår dig som förvaltar systemet.

### Behörigheter

**Administration → Discord-roller** i terminalen.

Här kopplas en Discord-roll till en behörighetsgrupp. Klistra in roll-ID:t, välj
grupp, lägg till. Det slår igenom omedelbart för alla som är inloggade.

Sidan visar också hur färsk kontakten med Discord är. Står det att synkningen är
gammal ska du inte lita på bilden — anmäl det i stället.

Tre saker att känna till:

1. **Du kan inte dela ut mer än du själv har.** Försöker du koppla en roll till
   en grupp som är värd mer än din egen behörighet vägras det, och försöket
   antecknas.
2. **Administratörsgruppen ger ingen behörighet till register.** Att förvalta
   systemet är inte samma sak som att vara behörig att läsa om personer. Behöver
   du båda delarna ska du tilldelas båda, uttryckligen.
3. **Att ta bort en koppling slår igenom direkt.** Den som hade behörighet enbart
   genom den förlorar den i samma sekund, mitt i passet.

### Placeringar

```
/fredpd placement
```

Härifrån placeras terminaler, laboratoriebänkar och fordonsdepåns tjänsteman ut i
världen. Ställ dig där föremålet ska stå, eller titta rakt på ett befintligt
föremål och koppla det.

Du kan också flytta, stänga av och ta bort den närmaste placeringen.

En placering är en **ingång, aldrig en behörighet**. Att koppla en dator till
laboratorieterminalen ger ingen tillgång till laboratoriet. Tar du bort en
placering tar du bort en dörr — inte en behörighet.

Samtliga ändringar förs in i loggboken med vem som gjorde vad.

---

## 7. Sammanfattning

| Vad du vill göra | Hur |
| --- | --- |
| Öppna terminalen | Gå fram till en terminal, tryck **E** |
| Skriva på interna kanalen | `/pd <meddelande>` |
| Kvittera ut ett fordon | Gå fram till tjänstemannen vid depån, tryck **E** |
| Lämna tillbaka ett fordon | Kör till depån, tryck **E**, välj Lämna tillbaka |
| Stänga terminalen | **Esc** |
| Sätta ut en terminal *(systemansvarig)* | `/fredpd placement` |
| Ändra behörigheter *(systemansvarig)* | Terminalen → Administration → Discord-roller |

---

*Frågor om innehållet i den här handboken ställs till närmaste befäl. Fel i
systemet anmäls till systemförvaltningen.*
