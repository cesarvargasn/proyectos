-- ============================================================
-- Match Night — Admin Policies Fix
-- Run ONCE in Supabase SQL editor AFTER migration_security.sql
-- Adds back the anon policies needed for admin panel operations.
-- Admin uses the anon key (client-side password), so needs these.
-- ============================================================

-- events: admin creates events
CREATE POLICY "anon_insert_events" ON events
  FOR INSERT TO anon WITH CHECK (true);

-- participants: admin reads list, joins as admin, cleanup
CREATE POLICY "anon_select_participants" ON participants
  FOR SELECT TO anon USING (true);

CREATE POLICY "anon_insert_participants" ON participants
  FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY "anon_delete_participants" ON participants
  FOR DELETE TO anon USING (true);

-- answers: matching algorithm reads answers
CREATE POLICY "anon_select_answers" ON answers
  FOR SELECT TO anon USING (true);

-- matches: admin runs matching (delete old + insert new), admin panel reads results
CREATE POLICY "anon_select_matches" ON matches
  FOR SELECT TO anon USING (true);

CREATE POLICY "anon_insert_matches" ON matches
  FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY "anon_delete_matches" ON matches
  FOR DELETE TO anon USING (true);

-- event_state: admin creates state row, updates phase/reveal_at/admin fields
CREATE POLICY "anon_insert_event_state" ON event_state
  FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY "anon_update_event_state" ON event_state
  FOR UPDATE TO anon USING (true) WITH CHECK (true);

-- event_questions: admin syncs, toggles, adds questions
CREATE POLICY "anon_insert_event_questions" ON event_questions
  FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY "anon_update_event_questions" ON event_questions
  FOR UPDATE TO anon USING (true) WITH CHECK (true);

CREATE POLICY "anon_delete_event_questions" ON event_questions
  FOR DELETE TO anon USING (true);

-- questions: admin adds/deletes questions
CREATE POLICY "anon_insert_questions" ON questions
  FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY "anon_delete_questions" ON questions
  FOR DELETE TO anon USING (true);
