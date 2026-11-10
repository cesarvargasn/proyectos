-- ============================================================
-- Match Night — Multi-event migration
-- Run this in the Supabase SQL editor
-- ============================================================

-- 1. Events table
CREATE TABLE IF NOT EXISTS events (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text        NOT NULL DEFAULT 'Match Night',
  code        text        UNIQUE NOT NULL,
  created_at  timestamptz DEFAULT now()
);

ALTER TABLE events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "events_open" ON events;
CREATE POLICY "events_open" ON events FOR ALL USING (true) WITH CHECK (true);

-- 2. Add event_id to participants
ALTER TABLE participants ADD COLUMN IF NOT EXISTS event_id uuid REFERENCES events(id) ON DELETE CASCADE;

-- 3. Add event_id to event_questions
ALTER TABLE event_questions ADD COLUMN IF NOT EXISTS event_id uuid REFERENCES events(id) ON DELETE CASCADE;

-- 4. Add event_id to matches
ALTER TABLE matches ADD COLUMN IF NOT EXISTS event_id uuid REFERENCES events(id) ON DELETE CASCADE;

-- 5. Add event_id to event_state + allow multiple rows (drop id=1 default)
ALTER TABLE event_state ADD COLUMN IF NOT EXISTS event_id uuid REFERENCES events(id) ON DELETE CASCADE;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.sequences
    WHERE sequence_name = 'event_state_id_seq'
  ) THEN
    CREATE SEQUENCE event_state_id_seq START WITH 2;
    ALTER TABLE event_state ALTER COLUMN id SET DEFAULT nextval('event_state_id_seq');
  END IF;
END $$;
