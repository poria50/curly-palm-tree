# Oman Fleet – planlegging og drift av lastebilselskap i Oman

Tospråklig (persisk/engelsk) planleggingsapp: forutsetninger, ruter og runder, kjørelogg,
femårsprognose, scenarier med versjoner, investorer, risiko og team.

## Struktur
- `index.html` – hele appen (én fil, ingen byggesteg)
- `netlify.toml` – Netlify-oppsett (publiserer rotmappen)
- `supabase/migrations/` – databaseskjemaet i Supabase-prosjektet `oman-fleet`, i rekkefølge

## Oppdatere appen
1. Erstatt `index.html` med ny versjon (GitHub: *Add file → Upload files*).
2. Commit. Netlify publiserer automatisk i løpet av et minutt.

## Backend
Supabase-prosjekt `oman-fleet` (Frankfurt). Nøkkelen i `index.html` er den offentlige
anon-nøkkelen; tilgang styres av Row Level Security i databasen.
Migrasjonene er allerede kjørt – filene her er dokumentasjon og sikkerhetskopi.
