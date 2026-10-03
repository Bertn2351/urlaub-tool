-- ============================================================
-- Urlaub Tool – Wissensspeicher für ausgelesene Dokumente
--
-- Zweck: Jede Dokumentenlesung wird mitsamt Rohtext und erkannten Feldern
-- festgehalten. Daraus lassen sich später feste Leseregeln je Formulartyp
-- ableiten – so wie es beim ÖGK-Formular schon gemacht wurde. Danach kann
-- die KI für diesen Formulartyp abgeschaltet werden.
--
-- Achtung: Hier stehen personenbezogene Daten (Namen, SV-Nummern, Adressen).
-- Die Tabelle ist deshalb ausschliesslich für Verwalter lesbar.
-- ============================================================

create table if not exists dokument_lesungen (
  id uuid primary key default gen_random_uuid(),
  dateiname text,
  medientyp text,
  art text,                       -- erkannte Dokumentart
  quelle text,                    -- feste Regel oder KI
  sicherheit text,
  rohtext text,                   -- der aus der Datei gelesene Text
  ergebnis jsonb,                 -- alle erkannten Felder
  uebernommen boolean not null default false,
  mitarbeiter_id uuid references mitarbeiter(id) on delete set null,
  gelesen_von uuid references mitarbeiter(id) on delete set null,
  erstellt_am timestamptz not null default now()
);

create index if not exists dokument_lesungen_art_idx on dokument_lesungen(art);
create index if not exists dokument_lesungen_datum_idx on dokument_lesungen(erstellt_am desc);

alter table dokument_lesungen enable row level security;

drop policy if exists lesungen_select on dokument_lesungen;
create policy lesungen_select on dokument_lesungen for select using (ist_verwalter());

drop policy if exists lesungen_insert on dokument_lesungen;
create policy lesungen_insert on dokument_lesungen for insert with check (ist_verwalter());

drop policy if exists lesungen_update on dokument_lesungen;
create policy lesungen_update on dokument_lesungen for update using (ist_verwalter());

drop policy if exists lesungen_delete on dokument_lesungen;
create policy lesungen_delete on dokument_lesungen for delete using (ist_verwalter());
