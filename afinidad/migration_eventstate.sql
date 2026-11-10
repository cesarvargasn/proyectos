-- ============================================================
-- Match Night — Fix event_state for multi-event (BULLETPROOF)
-- Drops EVERY check constraint on event_state (any name),
-- then gives id an auto-incrementing default.
-- Run once in Supabase SQL editor. Watch for "Success".
-- ============================================================

-- 1. Drop every CHECK constraint on event_state, whatever it's called
DO $$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.event_state'::regclass
      AND contype = 'c'
  LOOP
    EXECUTE format('ALTER TABLE event_state DROP CONSTRAINT %I', c.conname);
    RAISE NOTICE 'Dropped constraint: %', c.conname;
  END LOOP;
END $$;

-- 2. Make id auto-generate for new rows
CREATE SEQUENCE IF NOT EXISTS event_state_id_seq;
SELECT setval('event_state_id_seq', GREATEST((SELECT COALESCE(MAX(id), 1) FROM event_state), 1));
ALTER TABLE event_state ALTER COLUMN id SET DEFAULT nextval('event_state_id_seq');
