-- ============================================================
-- Urlaub Tool – komplettes Datenbankschema (Neuaufbau)
-- ACHTUNG: Löscht alle vorhandenen Tabellen und Daten dieses Tools.
-- Einmal komplett in den Supabase SQL-Editor einfügen und ausführen.
-- ============================================================

drop view if exists mein_konto;
drop view if exists mitarbeiter_uebersicht;
drop table if exists abwesenheiten;
drop table if exists mitarbeiter;
drop table if exists abteilungen;
drop table if exists feiertage;
drop function if exists ist_verwalter();
drop function if exists eigene_mitarbeiter_id();

-- Mitarbeiter-Zugänge aus früheren Tests entfernen (dein eigener Verwalter-Login bleibt)
delete from auth.users where email like '%@dienst.intern';

-- ============================================================
-- Tabellen
-- ============================================================

create table abteilungen (
  id uuid primary key default gen_random_uuid(),
  name text unique not null
);

insert into abteilungen (name) values
  ('Produktion'), ('Büro'), ('Fahrer'), ('Lager'), ('Außendienst'), ('Reinigung');

create table feiertage (
  id uuid primary key default gen_random_uuid(),
  datum date unique not null,
  bezeichnung text not null
);

create table mitarbeiter (
  id uuid primary key default gen_random_uuid(),

  -- Zugang
  dienstnummer text unique,
  email text unique,
  rolle text not null default 'mitarbeiter' check (rolle in ('mitarbeiter','verwalter')),

  -- Person
  vorname text not null,
  nachname text not null,
  geburtsdatum date,

  -- Beschäftigung
  abteilung text not null,
  taetigkeit text,
  beschaeftigung text check (beschaeftigung in ('Vollzeit','Teilzeit','Geringfügig')),
  wochenstunden numeric,
  eintrittsdatum date not null,
  austrittsdatum date,

  -- Kontakt
  telefon text,
  adresse text,

  -- Amtlich (nur für Verwalter sichtbar)
  sv_nummer text,
  staatsangehoerigkeit text,

  -- Urlaubsberechnung
  urlaubssatz numeric not null default 2.055,
  kontokorrektur numeric not null default 0,

  erstellt_am timestamptz not null default now()
);

comment on column mitarbeiter.urlaubssatz is 'Urlaubstage je 30 Tage Betriebszugehörigkeit. 2,055 entspricht rund 25 Werktagen pro Jahr.';

create table abwesenheiten (
  id uuid primary key default gen_random_uuid(),
  mitarbeiter_id uuid not null references mitarbeiter(id) on delete cascade,
  art text not null check (art in ('Urlaub','Krank','Sonstige')),
  von date not null,
  bis date not null,
  werktage numeric not null,
  status text not null default 'offen' check (status in ('offen','genehmigt','abgelehnt')),
  kommentar text,
  erstellt_am timestamptz not null default now(),
  bearbeitet_von uuid references mitarbeiter(id),
  bearbeitet_am timestamptz,
  constraint zeitraum_gueltig check (bis >= von)
);

create index abwesenheiten_mitarbeiter_idx on abwesenheiten(mitarbeiter_id);
create index abwesenheiten_zeitraum_idx on abwesenheiten(von, bis);

-- ============================================================
-- Rechte-Hilfsfunktionen
-- ============================================================

create or replace function ist_verwalter()
returns boolean language sql security definer set search_path = public stable as $$
  select
    not exists (select 1 from mitarbeiter)
    or exists (select 1 from mitarbeiter where email = auth.email() and rolle = 'verwalter');
$$;

create or replace function eigene_mitarbeiter_id()
returns uuid language sql security definer set search_path = public stable as $$
  select id from mitarbeiter where email = auth.email();
$$;

-- ============================================================
-- Sichten
-- ============================================================

-- Vollständige Übersicht – nur für Verwalter
create view mitarbeiter_uebersicht as
select
  m.id, m.dienstnummer, m.email, m.rolle,
  m.vorname, m.nachname, m.vorname || ' ' || m.nachname as vollername, m.geburtsdatum,
  m.abteilung, m.taetigkeit, m.beschaeftigung, m.wochenstunden,
  m.eintrittsdatum, m.austrittsdatum,
  m.telefon, m.adresse, m.sv_nummer, m.staatsangehoerigkeit,
  m.urlaubssatz, m.kontokorrektur,
  (current_date - m.eintrittsdatum) as tage_in_firma,
  coalesce(sum(a.werktage) filter (where a.art = 'Urlaub'   and a.status = 'genehmigt'), 0) as konsumiert,
  coalesce(sum(a.werktage) filter (where a.art = 'Krank'    and a.status = 'genehmigt'), 0) as krank,
  coalesce(sum(a.werktage) filter (where a.art = 'Sonstige' and a.status = 'genehmigt'), 0) as sonstige,
  round((current_date - m.eintrittsdatum)::numeric / 30 * m.urlaubssatz, 2) as urlaubsanspruch,
  round(
    (current_date - m.eintrittsdatum)::numeric / 30 * m.urlaubssatz
    - coalesce(sum(a.werktage) filter (where a.art = 'Urlaub' and a.status = 'genehmigt'), 0)
    + m.kontokorrektur
  , 2) as urlaubskonto
