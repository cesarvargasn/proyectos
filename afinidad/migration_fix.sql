-- ============================================================
-- Match Night — Fix migration (run after migration.sql)
-- ============================================================

-- 1. Drop unique constraint on question_id alone if it exists
--    (the old schema may have had UNIQUE(question_id) which blocks multi-event inserts)
DO $$
DECLARE
  v_constraint text;
BEGIN
  SELECT conname INTO v_constraint
  FROM pg_constraint
  WHERE conrelid = 'public.event_questions'::regclass
    AND contype = 'u'
    AND cardinality(conkey) = 1
    AND conkey[1] = (
      SELECT attnum FROM pg_attribute
      WHERE attrelid = 'public.event_questions'::regclass
        AND attname = 'question_id'
    );
  IF v_constraint IS NOT NULL THEN
    EXECUTE 'ALTER TABLE event_questions DROP CONSTRAINT ' || quote_ident(v_constraint);
    RAISE NOTICE 'Dropped constraint: %', v_constraint;
  ELSE
    RAISE NOTICE 'No single-column unique constraint on question_id found (OK)';
  END IF;
END $$;

-- 2. Clean up duplicate (event_id, question_id) pairs before adding unique constraint
DELETE FROM event_questions a
USING event_questions b
WHERE a.id > b.id
  AND a.event_id IS NOT DISTINCT FROM b.event_id
  AND a.question_id = b.question_id;

-- 3. Add composite unique constraint (event_id, question_id)
--    This allows the same question in multiple events but not twice in the same event
ALTER TABLE event_questions
  DROP CONSTRAINT IF EXISTS event_questions_event_question_unique;

ALTER TABLE event_questions
  ADD CONSTRAINT event_questions_event_question_unique
  UNIQUE (event_id, question_id);

-- 4. Make sure event_questions has open RLS for updates
DROP POLICY IF EXISTS "event_questions_open" ON event_questions;
ALTER TABLE event_questions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "event_questions_open" ON event_questions FOR ALL USING (true) WITH CHECK (true);
