-- ============================================================
-- Afinidad — Rondas embudo (2026-11-01)
-- Run ONCE in Supabase SQL editor.
--
-- La noche va por etapas anidadas:
--   ronda 1 = 2 grupos → ronda 2 = 4 grupos → ronda 3 = grupos de ~4
--   → duplas finales (tabla matches de siempre, armadas DENTRO de cada
--   grupo de la ronda 3).
--
-- funnel_groups: solo el admin (authenticated) lee/escribe.
-- Participantes ven SOLO su grupo de la ronda actual vía get_my_group
-- (nombres de pila, nunca email/teléfono).
-- ============================================================

ALTER TABLE event_state ADD COLUMN IF NOT EXISTS funnel_round smallint NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS funnel_groups (
  event_id       uuid     NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  round          smallint NOT NULL CHECK (round BETWEEN 1 AND 3),
  group_idx      smallint NOT NULL,
  participant_id uuid     NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  score          float    NOT NULL DEFAULT 0,
  PRIMARY KEY (event_id, round, participant_id)
);

ALTER TABLE funnel_groups ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admin_all_funnel_groups" ON funnel_groups;
CREATE POLICY "admin_all_funnel_groups" ON funnel_groups
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON funnel_groups TO authenticated;

-- get_my_group: grupo del participante en la ronda ACTUAL del evento
-- (event_state.funnel_round). Devuelve 0 filas si no hay ronda activa.
CREATE OR REPLACE FUNCTION get_my_group(
  p_token    text,
  p_event_id uuid
)
RETURNS TABLE(round smallint, group_idx smallint, score float, members text[])
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_participant_id uuid;
  v_round smallint;
BEGIN
  SELECT p.id INTO v_participant_id
  FROM participants p
  WHERE p.token = p_token AND p.event_id = p_event_id;

  IF v_participant_id IS NULL THEN
    RAISE EXCEPTION 'Token inválido o evento incorrecto';
  END IF;

  SELECT es.funnel_round INTO v_round
  FROM event_state es
  WHERE es.event_id = p_event_id
  ORDER BY es.id LIMIT 1;

  IF coalesce(v_round, 0) = 0 THEN RETURN; END IF;

  RETURN QUERY
    SELECT me.round, me.group_idx, me.score,
      coalesce((
        SELECT array_agg(p.first_name ORDER BY p.first_name)
        FROM funnel_groups o
        JOIN participants p ON p.id = o.participant_id
        WHERE o.event_id = p_event_id AND o.round = me.round
          AND o.group_idx = me.group_idx AND o.participant_id <> v_participant_id
      ), '{}')
    FROM funnel_groups me
    WHERE me.event_id = p_event_id AND me.round = v_round
      AND me.participant_id = v_participant_id;
END;
$$;

GRANT EXECUTE ON FUNCTION get_my_group(text, uuid) TO anon, authenticated;