from mitarbeiter m
left join abwesenheiten a on a.mitarbeiter_id = m.id
where ist_verwalter()
group by m.id;

-- Eigenes Konto – für jeden Angemeldeten, ohne sensible Felder
create view mein_konto as
select
  m.id, m.dienstnummer,
  m.vorname, m.nachname, m.vorname || ' ' || m.nachname as vollername,
  m.abteilung, m.taetigkeit, m.rolle,
  m.eintrittsdatum, m.austrittsdatum,
  (current_date - m.eintrittsdatum) as tage_in_firma,
  coalesce(sum(a.werktage) filter (where a.art = 'Urlaub'   and a.status = 'genehmigt'), 0) as konsumiert,
  coalesce(sum(a.werktage) filter (where a.art = 'Krank'    and a.status = 'genehmigt'), 0) as krank,
  coalesce(sum(a.werktage) filter (where a.art = 'Sonstige' and a.status = 'genehmigt'), 0) as sonstige,
  round((current_date - m.eintrittsdatum)::numeric / 30 * m.urlaubssatz, 2) as urlaubsanspruch,
  round(
    (current_date - m.eintrittsdatum)::numeric / 30 * m.urlaubssatz
    - coalesce(sum(a.werktage) filter (where a.art = 'Urlaub' and a.status = 'genehmigt'), 0)
    + m.kontokorrektur
  , 2) as urlaubskonto
from mitarbeiter m
left join abwesenheiten a on a.mitarbeiter_id = m.id
where m.email = auth.email()
group by m.id;

grant select on mitarbeiter_uebersicht to anon, authenticated;
grant select on mein_konto to anon, authenticated;

-- ============================================================
-- Row Level Security
-- ============================================================

alter table mitarbeiter enable row level security;
alter table abteilungen enable row level security;
alter table feiertage enable row level security;
alter table abwesenheiten enable row level security;

-- Stammdaten: komplett nur für Verwalter (sensible Felder wie SV-Nummer)
create policy mitarbeiter_select on mitarbeiter for select using (ist_verwalter());
create policy mitarbeiter_insert on mitarbeiter for insert with check (ist_verwalter());
create policy mitarbeiter_update on mitarbeiter for update using (ist_verwalter());
create policy mitarbeiter_delete on mitarbeiter for delete using (ist_verwalter());

create policy abteilungen_select on abteilungen for select using (true);
create policy abteilungen_write on abteilungen for all using (ist_verwalter()) with check (ist_verwalter());

create policy feiertage_select on feiertage for select using (true);
create policy feiertage_write on feiertage for all using (ist_verwalter()) with check (ist_verwalter());

-- Abwesenheiten: eigene sehen und beantragen, Verwalter sieht und entscheidet alles
create policy abwesenheiten_select on abwesenheiten
  for select using (mitarbeiter_id = eigene_mitarbeiter_id() or ist_verwalter());
create policy abwesenheiten_insert on abwesenheiten
  for insert with check (mitarbeiter_id = eigene_mitarbeiter_id() or ist_verwalter());
create policy abwesenheiten_update on abwesenheiten
  for update using (ist_verwalter() or (mitarbeiter_id = eigene_mitarbeiter_id() and status = 'offen'));
create policy abwesenheiten_delete on abwesenheiten
  for delete using (ist_verwalter() or (mitarbeiter_id = eigene_mitarbeiter_id() and status = 'offen'));

-- ============================================================
-- Österreichische Feiertage 2016–2030
-- ============================================================

