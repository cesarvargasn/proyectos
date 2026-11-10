-- ============================================================================
-- 026_retiro_frases_filtro.sql — feedback de César 2026-09-12 (batch 2)
--
--  1. BATALLA DE FRASES (ocurrencias) y SIN FILTRO salen del juego, mismo
--     trato que El Rey/Mentiras/La Manada en 023: fuera de la lista
--     permitida y de los dispatchers; módulos y migraciones quedan como
--     historia. Revivir uno = re-listar en registry + gameRegistry + rama.
--  2. TRES RONDAS se queda pero se llama CHARADAS (rename solo de display
--     en el cliente; el id interno 'tres-rondas' no cambia — igual que
--     El Más Probable / el-senalado).
--  3. Lobos, Misión Secreta y Dos Cuartos se quedan; sus instrucciones
--     (HowToPlay, batch 022) ya existen en el cliente.
--
-- Dispatchers reescritos completos (patrón 015/019/022/023/025). Quedan
-- 7 JUEGOS LANZABLES: la-ruleta, impostor, tres-rondas (Charadas),
-- parejas-a-gritos, lobos, mision-secreta, dos-cuartos.
--
-- DEUDA CONOCIDA (patrón 023): helpers oc_* y sf_* quedan en la base sin
-- referencias, junto a los de los demás retirados (vr_*, es_*, rey_*,
-- mt_*, mn_*, pa_*, yn_*).
-- ============================================================================

