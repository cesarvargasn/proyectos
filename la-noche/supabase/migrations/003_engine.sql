-- ============================================================
-- LA NOCHE — Migración 003: Engine (Fase 2)
-- Correr DESPUÉS de 002. Motor genérico + juego "Prueba".
--
-- Modelo: game_sessions.state (jsonb) = única verdad.
--   state = { phase, phase_ends_at, ready:{}, votes:{}, texts:{},
--             turn_order:[], turn_idx, reveal:{} }
-- Toda acción entra por submit_action / advance_phase con
-- validación server. Timers anclados: phase_ends_at timestamptz.
-- force_advance (host) SIEMPRE puede avanzar — regla del plan.
-- Prueba: secreto(30s) → voto(30s) → texto(45s) → turnos(15s/turno) → reveal
-- ============================================================

-- ---------- helpers internos (NO invocables por clientes) ----------

create or replace function active_session(p_party_id uuid)
returns game_sessions language sql stable security definer set search_path = public as $$
  select * from game_sessions
  where party_id = p_party_id and status = 'active'
  order by created_at desc limit 1;
$$;

create or replace function my_player_id(p_party_id uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select id from players
  where party_id = p_party_id and auth_user_id = auth.uid() and status = 'active';
$$;

create or replace function acting_player_ids(p_party_id uuid)
returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(id order by joined_at), '{}') from players
  where party_id = p_party_id and status = 'active';
$$;