insert into feiertage (datum, bezeichnung) values
('2016-01-01','Neujahr'),('2016-01-06','Heilige Drei Könige'),('2016-03-28','Ostermontag'),('2016-05-01','Staatsfeiertag'),('2016-05-05','Christi Himmelfahrt'),('2016-05-16','Pfingstmontag'),('2016-05-26','Fronleichnam'),('2016-08-15','Mariä Himmelfahrt'),('2016-10-26','Nationalfeiertag'),('2016-11-01','Allerheiligen'),('2016-12-08','Mariä Empfängnis'),('2016-12-25','Christtag'),('2016-12-26','Stefanitag'),
('2017-01-01','Neujahr'),('2017-01-06','Heilige Drei Könige'),('2017-04-17','Ostermontag'),('2017-05-01','Staatsfeiertag'),('2017-05-25','Christi Himmelfahrt'),('2017-06-05','Pfingstmontag'),('2017-06-15','Fronleichnam'),('2017-08-15','Mariä Himmelfahrt'),('2017-10-26','Nationalfeiertag'),('2017-11-01','Allerheiligen'),('2017-12-08','Mariä Empfängnis'),('2017-12-25','Christtag'),('2017-12-26','Stefanitag'),
('2018-01-01','Neujahr'),('2018-01-06','Heilige Drei Könige'),('2018-04-02','Ostermontag'),('2018-05-01','Staatsfeiertag'),('2018-05-10','Christi Himmelfahrt'),('2018-05-21','Pfingstmontag'),('2018-05-31','Fronleichnam'),('2018-08-15','Mariä Himmelfahrt'),('2018-10-26','Nationalfeiertag'),('2018-11-01','Allerheiligen'),('2018-12-08','Mariä Empfängnis'),('2018-12-25','Christtag'),('2018-12-26','Stefanitag'),
('2019-01-01','Neujahr'),('2019-01-06','Heilige Drei Könige'),('2019-04-22','Ostermontag'),('2019-05-01','Staatsfeiertag'),('2019-05-30','Christi Himmelfahrt'),('2019-06-10','Pfingstmontag'),('2019-06-20','Fronleichnam'),('2019-08-15','Mariä Himmelfahrt'),('2019-10-26','Nationalfeiertag'),('2019-11-01','Allerheiligen'),('2019-12-08','Mariä Empfängnis'),('2019-12-25','Christtag'),('2019-12-26','Stefanitag'),
('2020-01-01','Neujahr'),('2020-01-06','Heilige Drei Könige'),('2020-04-13','Ostermontag'),('2020-05-01','Staatsfeiertag'),('2020-05-21','Christi Himmelfahrt'),('2020-06-01','Pfingstmontag'),('2020-06-11','Fronleichnam'),('2020-08-15','Mariä Himmelfahrt'),('2020-10-26','Nationalfeiertag'),('2020-11-01','Allerheiligen'),('2020-12-08','Mariä Empfängnis'),('2020-12-25','Christtag'),('2020-12-26','Stefanitag'),
('2021-01-01','Neujahr'),('2021-01-06','Heilige Drei Könige'),('2021-04-05','Ostermontag'),('2021-05-01','Staatsfeiertag'),('2021-05-13','Christi Himmelfahrt'),('2021-05-24','Pfingstmontag'),('2021-06-03','Fronleichnam'),('2021-08-15','Mariä Himmelfahrt'),('2021-10-26','Nationalfeiertag'),('2021-11-01','Allerheiligen'),('2021-12-08','Mariä Empfängnis'),('2021-12-25','Christtag'),('2021-12-26','Stefanitag'),
('2022-01-01','Neujahr'),('2022-01-06','Heilige Drei Könige'),('2022-04-18','Ostermontag'),('2022-05-01','Staatsfeiertag'),('2022-05-26','Christi Himmelfahrt'),('2022-06-06','Pfingstmontag'),('2022-06-16','Fronleichnam'),('2022-08-15','Mariä Himmelfahrt'),('2022-10-26','Nationalfeiertag'),('2022-11-01','Allerheiligen'),('2022-12-08','Mariä Empfängnis'),('2022-12-25','Christtag'),('2022-12-26','Stefanitag'),
('2023-01-01','Neujahr'),('2023-01-06','Heilige Drei Könige'),('2023-04-10','Ostermontag'),('2023-05-01','Staatsfeiertag'),('2023-05-18','Christi Himmelfahrt'),('2023-05-29','Pfingstmontag'),('2023-06-08','Fronleichnam'),('2023-08-15','Mariä Himmelfahrt'),('2023-10-26','Nationalfeiertag'),('2023-11-01','Allerheiligen'),('2023-12-08','Mariä Empfängnis'),('2023-12-25','Christtag'),('2023-12-26','Stefanitag'),
('2024-01-01','Neujahr'),('2024-01-06','Heilige Drei Könige'),('2024-04-01','Ostermontag'),('2024-05-01','Staatsfeiertag'),('2024-05-09','Christi Himmelfahrt'),('2024-05-20','Pfingstmontag'),('2024-05-30','Fronleichnam'),('2024-08-15','Mariä Himmelfahrt'),('2024-10-26','Nationalfeiertag'),('2024-11-01','Allerheiligen'),('2024-12-08','Mariä Empfängnis'),('2024-12-25','Christtag'),('2024-12-26','Stefanitag'),
('2025-01-01','Neujahr'),('2025-01-06','Heilige Drei Könige'),('2025-04-21','Ostermontag'),('2025-05-01','Staatsfeiertag'),('2025-05-29','Christi Himmelfahrt'),('2025-06-09','Pfingstmontag'),('2025-06-19','Fronleichnam'),('2025-08-15','Mariä Himmelfahrt'),('2025-10-26','Nationalfeiertag'),('2025-11-01','Allerheiligen'),('2025-12-08','Mariä Empfängnis'),('2025-12-25','Christtag'),('2025-12-26','Stefanitag'),
('2026-01-01','Neujahr'),('2026-01-06','Heilige Drei Könige'),('2026-04-06','Ostermontag'),('2026-05-01','Staatsfeiertag'),('2026-05-14','Christi Himmelfahrt'),('2026-05-25','Pfingstmontag'),('2026-06-04','Fronleichnam'),('2026-08-15','Mariä Himmelfahrt'),('2026-10-26','Nationalfeiertag'),('2026-11-01','Allerheiligen'),('2026-12-08','Mariä Empfängnis'),('2026-12-25','Christtag'),('2026-12-26','Stefanitag'),
('2027-01-01','Neujahr'),('2027-01-06','Heilige Drei Könige'),('2027-03-29','Ostermontag'),('2027-05-01','Staatsfeiertag'),('2027-05-06','Christi Himmelfahrt'),('2027-05-17','Pfingstmontag'),('2027-05-27','Fronleichnam'),('2027-08-15','Mariä Himmelfahrt'),('2027-10-26','Nationalfeiertag'),('2027-11-01','Allerheiligen'),('2027-12-08','Mariä Empfängnis'),('2027-12-25','Christtag'),('2027-12-26','Stefanitag'),
('2028-01-01','Neujahr'),('2028-01-06','Heilige Drei Könige'),('2028-04-17','Ostermontag'),('2028-05-01','Staatsfeiertag'),('2028-05-25','Christi Himmelfahrt'),('2028-06-05','Pfingstmontag'),('2028-06-15','Fronleichnam'),('2028-08-15','Mariä Himmelfahrt'),('2028-10-26','Nationalfeiertag'),('2028-11-01','Allerheiligen'),('2028-12-08','Mariä Empfängnis'),('2028-12-25','Christtag'),('2028-12-26','Stefanitag'),
('2029-01-01','Neujahr'),('2029-01-06','Heilige Drei Könige'),('2029-04-02','Ostermontag'),('2029-05-01','Staatsfeiertag'),('2029-05-10','Christi Himmelfahrt'),('2029-05-21','Pfingstmontag'),('2029-05-31','Fronleichnam'),('2029-08-15','Mariä Himmelfahrt'),('2029-10-26','Nationalfeiertag'),('2029-11-01','Allerheiligen'),('2029-12-08','Mariä Empfängnis'),('2029-12-25','Christtag'),('2029-12-26','Stefanitag'),
('2030-01-01','Neujahr'),('2030-01-06','Heilige Drei Könige'),('2030-04-22','Ostermontag'),('2030-05-01','Staatsfeiertag'),('2030-05-30','Christi Himmelfahrt'),('2030-06-10','Pfingstmontag'),('2030-06-20','Fronleichnam'),('2030-08-15','Mariä Himmelfahrt'),('2030-10-26','Nationalfeiertag'),('2030-11-01','Allerheiligen'),('2030-12-08','Mariä Empfängnis'),('2030-12-25','Christtag'),('2030-12-26','Stefanitag');

-- ============================================================
-- Dein Verwalter-Zugang
-- Diese Zeile verbindet deinen bestehenden Login mit einem Mitarbeiter-Datensatz.
-- E-Mail muss exakt der sein, mit dem du dich anmeldest.
-- ============================================================

insert into mitarbeiter (email, rolle, vorname, nachname, abteilung, eintrittsdatum)
values ('admin@gmail.com', 'verwalter', 'Bertan', 'Bulut', 'Büro', current_date);
