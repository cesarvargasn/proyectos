-- ============================================================
-- Match Night — Feedback + Question-bank editor support
-- Run ONCE in Supabase SQL editor, AFTER migration_admin_auth.sql.
-- Then run seed_questions_bank.sql to import the question bank.
--
-- Adds:
--   • questions.text_en (bilingual nice-to-have) + soft delete (deleted_at)
--   • feedback_questions (editable post-event survey questions, global)
--   • feedback (responses, jsonb, participant_id nullable/anonymous)
--   • RLS: anon SELECT feedback_questions + INSERT feedback; admin full CRUD
--   • get_event_feedback() SECURITY DEFINER RPC for the admin summary
-- Does NOT touch matching or realtime.
-- ============================================================

-- ── 1. questions: bilingual + soft delete ──
ALTER TABLE questions ADD COLUMN IF NOT EXISTS text_en    text;
ALTER TABLE questions ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

-- ── 2. feedback_questions (global, editable by host) ──
CREATE TABLE IF NOT EXISTS feedback_questions (
  id          uuid primary key default gen_random_uuid(),
  text        text not null,
  type        text not null default 'rating' check (type in ('rating', 'boolean', 'text')),
  order_index int  not null default 0,
  active      boolean not null default true,
  created_at  timestamptz default now()
);

-- ── 3. feedback (responses) ──
CREATE TABLE IF NOT EXISTS feedback (
  id             uuid primary key default gen_random_uuid(),
  event_id       uuid references events(id) on delete cascade,
  participant_id uuid references participants(id) on delete set null,
  answers        jsonb not null default '{}'::jsonb,  -- { feedback_question_id: value }
  created_at     timestamptz default now()
);

CREATE INDEX IF NOT EXISTS feedback_event_idx ON feedback(event_id);

-- ── 4. RLS ──
ALTER TABLE feedback_questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE feedback           ENABLE ROW LEVEL SECURITY;

-- feedback_questions: anon may READ (to render the public form); admin full CRUD
DROP POLICY IF EXISTS "anon_select_feedback_questions" ON feedback_questions;
CREATE POLICY "anon_select_feedback_questions" ON feedback_questions
  FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS "admin_all_feedback_questions" ON feedback_questions;
CREATE POLICY "admin_all_feedback_questions" ON feedback_questions
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- feedback: anon may INSERT only (no SELECT — anonymous in aggregate); admin full CRUD
DROP POLICY IF EXISTS "anon_insert_feedback" ON feedback;
CREATE POLICY "anon_insert_feedback" ON feedback
  FOR INSERT TO anon WITH CHECK (true);
DROP POLICY IF EXISTS "admin_all_feedback" ON feedback;
CREATE POLICY "admin_all_feedback" ON feedback
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ── 5. Admin read RPC (SECURITY DEFINER) — anon cannot call it ──
CREATE OR REPLACE FUNCTION get_event_feedback(p_event_id uuid)
RETURNS TABLE(answers jsonb, created_at timestamptz)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT answers, created_at
  FROM feedback
  WHERE event_id = p_event_id
  ORDER BY created_at DESC;
$$;

REVOKE ALL    ON FUNCTION get_event_feedback(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION get_event_feedback(uuid) TO authenticated;

-- ── 6. Seed 5 draft feedback questions (only if table is empty) ──
INSERT INTO feedback_questions (text, type, order_index)
SELECT v.text, v.type, v.order_index
FROM (VALUES
  ('¿Qué tal estuvo el evento?',                       'rating',  1),
  ('¿Qué tan buena fue tu conexión de esta noche?',    'rating',  2),
  ('¿Conociste a alguien que seguirías viendo?',       'boolean', 3),
  ('¿Repetirías un Match Night?',                      'rating',  4),
  ('Comentario libre (opcional)',                      'text',    5)
) AS v(text, type, order_index)
WHERE NOT EXISTS (SELECT 1 FROM feedback_questions);