create or replace function prueba_enter_phase(p_session game_sessions, p_phase text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_ids uuid[] := acting_player_ids(p_session.party_id);
  v_secret_words text[] := array['LINTERNA','CACTUS','KARAOKE','SUBMARINO','PIÑATA','METEORITO','FLAMENCO','TROMBÓN'];
  v_pid uuid;
  i int := 0;
begin
  v_state := v_state || jsonb_build_object('phase', p_phase, 'ready', '{}'::jsonb);

  if p_phase = 'secreto' then
    -- SecretDeal: palabra secreta por jugador (RLS: cada quien lee solo la suya)
    delete from player_secrets where game_session_id = p_session.id;
    foreach v_pid in array v_ids loop
      i := i + 1;
      insert into player_secrets (game_session_id, player_id, payload)
      values (p_session.id, v_pid, jsonb_build_object('word', v_secret_words[1 + (i % array_length(v_secret_words,1))]));
    end loop;
    v_state := v_state || jsonb_build_object('phase_ends_at', to_jsonb(now() + interval '30 seconds'));

  elsif p_phase = 'voto' then
    v_state := v_state || jsonb_build_object('votes', '{}'::jsonb, 'phase_ends_at', to_jsonb(now() + interval '30 seconds'));

  elsif p_phase = 'texto' then
    v_state := v_state || jsonb_build_object('texts', '{}'::jsonb, 'phase_ends_at', to_jsonb(now() + interval '45 seconds'));

  elsif p_phase = 'turnos' then
    v_state := v_state || jsonb_build_object(
      'turn_order', to_jsonb(v_ids), 'turn_idx', 0,
      'phase_ends_at', to_jsonb(now() + interval '15 seconds'));

  elsif p_phase = 'reveal' then
    -- Prueba es juego de test: secretos se hacen públicos al final
    v_state := v_state || jsonb_build_object(
      'phase_ends_at', null,
      'reveal', (
        select coalesce(jsonb_object_agg(ps.player_id, ps.payload->>'word'), '{}')
        from player_secrets ps where ps.game_session_id = p_session.id
      ));
  end if;

  return v_state;
end $$;

create or replace function prueba_next_phase(p_phase text)
returns text language sql immutable as $$
  select case p_phase
    when 'secreto' then 'voto'
    when 'voto'    then 'texto'
    when 'texto'   then 'turnos'
    when 'turnos'  then 'reveal'
    else null end;
$$;

-- ¿pueden avanzar sin forzar? (todos actuaron O timer vencido)
-- En turnos solo el timer cuenta aquí; el paso normal es prueba_step_turn.
create or replace function prueba_can_advance(p_session game_sessions)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_phase text := v_state->>'phase';
  v_ids uuid[] := acting_player_ids(p_session.party_id);
  v_expired boolean := coalesce((v_state->>'phase_ends_at')::timestamptz < now(), false);
begin
  if v_phase = 'turnos' then return v_expired; end if;
  if v_expired then return true; end if;
  if v_phase = 'secreto' then
    return (select bool_and(v_state->'ready' ? id::text) from unnest(v_ids) id);
  elsif v_phase = 'voto' then
    return (select bool_and(v_state->'votes' ? id::text) from unnest(v_ids) id);
  elsif v_phase = 'texto' then
    return (select bool_and(v_state->'texts' ? id::text) from unnest(v_ids) id);
  end if;
  return false;
end $$;

-- Avanza UN turno (salta jugadores idos); al agotarse pasa a reveal.
create or replace function prueba_step_turn(p_party_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  v_order uuid[];
  v_idx int;
begin
  select * into v_session from active_session(p_party_id);
  if v_session.id is null or v_session.state->>'phase' <> 'turnos' then return; end if;
  v_state := v_session.state;
  v_order := array(select (e#>>'{}')::uuid from jsonb_array_elements(v_state->'turn_order') e);
  v_idx := (v_state->>'turn_idx')::int + 1;
  while v_idx < array_length(v_order,1)
    and not exists (select 1 from players where id = v_order[v_idx+1] and status = 'active') loop
    v_idx := v_idx + 1;
  end loop;
  if v_idx < array_length(v_order,1) then
    update game_sessions set state = v_state || jsonb_build_object(
      'turn_idx', v_idx, 'phase_ends_at', to_jsonb(now() + interval '15 seconds'))
      where id = v_session.id;
  else
    update game_sessions set state = prueba_enter_phase(v_session, 'reveal') where id = v_session.id;
  end if;
end $$;

-- helpers internos: nadie los llama por RPC
revoke execute on function active_session(uuid), my_player_id(uuid),
  acting_player_ids(uuid), prueba_enter_phase(game_sessions, text),
  prueba_next_phase(text), prueba_can_advance(game_sessions),
  prueba_step_turn(uuid)
from public, anon, authenticated;

-- ---------- RPCs públicos del engine ----------

create or replace function launch_game(p_party_id uuid, p_game_type text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  if p_game_type <> 'prueba' then raise exception 'JUEGO_NO_DISPONIBLE'; end if;
  if exists (select 1 from game_sessions where party_id = p_party_id and status = 'active') then
    raise exception 'YA_HAY_JUEGO';
  end if;

  insert into game_sessions (party_id, game_type, state)
    values (p_party_id, p_game_type, '{}'::jsonb)
    returning * into v_session;
  update game_sessions
    set state = prueba_enter_phase(v_session, 'secreto')
    where id = v_session.id;
  update parties set status = 'in_game' where id = p_party_id;
  return v_session.id;
end $$;

create or replace function end_game(p_party_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  update game_sessions set status = 'ended' where party_id = p_party_id and status = 'active';
  update parties set status = 'lobby' where id = p_party_id;
end $$;

-- p_force=true → SOLO host, avanza SIEMPRE (el botón más importante).
-- p_force=false → cualquier miembro; server valida (listos o timer).
create or replace function advance_phase(p_party_id uuid, p_force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_phase text;
  v_next text;
begin
  if p_force then
    if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  elsif not is_member(p_party_id) then
    raise exception 'NO_MIEMBRO';
  end if;

  select * into v_session from active_session(p_party_id);
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;
  v_phase := v_session.state->>'phase';

  if not p_force and not prueba_can_advance(v_session) then
    return; -- aún no toca; silencioso
  end if;

  if v_phase = 'turnos' then
    perform prueba_step_turn(p_party_id);
    return;
  end if;

  v_next := prueba_next_phase(v_phase);
  if v_next is null then
    perform end_game(p_party_id); -- avanzar desde reveal = volver al lobby
    return;
  end if;
  update game_sessions set state = prueba_enter_phase(v_session, v_next) where id = v_session.id;
end $$;

-- Acción de jugador, validada por fase.
create or replace function submit_action(p_party_id uuid, p_action text, p_payload jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  v_phase text;
  v_me uuid := my_player_id(p_party_id);
  v_target uuid;
  v_text text;
  v_order uuid[];
begin
  if v_me is null then raise exception 'NO_MIEMBRO'; end if;
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;
  v_state := v_session.state;
  v_phase := v_state->>'phase';

  if p_action = 'ready' and v_phase = 'secreto' then
    v_state := jsonb_set(v_state, array['ready', v_me::text], 'true');

  elsif p_action = 'vote' and v_phase = 'voto' then
    v_target := (p_payload->>'target')::uuid;
    if v_target = v_me then raise exception 'NO_AUTOVOTO'; end if;
    if not exists (select 1 from players where id = v_target and party_id = p_party_id and status = 'active') then
      raise exception 'VOTO_INVALIDO';
    end if;
    v_state := jsonb_set(v_state, array['votes', v_me::text], to_jsonb(v_target::text));

  elsif p_action = 'text' and v_phase = 'texto' then
    v_text := left(trim(coalesce(p_payload->>'text','')), 80);
    if v_text = '' then raise exception 'TEXTO_VACIO'; end if;
    v_state := jsonb_set(v_state, array['texts', v_me::text], to_jsonb(v_text));

  elsif p_action = 'turn_done' and v_phase = 'turnos' then
    v_order := array(select (e#>>'{}')::uuid from jsonb_array_elements(v_state->'turn_order') e);
    if v_order[(v_state->>'turn_idx')::int + 1] <> v_me then raise exception 'NO_ES_TU_TURNO'; end if;
    perform prueba_step_turn(p_party_id);
    return;

  else
    raise exception 'ACCION_INVALIDA';
  end if;

  update game_sessions set state = v_state where id = v_session.id;

  -- auto-avance si con esta acción quedaron todos
  select * into v_session from game_sessions where id = v_session.id;
  if prueba_can_advance(v_session) then
    perform advance_phase(p_party_id, false);
  end if;
end $$;

-- ---------- BOT RUNNER ----------
-- Host (cliente) lo llama cada ~3s con DEV_BOTS: cada bot hace
-- una acción válida en la fase actual.
create or replace function dev_bot_tick(p_party_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  v_phase text;
  v_bot record;
  v_targets uuid[];
  v_words text[] := array['épica','confusa','legendaria','sudorosa','inolvidable','rara','gloriosa'];
  v_order uuid[];
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then return; end if;
  v_phase := v_session.state->>'phase';

  for v_bot in select id from players where party_id = p_party_id and is_bot and status = 'active' loop
    v_state := (select state from game_sessions where id = v_session.id);

    if v_phase = 'secreto' and not (v_state->'ready' ? v_bot.id::text) then
      update game_sessions set state = jsonb_set(state, array['ready', v_bot.id::text], 'true')
        where id = v_session.id;

    elsif v_phase = 'voto' and not (v_state->'votes' ? v_bot.id::text) then
      v_targets := array(select id from players where party_id = p_party_id and status = 'active' and id <> v_bot.id);
      update game_sessions set state = jsonb_set(state, array['votes', v_bot.id::text],
        to_jsonb(v_targets[1 + floor(random()*array_length(v_targets,1))::int]::text))
        where id = v_session.id;

    elsif v_phase = 'texto' and not (v_state->'texts' ? v_bot.id::text) then
      update game_sessions set state = jsonb_set(state, array['texts', v_bot.id::text],
        to_jsonb(v_words[1 + floor(random()*array_length(v_words,1))::int]))
        where id = v_session.id;

    elsif v_phase = 'turnos' then
      v_order := array(select (e#>>'{}')::uuid from jsonb_array_elements(v_state->'turn_order') e);
      if v_order[(v_state->>'turn_idx')::int + 1] = v_bot.id then
        perform prueba_step_turn(p_party_id);
      end if;
    end if;
  end loop;

  -- si con lo de los bots quedaron todos, avanza
  select * into v_session from game_sessions where id = v_session.id;
  if v_session.status = 'active' and prueba_can_advance(v_session) then
    perform advance_phase(p_party_id, false);
  end if;
end $$;
