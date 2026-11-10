-- ============================================================
-- Match Night — Admin Auth + PII re-lock
-- Run ONCE in Supabase SQL editor, AFTER migration_admin_policies.sql
--
-- Replaces the temporary "anon can do everything" policies with:
--   • anon  → SELECT only on non-PII tables (events, questions,
--             event_questions, event_state). Register/answer/match
--             reads still go through SECURITY DEFINER RPCs.
--   • authenticated (the admin, logged in via Supabase Auth) → full CRUD.
--
-- After this, dumping participants/answers/matches with the public anon
-- key is no longer possible — closes the PII hole.
-- ============================================================

-- ── 1. Drop the temporary anon write / PII-read policies ──
DROP POLICY IF EXISTS "anon_insert_events"           ON events;

DROP POLICY IF EXISTS "anon_select_participants"     ON participants;
DROP POLICY IF EXISTS "anon_insert_participants"     ON participants;
DROP POLICY IF EXISTS "anon_delete_participants"     ON participants;

DROP POLICY IF EXISTS "anon_select_answers"          ON answers;

DROP POLICY IF EXISTS "anon_select_matches"          ON matches;
DROP POLICY IF EXISTS "anon_insert_matches"          ON matches;
DROP POLICY IF EXISTS "anon_delete_matches"          ON matches;

DROP POLICY IF EXISTS "anon_insert_event_state"      ON event_state;
DROP POLICY IF EXISTS "anon_update_event_state"      ON event_state;

DROP POLICY IF EXISTS "anon_insert_event_questions"  ON event_questions;
DROP POLICY IF EXISTS "anon_update_event_questions"  ON event_questions;
DROP POLICY IF EXISTS "anon_delete_event_questions"  ON event_questions;

DROP POLICY IF EXISTS "anon_insert_questions"        ON questions;
DROP POLICY IF EXISTS "anon_delete_questions"        ON questions;

-- Kept (from migration_security.sql) — anon SELECT, no PII:
--   anon_select_events, anon_select_questions,
--   anon_select_event_questions, anon_select_event_state

-- ── 2. Authenticated admin → full CRUD on every table ──
CREATE POLICY "admin_all_events"          ON events          FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "admin_all_participants"    ON participants    FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "admin_all_answers"         ON answers         FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "admin_all_matches"         ON matches         FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "admin_all_event_state"     ON event_state     FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "admin_all_questions"       ON questions       FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "admin_all_event_questions" ON event_questions FOR ALL TO authenticated USING (true) WITH CHECK (true);
