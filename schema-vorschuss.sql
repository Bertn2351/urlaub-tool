-- ============================================================
-- Urlaub Tool – Urlaubsvorschuss zulassen
--
-- Bisher hat eine Datenbankprüfung jeden Antrag abgelehnt, der über das
-- Urlaubskonto hinausgeht. Das ist jetzt erlaubt: Die App weist beim
-- Beantragen deutlich darauf hin und verlangt eine ausdrückliche Bestätigung,
-- die Entscheidung trifft danach die Verwaltung.
--
-- Die Prüffunktion bleibt erhalten, damit sich die Sperre jederzeit wieder
-- einschalten lässt:
--   create trigger urlaub_grenze before insert on abwesenheiten
--   for each row execute function urlaub_grenze_pruefen();
-- ============================================================

drop trigger if exists urlaub_grenze on abwesenheiten;
