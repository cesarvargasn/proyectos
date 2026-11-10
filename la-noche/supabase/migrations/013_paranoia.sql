-- ============================================================
-- LA NOCHE — Migración 013: Paranoia (Wave 3, 2 de 4)
-- Correr DESPUÉS de 012. Requiere cartas: supabase/content/paranoia.sql
--
-- PARANOIA ('paranoia'):
--   La pregunta aparece SOLO en el celular del Preguntón (player_secrets,
--   leak-proof igual que Impostor: state lleva ids). La lee en silencio y
--   SEÑALA a un jugador (dice el nombre en voz alta). El señalado decide:
--   modo trago = paga {drink:1} para revelar la pregunta o la entierra;
--   modo social = moneda al aire (server) decide si se revela gratis.
--   Sin puntos: termina al agotar el mazo. Preguntón rota.
--
--   Fases: senalar (sin timer; host puede forzar = salta turno) →
--   decidir (30s; timeout = enterrada) → reveal (host pasa) → sig turno.
--   state = { phase, phase_ends_at, deck:[{id}], round_idx, turn_order,
--             turn_idx, target, decision:null|pago|enterrada|cara|sello,
--             question:null|text (pública solo si se reveló) }
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

revoke execute on function pa_asker(jsonb), pa_start_turn(uuid, game_sessions),
  pa_can_advance(game_sessions), pa_decide(uuid, game_sessions, boolean)
from public, anon, authenticated;

-- ============ DISPATCHERS VÍA RENAME + DELEGACIÓN ============
-- Truco: las 4 funciones de 012 se RENOMBRAN a *_012 y se crean wrappers
-- que atienden paranoia y delegan el resto. Así 013 no repite ~700 líneas.
-- ⚠ La migración 014 debe consolidar (reescribir completo) o repetir el
-- patrón renombrando los wrappers.

-- launch: paranoia
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

revoke execute on function pa_launch(uuid, uuid, jsonb, int, int, uuid[])
from public, anon, authenticated;

-- renombra las de 012 (idempotencia: solo si el wrapper aún no existe)
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'launch_game_012') then
    alter function launch_game(uuid, text, jsonb) rename to launch_game_012;
    alter function advance_phase(uuid, boolean) rename to advance_phase_012;
    alter function submit_action(uuid, text, jsonb) rename to submit_action_012;
    alter function dev_bot_tick(uuid) rename to dev_bot_tick_012;
  end if;
end $$;

create or replace function launch_game(p_party_id uuid, p_game_type text, p_opts jsonb default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_intensity int;
  v_n int;
  v_ids uuid[];
begin
  if p_game_type <> 'paranoia' then
    return launch_game_012(p_party_id, p_game_type, p_opts);
  end if;
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  if exists (select 1 from game_sessions where party_id = p_party_id and status = 'active') then
    raise exception 'YA_HAY_JUEGO';
  end if;
  select coalesce((settings->>'intensity')::int, 2) into v_intensity from parties where id = p_party_id;
  v_intensity := least(5, greatest(1, coalesce((p_opts->>'intensity')::int, v_intensity)));
  v_n := least(60, greatest(3, coalesce((p_opts->>'n_cards')::int, 10)));
  v_ids := acting_player_ids(p_party_id);
  insert into game_sessions (party_id, game_type, state)
    values (p_party_id, 'paranoia', '{}'::jsonb) returning * into v_session;
  perform pa_launch(p_party_id, v_session.id, p_opts, v_intensity, v_n, v_ids);
  update parties set status = 'in_game' where id = p_party_id;
  return v_session.id;
end $$;

create or replace function advance_phase(p_party_id uuid, p_force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
begin
  select * into v_session from active_session(p_party_id);
  if v_session.id is not null and v_session.game_type <> 'paranoia' then
    perform advance_phase_012(p_party_id, p_force); return;
  end if;
  if p_force then
    if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  elsif not is_member(p_party_id) then
    raise exception 'NO_MIEMBRO';
  end if;
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;

  if v_session.state->>'phase' = 'senalar' then
    if not p_force then return; end if; -- host salta el turno del dormido
    perform pa_start_turn(p_party_id, v_session);
  elsif v_session.state->>'phase' = 'decidir' then
    if not p_force and not pa_can_advance(v_session) then return; end if;
    -- timeout o host = enterrada sin pagar
    update game_sessions set state = state || jsonb_build_object(
      'phase', 'reveal', 'decision', 'enterrada', 'question', null, 'phase_ends_at', null)
      where id = v_session.id;
  elsif v_session.state->>'phase' = 'reveal' then
    if not p_force then return; end if;
    perform pa_start_turn(p_party_id, v_session);
  end if;
end $$;

create or replace function submit_action(p_party_id uuid, p_action text, p_payload jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_me uuid := my_player_id(p_party_id);
  v_target uuid;
begin
  select * into v_session from active_session(p_party_id);
  if v_session.id is not null and v_session.game_type <> 'paranoia' then
    perform submit_action_012(p_party_id, p_action, p_payload); return;
  end if;
  if v_me is null then raise exception 'NO_MIEMBRO'; end if;
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;

  if p_action = 'point' and v_session.state->>'phase' = 'senalar' then
    if v_me <> pa_asker(v_session.state) then raise exception 'NO_ES_TU_TURNO'; end if;
    v_target := (p_payload->>'target')::uuid;
    if v_target = v_me then raise exception 'NO_AUTOSENALADO'; end if;
    if not exists (select 1 from players where id = v_target and party_id = p_party_id and status = 'active') then
      raise exception 'SENALADO_INVALIDO';
    end if;
    update game_sessions set state = state || jsonb_build_object(
      'phase', 'decidir', 'target', v_target,
      'phase_ends_at', to_jsonb(now() + interval '30 seconds'))
      where id = v_session.id;
  elsif p_action = 'decide' and v_session.state->>'phase' = 'decidir' then
    if v_me <> (v_session.state->>'target')::uuid then raise exception 'NO_ERES_EL_SENALADO'; end if;
    perform pa_decide(p_party_id, v_session, coalesce((p_payload->>'pay')::boolean, false));
  else
    raise exception 'ACCION_INVALIDA';
  end if;
end $$;

create or replace function dev_bot_tick(p_party_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_targets uuid[];
  v_who uuid;
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then return; end if;
  if v_session.game_type <> 'paranoia' then
    perform dev_bot_tick_012(p_party_id); return;
  end if;

  if v_session.state->>'phase' = 'senalar' then
    v_who := pa_asker(v_session.state);
    if exists (select 1 from players where id = v_who and is_bot and status = 'active') then
      v_targets := array(select id from players
        where party_id = p_party_id and status = 'active' and id <> v_who);
      update game_sessions set state = state || jsonb_build_object(
        'phase', 'decidir', 'target', v_targets[1 + floor(random()*array_length(v_targets,1))::int],
        'phase_ends_at', to_jsonb(now() + interval '30 seconds'))
        where id = v_session.id;
    end if;
  elsif v_session.state->>'phase' = 'decidir' then
    v_who := (v_session.state->>'target')::uuid;
    if exists (select 1 from players where id = v_who and is_bot and status = 'active') then
      perform pa_decide(p_party_id, v_session, random() < 0.5);
    elsif pa_can_advance(v_session) then
      perform advance_phase(p_party_id, false);
    end if;
  end if;
end $$;
