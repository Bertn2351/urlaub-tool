-- ============================================================
-- Urlaub Tool – Erweiterung: Urlaubsgrenze und Krankmeldung mit Beleg
-- Ergänzt das bestehende Schema, löscht nichts.
-- ============================================================

-- 1) Beleg (Foto der Krankmeldung) an der Abwesenheit
alter table abwesenheiten add column if not exists beleg_pfad text;

-- 2) Eigene Kontosicht um die Werte erweitern, die für die Grenze nötig sind
drop view if exists mein_konto;
create view mein_konto as
select
  m.id, m.dienstnummer,
  m.vorname, m.nachname, m.vorname || ' ' || m.nachname as vollername,
  m.abteilung, m.taetigkeit, m.rolle,
  m.eintrittsdatum, m.austrittsdatum,
  m.urlaubssatz, m.kontokorrektur,
  (current_date - m.eintrittsdatum) as tage_in_firma,
  coalesce(sum(a.werktage) filter (where a.art = 'Urlaub'   and a.status = 'genehmigt'), 0) as konsumiert,
  coalesce(sum(a.werktage) filter (where a.art = 'Urlaub'   and a.status = 'offen'), 0)     as offen_urlaub,
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

grant select on mein_konto to anon, authenticated;

-- 3) Urlaubsgrenze serverseitig erzwingen
-- Der Anspruch wird auf das Enddatum des Antrags gerechnet, weil er täglich mitwächst.
-- Offene Anträge zählen mit, sonst liessen sich mehrere Anträge nebeneinander stellen.
-- Verwalter sind ausgenommen: sie dürfen bewusst einen Vorschuss gewähren.
create or replace function urlaub_grenze_pruefen()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  person    mitarbeiter%rowtype;
  anspruch  numeric;
  gebucht   numeric;
  frei      numeric;
begin
  if new.art <> 'Urlaub' or ist_verwalter() then
    return new;
  end if;

  select * into person from mitarbeiter where id = new.mitarbeiter_id;
  if not found then
    raise exception 'Mitarbeiter nicht gefunden.';
  end if;

  anspruch := greatest(new.bis - person.eintrittsdatum, 0)::numeric / 30 * person.urlaubssatz
              + person.kontokorrektur;

  select coalesce(sum(werktage), 0) into gebucht
  from abwesenheiten
  where mitarbeiter_id = new.mitarbeiter_id
    and art = 'Urlaub'
    and status in ('offen', 'genehmigt');

  frei := anspruch - gebucht;

  if new.werktage > frei then
    raise exception 'Nicht genug Urlaub: Bis % hast du % Tage zur Verfuegung, beantragt sind % Tage.',
      to_char(new.bis, 'DD.MM.YYYY'), round(frei, 1), new.werktage;
  end if;

  return new;
end $$;

drop trigger if exists urlaub_grenze on abwesenheiten;
create trigger urlaub_grenze before insert on abwesenheiten
for each row execute function urlaub_grenze_pruefen();

-- 4) Ablage für die Fotos der Krankmeldungen (nicht öffentlich)
insert into storage.buckets (id, name, public)
values ('krankmeldungen', 'krankmeldungen', false)
on conflict (id) do nothing;

drop policy if exists krankmeldung_hochladen on storage.objects;
create policy krankmeldung_hochladen on storage.objects
  for insert to authenticated
  with check (bucket_id = 'krankmeldungen');

drop policy if exists krankmeldung_ansehen on storage.objects;
create policy krankmeldung_ansehen on storage.objects
  for select to authenticated
  using (bucket_id = 'krankmeldungen' and (ist_verwalter() or owner = auth.uid()));
