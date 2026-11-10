-- ============================================================
-- LA NOCHE — Migración 005: Yo Nunca v2 = solo banco de cartas
-- Correr DESPUÉS de 004.
--
-- Decisión de César 2026-07-09: en persona el sí/no se hace en
-- vivo (la gracia es la sala, no el celular). La app solo muestra
-- la carta en todas las pantallas; el host pasa a la siguiente.
-- Fuera: answers, anon_toggle, timer, reveal.
--
-- state = { phase:'pregunta', phase_ends_at:null,
--           deck:[{text,intensity}], round_idx }
-- launch_game de 004 queda igual (mismo nombre de fase inicial).
-- ============================================================

-- carta sin timer; round_idx avanza al entrar
create or replace function yn_enter_phase(p_session game_sessions, p_phase text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
begin
  if p_phase = 'pregunta' then
    v_state := v_state || jsonb_build_object(
      'phase', 'pregunta',
      'round_idx', coalesce((v_state->>'round_idx')::int, -1) + 1,
      'phase_ends_at', null);
  end if;
  return v_state;
end $$;

-- siguiente carta mientras queden; sin cartas = fin del juego
create or replace function yn_next_phase(p_session game_sessions)
returns text language sql stable as $$
  select case
    when (p_session.state->>'round_idx')::int + 1 < jsonb_array_length(p_session.state->'deck')
    then 'pregunta' else null end;
$$;

-- nunca avanza solo: la carta la pasa el host (force)
create or replace function yn_can_advance(p_session game_sessions)
returns boolean language sql stable as $$
  select false;
$$;

-- submit_action: yo-nunca ya no tiene acciones de jugador
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

  -- ----- prueba (igual que 003/004) -----
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

  -- yo-nunca: sin acciones (solo banco de cartas)
  raise exception 'ACCION_INVALIDA';
end $$;

-- dev_bot_tick: bots sin nada que hacer en yo-nunca
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
  if v_session.id is null or v_session.game_type <> 'prueba' then return; end if;
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

  select * into v_session from game_sessions where id = v_session.id;
  if v_session.status = 'active' and prueba_can_advance(v_session) then
    perform advance_phase(p_party_id, false);
  end if;
end $$;
