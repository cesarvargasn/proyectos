-- ============================================================
-- LA NOCHE — Migración 004: Yo Nunca (Fase 3, juego 1)
-- Correr DESPUÉS de 003. Requiere cartas: correr también
-- supabase/content/yo-nunca.sql (generado con npm run content).
--
-- Flujo: pregunta(30s: YO SÍ / YO NO) → reveal (sin timer, host
-- pasa a la siguiente carta) → … → sin cartas = fin.
-- state = { phase, phase_ends_at, deck:[{text,intensity}],
--           round_idx, answers:{pid:'si'|'no'}, anon:bool }
-- anon: el host puede marcar la carta como reveal anónimo
-- (solo conteo, sin nombres) durante la pregunta.
--
-- Este archivo también convierte los RPCs del engine en
-- dispatchers por game_type (case explícito). Cada juego nuevo
-- agrega su rama en launch/advance/submit/bot_tick.
-- ============================================================

-- ---------- helpers yo-nunca (NO invocables por clientes) ----------

create or replace function yn_enter_phase(p_session game_sessions, p_phase text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_idx int;
begin
  v_state := v_state || jsonb_build_object('phase', p_phase);

  if p_phase = 'pregunta' then
    v_idx := coalesce((v_state->>'round_idx')::int, -1) + 1;
    v_state := v_state || jsonb_build_object(
      'round_idx', v_idx,
      'answers', '{}'::jsonb,
      'anon', false,
      'phase_ends_at', to_jsonb(now() + interval '30 seconds'));

  elsif p_phase = 'reveal' then
    v_state := v_state || jsonb_build_object('phase_ends_at', null);
  end if;

  return v_state;
end $$;

-- reveal → pregunta mientras queden cartas; si no, null (= fin del juego)
create or replace function yn_next_phase(p_session game_sessions)
returns text language sql stable as $$
  select case p_session.state->>'phase'
    when 'pregunta' then 'reveal'
    when 'reveal' then case
      when (p_session.state->>'round_idx')::int + 1 < jsonb_array_length(p_session.state->'deck')
      then 'pregunta' else null end
    else null end;
$$;

-- pregunta avanza cuando todos contestaron o venció el timer.
-- reveal NO avanza solo: el host pasa la carta (force).
create or replace function yn_can_advance(p_session game_sessions)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_ids uuid[] := acting_player_ids(p_session.party_id);
begin
  if v_state->>'phase' <> 'pregunta' then return false; end if;
  if coalesce((v_state->>'phase_ends_at')::timestamptz < now(), false) then return true; end if;
  return (select bool_and(v_state->'answers' ? id::text) from unnest(v_ids) id);
end $$;

revoke execute on function yn_enter_phase(game_sessions, text),
  yn_next_phase(game_sessions), yn_can_advance(game_sessions)
from public, anon, authenticated;

-- ---------- dispatchers del engine (reemplazan a los de 003) ----------

create or replace function launch_game(p_party_id uuid, p_game_type text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_intensity int;
  v_deck jsonb;
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  if p_game_type not in ('prueba', 'yo-nunca') then raise exception 'JUEGO_NO_DISPONIBLE'; end if;
  if exists (select 1 from game_sessions where party_id = p_party_id and status = 'active') then
    raise exception 'YA_HAY_JUEGO';
  end if;

  insert into game_sessions (party_id, game_type, state)
    values (p_party_id, p_game_type, '{}'::jsonb)
    returning * into v_session;

  if p_game_type = 'prueba' then
    update game_sessions set state = prueba_enter_phase(v_session, 'secreto') where id = v_session.id;

  elsif p_game_type = 'yo-nunca' then
    -- mazo: cartas con intensity <= intensidad de la party, barajadas, máx 15
    select coalesce((settings->>'intensity')::int, 2) into v_intensity from parties where id = p_party_id;
    select coalesce(jsonb_agg(c), '[]') into v_deck from (
      select jsonb_build_object('text', text_es, 'intensity', intensity) as c
      from content_cards
      where game_type = 'yo-nunca' and intensity <= v_intensity
      order by random() limit 15
    ) s;
    if jsonb_array_length(v_deck) = 0 then
      delete from game_sessions where id = v_session.id;
      raise exception 'SIN_CARTAS'; -- importar supabase/content/yo-nunca.sql primero
    end if;
    v_session.state := jsonb_build_object('deck', v_deck, 'round_idx', -1);
    update game_sessions set state = yn_enter_phase(v_session, 'pregunta') where id = v_session.id;
  end if;

  update parties set status = 'in_game' where id = p_party_id;
  return v_session.id;
end $$;

create or replace function advance_phase(p_party_id uuid, p_force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_next text;
begin
  if p_force then
    if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  elsif not is_member(p_party_id) then
    raise exception 'NO_MIEMBRO';
  end if;

  select * into v_session from active_session(p_party_id);
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;

  if v_session.game_type = 'prueba' then
    if not p_force and not prueba_can_advance(v_session) then return; end if;
    if v_session.state->>'phase' = 'turnos' then
      perform prueba_step_turn(p_party_id);
      return;
    end if;
    v_next := prueba_next_phase(v_session.state->>'phase');
    if v_next is null then perform end_game(p_party_id); return; end if;
    update game_sessions set state = prueba_enter_phase(v_session, v_next) where id = v_session.id;

  elsif v_session.game_type = 'yo-nunca' then
    if not p_force and not yn_can_advance(v_session) then return; end if;
    v_next := yn_next_phase(v_session);
    if v_next is null then perform end_game(p_party_id); return; end if;
    update game_sessions set state = yn_enter_phase(v_session, v_next) where id = v_session.id;
  end if;
end $$;

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
  v_answer text;
begin
  if v_me is null then raise exception 'NO_MIEMBRO'; end if;
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;
  v_state := v_session.state;
  v_phase := v_state->>'phase';

  -- ----- prueba (igual que 003) -----
  if v_session.game_type = 'prueba' then
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
    select * into v_session from game_sessions where id = v_session.id;
    if prueba_can_advance(v_session) then perform advance_phase(p_party_id, false); end if;
    return;
  end if;

  -- ----- yo-nunca -----
  if v_session.game_type = 'yo-nunca' then
    if p_action = 'answer' and v_phase = 'pregunta' then
      v_answer := p_payload->>'value';
      if v_answer not in ('si', 'no') then raise exception 'RESPUESTA_INVALIDA'; end if;
      v_state := jsonb_set(v_state, array['answers', v_me::text], to_jsonb(v_answer));

    elsif p_action = 'anon_toggle' and v_phase = 'pregunta' then
      if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
      v_state := jsonb_set(v_state, '{anon}', to_jsonb(not coalesce((v_state->>'anon')::boolean, false)));

    else
      raise exception 'ACCION_INVALIDA';
    end if;

    update game_sessions set state = v_state where id = v_session.id;
    select * into v_session from game_sessions where id = v_session.id;
    if yn_can_advance(v_session) then perform advance_phase(p_party_id, false); end if;
    return;
  end if;

  raise exception 'ACCION_INVALIDA';
end $$;

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

    if v_session.game_type = 'prueba' then
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

    elsif v_session.game_type = 'yo-nunca' then
      if v_phase = 'pregunta' and not (v_state->'answers' ? v_bot.id::text) then
        update game_sessions set state = jsonb_set(state, array['answers', v_bot.id::text],
          to_jsonb(case when random() < 0.5 then 'si' else 'no' end))
          where id = v_session.id;
      end if;
    end if;
  end loop;

  -- si con lo de los bots quedaron todos, avanza
  select * into v_session from game_sessions where id = v_session.id;
  if v_session.status = 'active' then
    if (v_session.game_type = 'prueba' and prueba_can_advance(v_session))
       or (v_session.game_type = 'yo-nunca' and yn_can_advance(v_session)) then
      perform advance_phase(p_party_id, false);
    end if;
  end if;
end $$;
