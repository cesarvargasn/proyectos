-- ============================================================
-- LA NOCHE — Migración 021: fix Paranoia (helpers pa_* faltantes)
--
-- Bug reportado 2026-07-18: al lanzar Paranoia →
--   "function pa_launch(uuid, uuid, jsonb, integer, integer, uuid[]) does not exist"
-- Causa: 013_paranoia.sql nunca corrió en prod. Los dispatchers de
-- 015/019 llaman pa_launch/pa_start_turn/pa_can_advance/pa_asker/pa_decide,
-- pero esas funciones solo se creaban en 013.
--
-- ⚠ NO correr 013 ahora: su bloque final renombra los dispatchers
-- actuales (019) a *_012 e instala wrappers viejos → rompería Wave 4.
-- Esta migración trae SOLO los 5 helpers pa_* de 013, sin tocar
-- dispatchers. Idempotente (create or replace).
--
-- Después de correr esto: correr supabase/content/paranoia.sql si las
-- cartas tampoco están (si Paranoia da SIN_CARTAS, es eso).
-- ============================================================

create or replace function pa_asker(p_state jsonb)
returns uuid language sql immutable as $$
  select (p_state->'turn_order'->>((p_state->>'turn_idx')::int))::uuid;
$$;

-- arranca el turno round_idx+1 (o termina el juego si no hay más cartas)
create or replace function pa_start_turn(p_party_id uuid, p_session game_sessions)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_round int := coalesce((v_state->>'round_idx')::int, -1) + 1;
  v_turn int;
  v_q text;
begin
  if v_round >= jsonb_array_length(v_state->'deck') then
    perform end_game(p_party_id); return;
  end if;
  v_turn := next_active_turn(v_state->'turn_order', coalesce((v_state->>'turn_idx')::int, -1));
  if v_turn = -1 then perform end_game(p_party_id); return; end if;

  select text_es into v_q from content_cards
    where id = (v_state->'deck'->v_round->>'id')::uuid;
  if v_q is null then perform end_game(p_party_id); return; end if;

  delete from player_secrets where game_session_id = p_session.id;
  insert into player_secrets (game_session_id, player_id, payload)
    values (p_session.id, (v_state->'turn_order'->>v_turn)::uuid,
            jsonb_build_object('question', v_q));

  update game_sessions set state = v_state || jsonb_build_object(
    'phase', 'senalar', 'round_idx', v_round, 'turn_idx', v_turn,
    'target', null, 'decision', null, 'question', null, 'phase_ends_at', null)
  where id = p_session.id;
end $$;

create or replace function pa_can_advance(p_session game_sessions)
returns boolean language sql stable as $$
  select p_session.state->>'phase' = 'decidir'
     and coalesce((p_session.state->>'phase_ends_at')::timestamptz < now(), false);
$$;

-- resuelve la decisión del señalado; p_pay solo aplica en modo trago
create or replace function pa_decide(p_party_id uuid, p_session game_sessions, p_pay boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_mode text;
  v_decision text;
  v_reveal boolean;
  v_q text;
begin
  select coalesce(settings->>'mode', 'social') into v_mode from parties where id = p_party_id;
  if v_mode = 'drinking' then
    v_decision := case when p_pay then 'pago' else 'enterrada' end;
    v_reveal := p_pay;
  else
    v_reveal := random() < 0.5; -- moneda al aire
    v_decision := case when v_reveal then 'cara' else 'sello' end;
  end if;
  if v_reveal then
    select payload->>'question' into v_q from player_secrets
      where game_session_id = p_session.id limit 1;
  end if;
  update game_sessions set state = v_state || jsonb_build_object(
    'phase', 'reveal', 'decision', v_decision,
    'question', v_q, 'phase_ends_at', null)
  where id = p_session.id;
end $$;

create or replace function pa_launch(p_party_id uuid, p_session_id uuid, p_opts jsonb,
                                     p_intensity int, p_n int, p_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare
  v_deck jsonb;
  v_card_ids uuid[];
  v_session game_sessions;
begin
  if p_opts ? 'card_ids' then
    v_card_ids := array(select (e#>>'{}')::uuid from jsonb_array_elements(p_opts->'card_ids') e);
    if coalesce(array_length(v_card_ids, 1), 0) = 0 then v_card_ids := null; end if;
  end if;
  if v_card_ids is not null then
    select coalesce(jsonb_agg(jsonb_build_object('id', id)
             order by array_position(v_card_ids, id)), '[]') into v_deck
    from content_cards
    where id = any(v_card_ids) and game_type = 'paranoia' and enabled;
  else
    select coalesce(jsonb_agg(c.j), '[]') into v_deck from (
      select jsonb_build_object('id', id) as j
      from content_cards
      where game_type = 'paranoia' and intensity <= p_intensity and enabled
      order by random() limit p_n
    ) c;
  end if;
  if jsonb_array_length(v_deck) = 0 then
    delete from game_sessions where id = p_session_id;
    raise exception 'SIN_CARTAS';
  end if;
  update game_sessions set state = jsonb_build_object(
    'deck', v_deck, 'round_idx', -1, 'turn_idx', -1,
    'turn_order', (select jsonb_agg(to_jsonb(pid) order by random()) from unnest(p_ids) pid))
    where id = p_session_id;
  select * into v_session from game_sessions where id = p_session_id;
  perform pa_start_turn(p_party_id, v_session);
end $$;

revoke execute on function pa_asker(jsonb), pa_start_turn(uuid, game_sessions),
  pa_can_advance(game_sessions), pa_decide(uuid, game_sessions, boolean),
  pa_launch(uuid, uuid, jsonb, int, int, uuid[])
from public, anon, authenticated;
