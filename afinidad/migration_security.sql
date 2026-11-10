-- ============================================================
-- Match Night — Security Migration (Problem 1: PII lockdown)
-- Run ONCE in Supabase SQL editor
-- ============================================================

-- 1. Drop all open anon policies
DROP POLICY IF EXISTS "anon_all_participants"   ON participants;
DROP POLICY IF EXISTS "anon_all_questions"      ON questions;
DROP POLICY IF EXISTS "anon_all_event_questions" ON event_questions;
DROP POLICY IF EXISTS "anon_all_answers"        ON answers;
DROP POLICY IF EXISTS "anon_all_matches"        ON matches;
DROP POLICY IF EXISTS "anon_all_event_state"    ON event_state;
DROP POLICY IF EXISTS "events_open"             ON events;

-- 2. participants: NO direct anon access (insert/select/update via RPC)
-- (no policies = RLS blocks everything for anon)

-- 3. answers: NO direct anon access
-- (no policies = RLS blocks everything for anon)

-- 4. matches: NO direct anon access
-- (no policies = RLS blocks everything for anon)

-- 5. Read-only tables (no PII)
CREATE POLICY "anon_select_event_state" ON event_state
  FOR SELECT TO anon USING (true);

CREATE POLICY "anon_select_questions" ON questions
  FOR SELECT TO anon USING (true);

CREATE POLICY "anon_select_event_questions" ON event_questions
  FOR SELECT TO anon USING (true);

-- events: SELECT only (name + code — no PII)
CREATE POLICY "anon_select_events" ON events
  FOR SELECT TO anon USING (true);

-- ============================================================
-- RPCs (SECURITY DEFINER = run as postgres, bypass RLS)
-- ============================================================

-- RPC 1: register_participant
-- Inserts participant, returns id + token + first_name only
CREATE OR REPLACE FUNCTION register_participant(
  p_event_id   uuid,
  p_first_name text,
  p_email      text,
  p_phone      text    DEFAULT NULL,
  p_birthday   date    DEFAULT NULL
)
RETURNS TABLE(id uuid, token text, first_name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
    INSERT INTO participants (event_id, first_name, email, phone, birthday)
    VALUES (p_event_id, p_first_name, p_email, p_phone, p_birthday)
    RETURNING participants.id, participants.token, participants.first_name;
END;
$$;

-- RPC 2: submit_answers
-- Validates token, upserts answers, marks completed_at
-- p_answers: [{question_id: uuid, value: int}, ...]
CREATE OR REPLACE FUNCTION submit_answers(
  p_token     text,
  p_event_id  uuid,
  p_answers   jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_participant_id uuid;
  v_answer         jsonb;
BEGIN
  SELECT id INTO v_participant_id
  FROM participants
  WHERE token = p_token AND event_id = p_event_id;

  IF v_participant_id IS NULL THEN
    RAISE EXCEPTION 'Token inválido o evento incorrecto';
  END IF;

  FOR v_answer IN SELECT * FROM jsonb_array_elements(p_answers)
  LOOP
    INSERT INTO answers (participant_id, question_id, value)
    VALUES (
      v_participant_id,
      (v_answer->>'question_id')::uuid,
      (v_answer->>'value')::int
    )
    ON CONFLICT (participant_id, question_id)
    DO UPDATE SET value = EXCLUDED.value;
  END LOOP;

  UPDATE participants
  SET completed_at = now()
  WHERE id = v_participant_id;
END;
$$;

-- RPC 3: get_my_match
-- Returns partner's first_name + score ONLY (no PII)
CREATE OR REPLACE FUNCTION get_my_match(
  p_token    text,
  p_event_id uuid
)
RETURNS TABLE(partner_name text, score float)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_participant_id uuid;
BEGIN
  SELECT id INTO v_participant_id
  FROM participants
  WHERE token = p_token AND event_id = p_event_id;

  IF v_participant_id IS NULL THEN
    RAISE EXCEPTION 'Token inválido o evento incorrecto';
  END IF;

  RETURN QUERY
    SELECT
      CASE
        WHEN m.participant_a = v_participant_id THEN pb.first_name
        ELSE pa.first_name
      END AS partner_name,
      m.score
    FROM matches m
    JOIN participants pa ON pa.id = m.participant_a
    JOIN participants pb ON pb.id = m.participant_b
    WHERE m.event_id = p_event_id
      AND (m.participant_a = v_participant_id OR m.participant_b = v_participant_id);
END;
$$;
