# Meråker Casino – nettapp (versjon 2)

Felles webapp for 9 spillere og 2 administratorer. Supabase står for autentisering, database og adgangskontroll; Vercel serverer frontend.

## Oppsett (ca. 20–40 minutter)

1. Opprett prosjekt på https://supabase.com/dashboard.
2. I **Authentication → Providers → Email**, aktiver e-postinnlogging (OTP / magic link). Bruk gjerne e-postbekreftelse. I **Authentication → URL Configuration**: legg inn offentlig Vercel-URL under **Site URL** og **Redirect URLs**. Under første test kan du legge til `http://localhost:5173`.
3. Åpne `schema.sql`. Bytt `DIN_EPOST@EKSEMPEL.NO` med e-postadressen til den første banksjefen. Kjør SQL-filen i **SQL Editor**. **Bruk et nytt, tomt Supabase-prosjekt.**
4. I Supabase **Project Settings → API** kopierer du **Project URL** og **publishable key** (eller legacy `anon` key). **Aldri** legg `service_role`-nøkkelen i frontend.
5. På egen PC: installer Node.js 20+; kjør `npm install`, kopier `.env.example` til `.env` og fyll inn `VITE_SUPABASE_URL` og `VITE_SUPABASE_ANON_KEY`. Kjør `npm run dev` for test.
6. Legg hele prosjektet i et privat GitHub-repository. På https://vercel.com velger du **Add New → Project**, importerer repositoryet og bruker **Vite**. Legg inn de to `VITE_...` variablene under **Environment Variables**, og trykk **Deploy**.
7. Legg den endelige Vercel-adressen inn i Supabase **Authentication → URL Configuration**. Om du endrer dette etter første deploy, logg inn på nytt.
8. Åpne nettadressen, logg inn med banksjefens e-post. Under **Administrasjon** legger du inn ni spilleres e-postadresser og navn og den andre arrangøren som administrator. Spillerne går til samme URL og logger inn med sin registrerte e-post.

## Slik fungerer appen

- Spillerne ser egen saldo, egne transaksjoner, egne bud og kontrakter. Admin ser regnskap og alle bud.
- Sedler er kun digitale regnskapsposter. Banken starter med 1 500; 50 overføres automatisk til hver spiller som opprettes. Bankens beholdning kan ikke bli negativ.
- Kun admin kan bokføre betalinger, opprette dilemmaer, avgjøre auksjoner og starte avsløringen.
- Fangens dilemma støtter 2 eller 3 deltakere per runde. Alle må ha avgitt valg før oppgjør.
- Avsløring viser rangering fra sisteplass til førsteplass.
- Programmet er en sjekkliste med de viktigste aktivitetene.

## Begrensninger / viktig før arrangementet

- **Dette er en MVP**, ikke et ferdig stresstestet produksjonssystem. Kjør en generalprøve med testkontoer og prøv alle funksjoner før julebordet.
- Appen støtter ikke automatisk skattemodell, renter, hevnrett, sabotasje eller automatisk fordeling av lagpremier. Disse kan registreres manuelt av admin i bankfanen.
- Bud gjelder foreløpig én samlet auksjon fredag og én lørdag. Selger dere flere objekter, må de avgjøres sekvensielt eller modellen utvides.
- Kontrakter lagrer tekst og akseptstatus, men flytter ikke penger automatisk.
- Rangering er basert på bokførte sedler, ikke uoppgjort gjeld. Gjeld må avregnes før avsløringen.
- Spillere kan se at de har egne transaksjoner, men ikke andre spilleres saldoer. Etter avsløring er saldoene offentlige.
- Dilemma-oppgjør bruker faste utbetalinger; det kan feile dersom bank eller spiller mangler sedler. Avsett tilstrekkelig budsjett.
- Deltakeres e-postadresser er kun synlige for administratorer via RLS.
- Supabase har egne grenser og vilkår for gratisbruk; sjekk gjeldende betingelser.
- **Sikkerhetskopi:** Bruk Supabase database backup eller eksport fra dashboard før/etter hver hovedbolk.

## Teknisk

- Vite + vanilla JS, Supabase JS 2, Postgres RLS og SECURITY DEFINER RPC-er.
- Ingen servernøkkel i klienten.
- Bruk helst HTTPS (Vercel gjør dette automatisk).

## Foreslåtte navn for Meråker Casino

Navnene Daniel, Kristian, Petter S, Petter W, Eivind, Edvard, Adrian, Andreas og Magnus er forhåndsvalgbare under **Administrasjon → Inviter deltakere**. E-postadresser må legges inn av arrangøren. Det er nå ni oppgitte navn.

**Rolleavklaring:** Daniel er oppgitt som «revisor», Kristian som «julebordkonge/bestyrer». Dette er omtalt som arrangementsroller og gir ikke automatisk administratorrettigheter. Velg `Administrator` for Kristian dersom han skal styre spillet, eller `Spiller` dersom han også skal konkurrere. Daniel kan settes som administrator dersom han faktisk skal føre regnskapet; administratorer teller ikke som spillere i premieøkonomien.
