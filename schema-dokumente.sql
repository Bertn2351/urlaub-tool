-- ============================================================
-- Urlaub Tool – Erweiterung: Dokumente einreichen
-- Ergänzt das bestehende Schema, löscht nichts.
-- ============================================================

create table if not exists dokumente (
  id uuid primary key default gen_random_uuid(),
  mitarbeiter_id uuid not null references mitarbeiter(id) on delete cascade,
  art text not null,
  bemerkung text,
  pfad text not null,
  erledigt boolean not null default false,
  erstellt_am timestamptz not null default now()
);

create index if not exists dokumente_mitarbeiter_idx on dokumente(mitarbeiter_id);

alter table dokumente enable row level security;

drop policy if exists dokumente_select on dokumente;
create policy dokumente_select on dokumente
  for select using (mitarbeiter_id = eigene_mitarbeiter_id() or ist_verwalter());

drop policy if exists dokumente_insert on dokumente;
create policy dokumente_insert on dokumente
  for insert with check (mitarbeiter_id = eigene_mitarbeiter_id() or ist_verwalter());

drop policy if exists dokumente_update on dokumente;
create policy dokumente_update on dokumente
  for update using (ist_verwalter());

drop policy if exists dokumente_delete on dokumente;
create policy dokumente_delete on dokumente
  for delete using (ist_verwalter());

-- Ablage für die eingereichten Dokumente (nicht öffentlich)
insert into storage.buckets (id, name, public)
values ('dokumente', 'dokumente', false)
on conflict (id) do nothing;

drop policy if exists dokument_hochladen on storage.objects;
create policy dokument_hochladen on storage.objects
  for insert to authenticated
  with check (bucket_id = 'dokumente');

drop policy if exists dokument_ansehen on storage.objects;
create policy dokument_ansehen on storage.objects
  for select to authenticated
  using (bucket_id = 'dokumente' and (ist_verwalter() or owner = auth.uid()));