-- ==================== LAUNCH ====================
create or replace function launch_game(p_party_id uuid, p_game_type text, p_opts jsonb default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_deck jsonb;
  v_intensity int;
  v_n int;
  v_timer int;
  v_ids uuid[];
  v_card_ids uuid[];
  v_np int;
  v_pool jsonb;
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  if p_game_type not in ('la-ruleta','impostor','tres-rondas','parejas-a-gritos',
                         'lobos','mision-secreta','dos-cuartos') then
    raise exception 'JUEGO_NO_DISPONIBLE';
  end if;
  if exists (select 1 from game_sessions where party_id = p_party_id and status = 'active') then
    raise exception 'YA_HAY_JUEGO';
  end if;

  select coalesce((settings->>'intensity')::int, 2) into v_intensity from parties where id = p_party_id;
  v_intensity := least(5, greatest(1, coalesce((p_opts->>'intensity')::int, v_intensity)));
  v_n := least(60, greatest(3, coalesce((p_opts->>'n_cards')::int,
           case p_game_type when 'la-ruleta' then 40 when 'impostor' then 3 else 15 end)));
  v_timer := least(180, greatest(10, coalesce((p_opts->>'timer_s')::int, 30)));
  v_ids := acting_player_ids(p_party_id);
  v_np := array_length(v_ids, 1);

  if p_opts ? 'card_ids' then
    v_card_ids := array(select (e#>>'{}')::uuid from jsonb_array_elements(p_opts->'card_ids') e);
    if coalesce(array_length(v_card_ids, 1), 0) = 0 then v_card_ids := null; end if;
  end if;

  insert into game_sessions (party_id, game_type, state)
    values (p_party_id, p_game_type, '{}'::jsonb)
    returning * into v_session;

  if p_game_type = 'la-ruleta' then
    if v_card_ids is not null then
      select coalesce(jsonb_agg(jsonb_build_object('text', text_es, 'intensity', intensity, 'card_type', card_type)
               order by array_position(v_card_ids, id)), '[]') into v_deck
      from content_cards
      where id = any(v_card_ids) and game_type = 'la-ruleta' and enabled;
    else
      select coalesce(jsonb_agg(c), '[]') into v_deck from (
        select jsonb_build_object('text', text_es, 'intensity', intensity, 'card_type', card_type) as c
        from content_cards
        where game_type = 'la-ruleta' and intensity <= v_intensity and enabled
        order by intensity, random() limit v_n
      ) s;
    end if;
    if jsonb_array_length(v_deck) = 0 then
      delete from game_sessions where id = v_session.id;
      raise exception 'SIN_CARTAS';
    end if;
    v_session.state := jsonb_build_object('deck', v_deck, 'round_idx', -1, 'rules', '[]'::jsonb,
      'countdown_s', least(10, greatest(0, coalesce((p_opts->>'countdown_s')::int, 0))));
    update game_sessions set state = rl_enter_carta(v_session) where id = v_session.id;

  elsif p_game_type = 'impostor' then
    if v_card_ids is not null then
      select coalesce(jsonb_agg(jsonb_build_object('id', id, 'cat', text_es)
               order by array_position(v_card_ids, id)), '[]') into v_deck
      from content_cards
      where id = any(v_card_ids) and game_type = 'impostor' and enabled
        and jsonb_array_length(coalesce(meta->'words', '[]'::jsonb)) >= 3;
    else
      select coalesce(jsonb_agg(c.j), '[]') into v_deck from (
        select jsonb_build_object('id', id, 'cat', text_es) as j
        from content_cards
        where game_type = 'impostor' and intensity <= v_intensity and enabled
          and jsonb_array_length(coalesce(meta->'words', '[]'::jsonb)) >= 3
        order by random() limit v_n
      ) c;
    end if;
    if jsonb_array_length(v_deck) = 0 then
      delete from game_sessions where id = v_session.id;
      raise exception 'SIN_CARTAS';
    end if;
    update game_sessions set state = jsonb_build_object(
      'deck', v_deck, 'round_idx', -1, 'timer_s', v_timer,
      'offline', coalesce((p_opts->>'offline')::boolean, false),
      'scores', (select jsonb_object_agg(pid::text, 0) from unnest(v_ids) pid))
      where id = v_session.id;
    select * into v_session from game_sessions where id = v_session.id;
    perform im_start_round(v_session);

  elsif p_game_type = 'tres-rondas' then
    v_n := least(40, greatest(6, coalesce((p_opts->>'n_cards')::int, least(40, 5 * v_np))));
    v_timer := least(180, greatest(15, coalesce((p_opts->>'timer_s')::int, 60)));
    if v_card_ids is not null then
      select coalesce(jsonb_agg(to_jsonb(text_es)), '[]') into v_pool
      from content_cards where id = any(v_card_ids) and game_type = 'tres-rondas' and enabled;
    else
      select coalesce(jsonb_agg(to_jsonb(text_es)), '[]') into v_pool from (
        select text_es from content_cards
        where game_type = 'tres-rondas' and intensity <= v_intensity and enabled
        order by random() limit v_n) s;
    end if;
    if jsonb_array_length(v_pool) < 6 then
      delete from game_sessions where id = v_session.id;
      raise exception 'SIN_CARTAS';
    end if;
    if coalesce((p_opts->>'offline')::boolean, false) then
      -- MODO BASE: la app arma equipos y dispensa palabras; el resto en vivo
      update game_sessions set state = jsonb_build_object(
        'mode_base', true, 'phase', 'base', 'phase_ends_at', null,
        'pool', v_pool,
        'remaining', (select jsonb_agg(e order by random()) from jsonb_array_elements(v_pool) e),
        'teams', (select jsonb_object_agg(pid::text, case when ord % 2 = 0 then 'A' else 'B' end)
                  from (select pid, row_number() over () as ord
                        from unnest(v_ids) pid order by random()) t))
        where id = v_session.id;
    else
      update game_sessions set state = jsonb_build_object(
        'pool', v_pool,
        'remaining', (select jsonb_agg(e order by random()) from jsonb_array_elements(v_pool) e),
        'round', 1, 'timer_s', v_timer,
        'turn_order', (select jsonb_agg(to_jsonb(pid) order by random()) from unnest(v_ids) pid),
        'turn_idx', -1,
        'teams', (select jsonb_object_agg(pid::text, case when ord % 2 = 0 then 'A' else 'B' end)
                  from (select pid, row_number() over () as ord
                        from unnest(v_ids) pid order by random()) t),
        'team_scores', jsonb_build_object('A', 0, 'B', 0),
        'phase', 'entre', 'phase_ends_at', null)
        where id = v_session.id;
    end if;

  elsif p_game_type = 'parejas-a-gritos' then
    v_timer := least(180, greatest(15, coalesce((p_opts->>'timer_s')::int, 45)));
    update game_sessions set state = jsonb_build_object(
      'rounds_total', least(6, greatest(2, coalesce((p_opts->>'n_cards')::int, 3))),
      'round_idx', -1, 'timer_s', v_timer, 'used', '[]'::jsonb,
      'scores', (select jsonb_object_agg(pid::text, 0) from unnest(v_ids) pid))
      where id = v_session.id;
    select * into v_session from game_sessions where id = v_session.id;
    perform pj_start_round(p_party_id, v_session);

  elsif p_game_type = 'lobos' then
    perform lb_launch(p_party_id, v_session.id, p_opts);

  elsif p_game_type = 'mision-secreta' then
    perform ms_launch(p_party_id, v_session.id);

  elsif p_game_type = 'dos-cuartos' then
    perform dc_launch(p_party_id, v_session.id, p_opts);
  end if;

  update parties set status = 'in_game' where id = p_party_id;
  return v_session.id;
end $$;

-- ==================== ADVANCE ====================
create or replace function advance_phase(p_party_id uuid, p_force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
begin
  if p_force then
    if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  elsif not is_member(p_party_id) then
    raise exception 'NO_MIEMBRO';
  end if;

  select * into v_session from active_session(p_party_id);
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;

  if v_session.game_type = 'la-ruleta' then
    if not p_force then return; end if;
    declare v_new jsonb;
    begin
      v_new := rl_enter_carta(v_session);
      if v_new is null then perform end_game(p_party_id); return; end if;
      update game_sessions set state = v_new where id = v_session.id;
    end;

  elsif v_session.game_type = 'impostor' then
    -- modo offline: solo reparto por rondas
    if coalesce((v_session.state->>'offline')::boolean, false) then
      if not p_force then return; end if;
      if (v_session.state->>'round_idx')::int + 1 < jsonb_array_length(v_session.state->'deck') then
        perform im_start_round(v_session);
      else
        perform end_game(p_party_id);
      end if;
      return;
    end if;
    if v_session.state->>'phase' = 'secreto' then
      if not p_force and not im_can_advance(v_session) then return; end if;
      update game_sessions set state = state || jsonb_build_object('phase', 'pistas', 'phase_ends_at', null)
        where id = v_session.id;
    elsif v_session.state->>'phase' = 'pistas' then
      if not p_force then return; end if;
      update game_sessions set state = state || jsonb_build_object('phase', 'voto',
        'phase_ends_at', to_jsonb(now() + make_interval(secs => coalesce((v_session.state->>'timer_s')::int, 30))))
        where id = v_session.id;
    elsif v_session.state->>'phase' = 'voto' then
      if not p_force and not im_can_advance(v_session) then return; end if;
      perform im_after_voto(v_session);
    elsif v_session.state->>'phase' = 'cazeria' then
      if not p_force then return; end if; -- host reabre las pistas
      update game_sessions set state = state || jsonb_build_object('phase', 'pistas', 'phase_ends_at', null)
        where id = v_session.id;
    elsif v_session.state->>'phase' = 'adivinar' then
      if not p_force and not im_can_advance(v_session) then return; end if;
      if v_session.state->>'guess' is not null then
        update game_sessions set state = state || jsonb_build_object(
          'phase', 'confirmar', 'word', im_word(v_session.id), 'phase_ends_at', null)
          where id = v_session.id;
      else
        perform im_enter_reveal(v_session, 'fallo');
      end if;
    elsif v_session.state->>'phase' = 'confirmar' then
      if not p_force then return; end if;
      perform im_enter_reveal(v_session, 'fallo');
    elsif v_session.state->>'phase' = 'reveal' then
      if not p_force then return; end if;
      if (v_session.state->>'round_idx')::int + 1 < jsonb_array_length(v_session.state->'deck') then
        perform im_start_round(v_session);
      else
        update game_sessions set state = state || jsonb_build_object('phase', 'podio', 'phase_ends_at', null)
          where id = v_session.id;
      end if;
    elsif v_session.state->>'phase' = 'podio' then
      if p_force then perform end_game(p_party_id); end if;
    end if;

  elsif v_session.game_type = 'tres-rondas' then
    if coalesce((v_session.state->>'mode_base')::boolean, false) then
      if p_force then perform end_game(p_party_id); end if;
      return;
    end if;
    if v_session.state->>'phase' = 'turno' then
      if not p_force and not tr_can_advance(v_session) then return; end if;
      update game_sessions set state = state || jsonb_build_object('phase', 'entre', 'phase_ends_at', null)
        where id = v_session.id;
    elsif v_session.state->>'phase' = 'entre' then
      perform tr_next_turn(p_party_id, v_session.id);
    elsif v_session.state->>'phase' = 'podio' then
      if p_force then perform end_game(p_party_id); end if;
    end if;

  elsif v_session.game_type = 'parejas-a-gritos' then
    if v_session.state->>'phase' = 'gritos' then
      if not p_force and not pj_can_advance(v_session) then return; end if;
      update game_sessions set state = state || jsonb_build_object('phase', 'elegir',
        'phase_ends_at', to_jsonb(now() + interval '30 seconds')) where id = v_session.id;
    elsif v_session.state->>'phase' = 'elegir' then
      if not p_force and not pj_can_advance(v_session) then return; end if;
      perform pj_reveal(v_session);
    elsif v_session.state->>'phase' = 'reveal' then
      if not p_force then return; end if;
      perform pj_start_round(p_party_id, v_session);
    elsif v_session.state->>'phase' = 'podio' then
      if p_force then perform end_game(p_party_id); end if;
    end if;

  elsif v_session.game_type = 'lobos' then
    perform lb_advance(p_party_id, p_force);

  elsif v_session.game_type = 'mision-secreta' then
    perform ms_advance(p_party_id, p_force);

  elsif v_session.game_type = 'dos-cuartos' then
    perform dc_advance(p_party_id, p_force);
  end if;
end $$;

-- ==================== SUBMIT ====================
create or replace function submit_action(p_party_id uuid, p_action text, p_payload jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  v_phase text;
  v_me uuid := my_player_id(p_party_id);
  v_target uuid;
  v_text text;
  v_team text;
begin
  if v_me is null then raise exception 'NO_MIEMBRO'; end if;
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;
  v_state := v_session.state;
  v_phase := v_state->>'phase';

  if v_session.game_type = 'impostor' then
    if p_action = 'ready' and v_phase = 'secreto' then
      v_state := jsonb_set(v_state, array['ready', v_me::text], 'true');
      update game_sessions set state = v_state where id = v_session.id;
      select * into v_session from game_sessions where id = v_session.id;
      if not coalesce((v_state->>'offline')::boolean, false)
         and im_can_advance(v_session) then
        perform advance_phase(p_party_id, false);
      end if;

    elsif p_action = 'vote' and v_phase = 'voto' then
      v_target := (p_payload->>'target')::uuid;
      if v_target = v_me then raise exception 'NO_AUTOVOTO'; end if;
      if not exists (select 1 from players where id = v_target and party_id = p_party_id and status = 'active') then
        raise exception 'VOTO_INVALIDO';
      end if;
      v_state := jsonb_set(v_state, array['votes', v_me::text], to_jsonb(v_target::text));
      update game_sessions set state = v_state where id = v_session.id;
      select * into v_session from game_sessions where id = v_session.id;
      if im_can_advance(v_session) then perform advance_phase(p_party_id, false); end if;

    elsif p_action = 'guess' and v_phase = 'adivinar' then
      if v_me <> im_impostor(v_session.id) then raise exception 'NO_ERES_EL_IMPOSTOR'; end if;
      if v_state->>'guess' is not null then raise exception 'YA_ADIVINASTE'; end if;
      v_text := left(trim(coalesce(p_payload->>'text','')), 40);
      if v_text = '' then raise exception 'TEXTO_VACIO'; end if;
      update game_sessions set state = v_state || jsonb_build_object('guess', v_text)
        where id = v_session.id;
      select * into v_session from game_sessions where id = v_session.id;
      perform advance_phase(p_party_id, false);

    elsif p_action = 'confirm' and v_phase = 'confirmar' then
      if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
      perform im_enter_reveal(v_session,
        case when coalesce((p_payload->>'ok')::boolean, false) then 'adivino' else 'fallo' end);

    else
      raise exception 'ACCION_INVALIDA';
    end if;
    return;
  end if;

  if v_session.game_type = 'tres-rondas' then
    -- MODO BASE: cualquiera pide la siguiente palabra
    if coalesce((v_state->>'mode_base')::boolean, false) then
      if p_action = 'next_word' and v_phase = 'base' then
        if jsonb_array_length(coalesce(v_state->'remaining', '[]'::jsonb)) > 0 then
          update game_sessions set state = jsonb_set(v_state, '{remaining}', (v_state->'remaining') - 0)
            where id = v_session.id;
        end if;
        return;
      end if;
      raise exception 'ACCION_INVALIDA';
    end if;
    if v_phase <> 'turno' or v_me <> tr_actor(v_state) then
      raise exception 'NO_ES_TU_TURNO';
    end if;
    if coalesce((v_state->>'phase_ends_at')::timestamptz < now(), false) then
      update game_sessions set state = state || jsonb_build_object('phase', 'entre', 'phase_ends_at', null)
        where id = v_session.id;
      return;
    end if;
    if p_action = 'got' then
      v_team := v_state->'teams'->>(v_me::text);
      v_state := jsonb_set(v_state, array['team_scores', v_team],
        to_jsonb(coalesce((v_state->'team_scores'->>v_team)::int, 0) + 1));
      v_state := jsonb_set(v_state, '{remaining}', (v_state->'remaining') - 0);
      update game_sessions set state = v_state where id = v_session.id;
      if jsonb_array_length(v_state->'remaining') = 0 then
        perform tr_next_pool(v_session.id);
      end if;
    elsif p_action = 'pass' then
      if jsonb_array_length(v_state->'remaining') > 1 then
        v_state := jsonb_set(v_state, '{remaining}',
          ((v_state->'remaining') - 0) || jsonb_build_array(v_state->'remaining'->0));
        update game_sessions set state = v_state where id = v_session.id;
      end if;
    elsif p_action = 'end_turn' then
      update game_sessions set state = state || jsonb_build_object('phase', 'entre', 'phase_ends_at', null)
        where id = v_session.id;
    else
      raise exception 'ACCION_INVALIDA';
    end if;
    return;
  end if;

  if v_session.game_type = 'parejas-a-gritos' then
    if p_action = 'pick' and v_phase = 'elegir' then
      v_target := (p_payload->>'target')::uuid;
      if v_target = v_me then raise exception 'NO_AUTOPICK'; end if;
      if not exists (select 1 from players where id = v_target and party_id = p_party_id and status = 'active') then
        raise exception 'PICK_INVALIDO';
      end if;
      v_state := jsonb_set(v_state, array['picks', v_me::text], to_jsonb(v_target::text));
      update game_sessions set state = v_state where id = v_session.id;
      select * into v_session from game_sessions where id = v_session.id;
      if pj_can_advance(v_session) then perform advance_phase(p_party_id, false); end if;
    else
      raise exception 'ACCION_INVALIDA';
    end if;
    return;
  end if;

  if v_session.game_type = 'lobos' then
    perform lb_submit(p_party_id, v_me, p_action, p_payload);
    return;
  end if;

  if v_session.game_type = 'mision-secreta' then
    perform ms_submit(p_party_id, v_me, p_action, p_payload);
    return;
  end if;

  if v_session.game_type = 'dos-cuartos' then
    perform dc_submit(p_party_id, v_me, p_action, p_payload);
    return;
  end if;

  raise exception 'ACCION_INVALIDA';
end $$;

-- ==================== BOT TICK ====================
create or replace function dev_bot_tick(p_party_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  v_phase text;
  v_bot record;
  v_targets uuid[];
  v_frases text[] := array['un mariachi en huelga','la abuela con jetlag','un tamal radiactivo',
    'el ex de todo el mundo','un bus sin frenos','la resaca eterna','un gato con deudas',
    'el DJ del pueblo','una arepa gigante','el vecino chismoso'];
  v_team text;
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then return; end if;
  v_phase := v_session.state->>'phase';

  -- ruleta: el host maneja el ritmo, los bots no tienen nada que hacer
  if v_session.game_type = 'la-ruleta' then
    return;
  end if;

  if v_session.game_type = 'impostor' then
    v_state := v_session.state;
    if coalesce((v_state->>'offline')::boolean, false) then return; end if;
    if v_phase = 'adivinar' and v_state->>'guess' is null then
      if exists (select 1 from players where id = im_impostor(v_session.id) and is_bot and status = 'active') then
        update game_sessions set state = state || jsonb_build_object('guess',
          v_frases[1 + floor(random()*array_length(v_frases,1))::int])
          where id = v_session.id;
        select * into v_session from game_sessions where id = v_session.id;
        perform advance_phase(p_party_id, false);
      end if;
      return;
    end if;
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
      end if;
    end loop;
    select * into v_session from game_sessions where id = v_session.id;
    if v_session.status = 'active' and im_can_advance(v_session) then
      perform advance_phase(p_party_id, false);
    end if;
    return;
  end if;

  if v_session.game_type = 'tres-rondas' then
    v_state := v_session.state;
    if coalesce((v_state->>'mode_base')::boolean, false) then return; end if;
    if v_state->>'phase' = 'turno'
       and exists (select 1 from players where id = tr_actor(v_state) and is_bot and status = 'active') then
      if coalesce((v_state->>'phase_ends_at')::timestamptz < now(), false) then
        update game_sessions set state = state || jsonb_build_object('phase', 'entre', 'phase_ends_at', null)
          where id = v_session.id;
      else
        v_team := v_state->'teams'->>(tr_actor(v_state)::text);
        v_state := jsonb_set(v_state, array['team_scores', v_team],
          to_jsonb(coalesce((v_state->'team_scores'->>v_team)::int, 0) + 1));
        v_state := jsonb_set(v_state, '{remaining}', (v_state->'remaining') - 0);
        update game_sessions set state = v_state where id = v_session.id;
        if jsonb_array_length(v_state->'remaining') = 0 then
          perform tr_next_pool(v_session.id);
        end if;
      end if;
    elsif v_state->>'phase' = 'entre' then
      if exists (select 1 from players p
                 where p.id = (v_state->'turn_order'->>(next_active_turn(v_state->'turn_order', (v_state->>'turn_idx')::int)))::uuid
                   and p.is_bot and p.status = 'active') then
        perform tr_next_turn(p_party_id, v_session.id);
      end if;
    end if;
    return;
  end if;

  if v_session.game_type = 'parejas-a-gritos' then
    v_state := v_session.state;
    if v_state->>'phase' = 'elegir' then
      for v_bot in select id from players where party_id = p_party_id and is_bot and status = 'active' loop
        v_state := (select state from game_sessions where id = v_session.id);
        if not (v_state->'picks' ? v_bot.id::text) then
          v_targets := array(select id from players
            where party_id = p_party_id and status = 'active' and id <> v_bot.id);
          update game_sessions set state = jsonb_set(state, array['picks', v_bot.id::text],
            to_jsonb(v_targets[1 + floor(random()*array_length(v_targets,1))::int]::text))
            where id = v_session.id;
        end if;
      end loop;
    end if;
    select * into v_session from game_sessions where id = v_session.id;
    if v_session.status = 'active' and pj_can_advance(v_session) then
      perform advance_phase(p_party_id, false);
    end if;
    return;
  end if;

  if v_session.game_type = 'lobos' then
    if coalesce((v_session.state->>'offline')::boolean, false) then return; end if;
    perform lb_bot_tick(p_party_id); return;
  end if;
  if v_session.game_type = 'mision-secreta' then perform ms_bot_tick(p_party_id); return; end if;
  if v_session.game_type = 'dos-cuartos' then
    if coalesce((v_session.state->>'offline')::boolean, false) then return; end if;
    perform dc_bot_tick(p_party_id); return;
  end if;
end $$;
