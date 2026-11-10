-- ============================================================================
-- 025_bancos_solo_bd.sql — feedback de César 2026-09-12
--
-- Los bancos dejan de ser JUEGOS. En la fiesta ni siquiera "pasar carta"
-- en el celular aporta: César quiere Yo Nunca, Verdad o Reto y El Más
-- Probable como pura BASE DE DATOS que él (admin) consulta en /cartas.
-- Cero interacción, cero launch. Además:
--
--  1. PARANOIA se fusiona con EL MÁS PROBABLE. Desde 023 eran mecánicamente
--     idénticos; como bases de datos la distinción no aporta. Sus cartas
--     pasan a game_type 'el-senalado' (el csv también se fusionó).
--  2. PRUEBA (juego de test del motor, fase 2) se borra del todo: lista
--     permitida, dispatchers, helpers y módulo cliente. Cumplió su ciclo.
--  3. LA RULETA queda como el único juego de la familia "prompts": sí es
--     interactivo (countdown, slots {p1}, reglas persistentes). El modo
--     social/puntos muere app-wide: solo versión trago (cambio de cliente —
--     el server nunca resolvió {drink:N}).
--
-- Dispatchers reescritos completos (patrón 015/019/022/023). Quedan
-- 9 JUEGOS LANZABLES: la-ruleta, ocurrencias, sin-filtro, impostor,
-- tres-rondas, parejas-a-gritos, lobos, mision-secreta, dos-cuartos.
--
-- Al final se DROPean los helpers bn_* (023) y prueba_* (003): supersede
-- también a 024_fix_bn_grants.sql (correr 024 antes no hace daño; no
-- correrlo tampoco — aquí las funciones desaparecen).
--
-- DEUDA CONOCIDA (igual que 023): helpers de juegos retirados (vr_*, es_*,
-- rey_*, mt_*, mn_*, pa_*, yn_*) siguen en la base sin referencias.
-- ============================================================================

-- ==================== FUSIÓN PARANOIA → EL MÁS PROBABLE ====================
update content_cards set game_type = 'el-senalado' where game_type = 'paranoia';

-- La fusión puede duplicar textos (p.ej. "¿Quién es más probable que llegue
-- tarde a su propia boda?" existía en ambos mazos) — se queda una sola.
delete from content_cards a using content_cards b
  where a.game_type = 'el-senalado' and b.game_type = 'el-senalado'
    and a.text_es = b.text_es and a.id > b.id;

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
  v_blancas jsonb;
  v_pool jsonb;
  v_pid uuid;
  i int;
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  if p_game_type not in ('la-ruleta','ocurrencias','sin-filtro','impostor',
                         'tres-rondas','parejas-a-gritos',
                         'lobos','mision-secreta','dos-cuartos') then
    raise exception 'JUEGO_NO_DISPONIBLE';
  end if;
  if exists (select 1 from game_sessions where party_id = p_party_id and status = 'active') then
    raise exception 'YA_HAY_JUEGO';
  end if;

  select coalesce((settings->>'intensity')::int, 2) into v_intensity from parties where id = p_party_id;
  v_intensity := least(5, greatest(1, coalesce((p_opts->>'intensity')::int, v_intensity)));
  v_n := least(60, greatest(3, coalesce((p_opts->>'n_cards')::int,
           case p_game_type when 'la-ruleta' then 40
                            when 'sin-filtro' then 8 when 'impostor' then 3 else 15 end)));
  v_timer := least(180, greatest(10, coalesce((p_opts->>'timer_s')::int,
               case p_game_type when 'ocurrencias' then 90
                                when 'sin-filtro' then 45 when 'impostor' then 30 else 30 end)));
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

  elsif p_game_type = 'ocurrencias' then
    if v_card_ids is not null then
      select coalesce(jsonb_agg(jsonb_build_object('text', text_es)
               order by array_position(v_card_ids, id)), '[]') into v_deck
      from content_cards
      where id = any(v_card_ids) and game_type = 'ocurrencias' and enabled;
      v_deck := (select coalesce(jsonb_agg(e), '[]') from (
        select e from jsonb_array_elements(v_deck) with ordinality t(e, ord)
        where ord <= v_np) s);
    else
      select coalesce(jsonb_agg(jsonb_build_object('text', c.text_es)), '[]') into v_deck from (
        select text_es from content_cards
        where game_type = 'ocurrencias' and intensity <= v_intensity and enabled
        order by random() limit v_np
      ) c;
    end if;
    if jsonb_array_length(v_deck) < v_np then
      delete from game_sessions where id = v_session.id;
      raise exception 'SIN_CARTAS';
    end if;
    v_session.state := jsonb_build_object(
      'timer_s', v_timer,
      'players', to_jsonb(v_ids),
      'prompts', v_deck,
      'answers', (select jsonb_object_agg(g::text, '{}'::jsonb) from generate_series(0, v_np - 1) g),
      'duel_idx', -1, 'votes', '{}'::jsonb,
      'scores', (select jsonb_object_agg(pid::text, 0) from unnest(v_ids) pid));
    update game_sessions set state = oc_enter_phase(v_session, 'escribir') where id = v_session.id;

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

  elsif p_game_type = 'sin-filtro' then
    -- v_n = CARTAS EN MANO (mano finita, sin refill); negras dura lo mismo
    v_n := least(12, greatest(4, v_n));
    if v_card_ids is not null then
      select coalesce(jsonb_agg(jsonb_build_object('text', text_es)
               order by array_position(v_card_ids, id)), '[]') into v_deck
      from content_cards
      where id = any(v_card_ids) and game_type = 'sin-filtro' and card_type = 'negra' and enabled;
      select coalesce(jsonb_agg(to_jsonb(text_es) order by random()), '[]') into v_blancas
      from content_cards
      where id = any(v_card_ids) and game_type = 'sin-filtro' and card_type = 'blanca' and enabled;
    end if;
    if v_deck is null or jsonb_array_length(coalesce(v_deck, '[]')) = 0 then
      select coalesce(jsonb_agg(c.j), '[]') into v_deck from (
        select jsonb_build_object('text', text_es) as j
        from content_cards
        where game_type = 'sin-filtro' and card_type = 'negra' and intensity <= v_intensity and enabled
        order by random() limit v_n
      ) c;
    end if;
    if v_blancas is null or jsonb_array_length(coalesce(v_blancas, '[]')) < v_n * v_np then
      select coalesce(jsonb_agg(to_jsonb(text_es) order by random()), '[]') into v_blancas
      from content_cards
      where game_type = 'sin-filtro' and card_type = 'blanca' and intensity <= v_intensity and enabled;
    end if;
    if jsonb_array_length(v_deck) = 0 or jsonb_array_length(v_blancas) < v_n * v_np then
      delete from game_sessions where id = v_session.id;
      raise exception 'SIN_CARTAS';
    end if;

    delete from player_secrets where game_session_id = v_session.id;
    i := 0;
    foreach v_pid in array v_ids loop
      insert into player_secrets (game_session_id, player_id, payload)
      values (v_session.id, v_pid, jsonb_build_object('hand',
        (select coalesce(jsonb_agg(e), '[]') from (
          select e from jsonb_array_elements(v_blancas) with ordinality t(e, ord)
          where ord > i * v_n and ord <= (i + 1) * v_n) s)));
      i := i + 1;
    end loop;

    v_session.state := jsonb_build_object(
      'negras', v_deck, 'negra_idx', 0, 'blancas', '[]'::jsonb, 'timer_s', v_timer,
      'hand_n', v_n,
      'judge_mode', case when p_opts->>'judge_mode' = 'votos' then 'votos' else 'juez' end,
      'suspenso', coalesce((p_opts->>'suspenso')::boolean, false),
      'shown', true, 'votes', '{}'::jsonb,
      'turn_order', to_jsonb(v_ids), 'juez_idx', next_active_turn(to_jsonb(v_ids), -1),
      'plays', '[]'::jsonb, 'winner_idx', null,
      'phase', 'jugar', 'phase_ends_at', to_jsonb(now() + make_interval(secs => v_timer)),
      'scores', (select jsonb_object_agg(pid::text, 0) from unnest(v_ids) pid));
    update game_sessions set state = v_session.state where id = v_session.id;

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
  v_next text;
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

  elsif v_session.game_type = 'ocurrencias' then
    if not p_force and not oc_can_advance(v_session) then return; end if;
    v_next := oc_next_phase(v_session);
    if v_next is null then perform end_game(p_party_id); return; end if;
    update game_sessions set state = oc_enter_phase(v_session, v_next) where id = v_session.id;

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

  elsif v_session.game_type = 'sin-filtro' then
    if v_session.state->>'phase' = 'jugar' then
      if not p_force and not sf_can_advance(v_session) then return; end if;
      perform sf_enter_juzgar(p_party_id, v_session);
    elsif v_session.state->>'phase' = 'juzgar' then
      if not p_force then return; end if;
      if sf_mode(v_session.state) = 'votos' then
        perform sf_after_votes(p_party_id, v_session);
      else
        perform sf_crown(p_party_id, v_session,
          floor(random() * jsonb_array_length(v_session.state->'plays'))::int);
      end if;
    elsif v_session.state->>'phase' = 'resultado' then
      if not p_force then return; end if;
      perform sf_next_round(p_party_id, v_session);
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
  v_idx int;
  v_auth uuid[];
  v_team text;
  v_needed int;
begin
  if v_me is null then raise exception 'NO_MIEMBRO'; end if;
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;
  v_state := v_session.state;
  v_phase := v_state->>'phase';

  if v_session.game_type = 'ocurrencias' then
    if p_action = 'answer' and v_phase = 'escribir' then
      v_idx := (p_payload->>'prompt_idx')::int;
      if v_state->'prompts'->v_idx is null then raise exception 'PROMPT_INVALIDO'; end if;
      v_auth := oc_authors(v_state, v_idx);
      if v_me <> all (v_auth) then raise exception 'NO_ES_TU_PROMPT'; end if;
      v_text := left(trim(coalesce(p_payload->>'text','')), 120);
      if v_text = '' then raise exception 'TEXTO_VACIO'; end if;
      v_state := jsonb_set(v_state, array['answers', v_idx::text, v_me::text], to_jsonb(v_text));

    elsif p_action = 'vote' and v_phase = 'duelo' then
      v_auth := oc_authors(v_state, (v_state->>'duel_idx')::int);
      if v_me = any (v_auth) then raise exception 'AUTOR_NO_VOTA'; end if;
      v_target := (p_payload->>'author')::uuid;
      if v_target <> all (v_auth) then raise exception 'VOTO_INVALIDO'; end if;
      v_state := jsonb_set(v_state, array['votes', v_me::text], to_jsonb(v_target::text));

    else
      raise exception 'ACCION_INVALIDA';
    end if;
    update game_sessions set state = v_state where id = v_session.id;
    select * into v_session from game_sessions where id = v_session.id;
    if oc_can_advance(v_session) then perform advance_phase(p_party_id, false); end if;
    return;
  end if;

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

  if v_session.game_type = 'sin-filtro' then
    if p_action = 'play' and v_phase = 'jugar' then
      if sf_mode(v_state) = 'juez' and v_me = sf_juez(v_state) then raise exception 'ERES_EL_JUEZ'; end if;
      if exists (select 1 from jsonb_array_elements(v_state->'plays') e where (e->>'pid')::uuid = v_me) then
        raise exception 'YA_JUGASTE';
      end if;
      perform sf_play_card(v_session.id, v_me, (p_payload->>'idx')::int);
      select * into v_session from game_sessions where id = v_session.id;
      if sf_can_advance(v_session) then perform advance_phase(p_party_id, false); end if;

    elsif p_action = 'show' and v_phase = 'juzgar' then
      if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
      update game_sessions set state = state || jsonb_build_object('shown', true)
        where id = v_session.id;

    elsif p_action = 'crown' and v_phase = 'juzgar' then
      if sf_mode(v_state) <> 'juez' then raise exception 'MODO_VOTOS'; end if;
      if v_me <> sf_juez(v_state) then raise exception 'SOLO_EL_JUEZ'; end if;
      if not coalesce((v_state->>'shown')::boolean, true) then raise exception 'AUN_NO_SE_MUESTRAN'; end if;
      perform sf_crown(p_party_id, v_session, (p_payload->>'idx')::int);

    elsif p_action = 'vote' and v_phase = 'juzgar' then
      if sf_mode(v_state) <> 'votos' then raise exception 'MODO_JUEZ'; end if;
      if not coalesce((v_state->>'shown')::boolean, true) then raise exception 'AUN_NO_SE_MUESTRAN'; end if;
      v_idx := (p_payload->>'idx')::int;
      if v_state->'plays'->v_idx is null then raise exception 'JUGADA_INVALIDA'; end if;
      if (v_state->'plays'->v_idx->>'pid')::uuid = v_me then raise exception 'TU_JUGADA'; end if;
      v_state := jsonb_set(v_state, array['votes', v_me::text], to_jsonb(v_idx::text));
      update game_sessions set state = v_state where id = v_session.id;
      -- todos los activos votaron → se cierra solo
      select count(*) into v_needed from players
        where party_id = p_party_id and status = 'active';
      if (select count(*) from jsonb_each_text(v_state->'votes')) >= v_needed then
        select * into v_session from game_sessions where id = v_session.id;
        perform sf_after_votes(p_party_id, v_session);
      end if;

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
  v_auth uuid[];
  v_idx int;
  v_team text;
  v_needed int;
  i int;
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then return; end if;
  v_phase := v_session.state->>'phase';

  -- ruleta: el host maneja el ritmo, los bots no tienen nada que hacer
  if v_session.game_type = 'la-ruleta' then
    return;
  end if;

  if v_session.game_type = 'sin-filtro' then
    v_state := v_session.state;
    if v_phase = 'juzgar' then
      if sf_mode(v_state) = 'votos' then
        if not coalesce((v_state->>'shown')::boolean, true) then return; end if;
        for v_bot in select id from players where party_id = p_party_id and is_bot and status = 'active' loop
          v_state := (select state from game_sessions where id = v_session.id);
          if not (v_state->'votes' ? v_bot.id::text) then
            v_idx := (select (t.ord - 1)::int from
              jsonb_array_elements(v_state->'plays') with ordinality t(e, ord)
              where (t.e->>'pid')::uuid <> v_bot.id
              order by random() limit 1);
            if v_idx is not null then
              update game_sessions set state = jsonb_set(state, array['votes', v_bot.id::text],
                to_jsonb(v_idx::text)) where id = v_session.id;
            end if;
          end if;
        end loop;
        select * into v_session from game_sessions where id = v_session.id;
        select count(*) into v_needed from players where party_id = p_party_id and status = 'active';
        if (select count(*) from jsonb_each_text(v_session.state->'votes')) >= v_needed then
          perform sf_after_votes(p_party_id, v_session);
        end if;
      elsif exists (select 1 from players where id = sf_juez(v_state) and is_bot and status = 'active')
         and jsonb_array_length(v_state->'plays') > 0
         and coalesce((v_state->>'shown')::boolean, true) then
        perform sf_crown(p_party_id, v_session,
          floor(random() * jsonb_array_length(v_state->'plays'))::int);
      end if;
      return;
    elsif v_phase = 'jugar' then
      for v_bot in select id from players where party_id = p_party_id and is_bot and status = 'active' loop
        v_state := (select state from game_sessions where id = v_session.id);
        if (sf_mode(v_state) = 'votos' or v_bot.id <> sf_juez(v_state))
           and not exists (select 1 from jsonb_array_elements(v_state->'plays') e
                           where (e->>'pid')::uuid = v_bot.id) then
          perform sf_play_card(v_session.id, v_bot.id, null);
        end if;
      end loop;
      select * into v_session from game_sessions where id = v_session.id;
      if sf_can_advance(v_session) then perform advance_phase(p_party_id, false); end if;
      return;
    end if;
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

  -- ocurrencias: único juego que queda con la vuelta genérica de bots
  if v_session.game_type = 'ocurrencias' then
    for v_bot in select id from players where party_id = p_party_id and is_bot and status = 'active' loop
      v_state := (select state from game_sessions where id = v_session.id);
      if v_phase = 'escribir' then
        for i in 0..(jsonb_array_length(v_state->'players') - 1) loop
          v_auth := oc_authors(v_state, i);
          if v_bot.id = any (v_auth)
             and not (coalesce(v_state->'answers'->(i::text), '{}'::jsonb) ? v_bot.id::text) then
            update game_sessions set state = jsonb_set(state, array['answers', i::text, v_bot.id::text],
              to_jsonb(v_frases[1 + floor(random()*array_length(v_frases,1))::int]))
              where id = v_session.id;
            v_state := (select state from game_sessions where id = v_session.id);
          end if;
        end loop;
      elsif v_phase = 'duelo' and not (v_state->'votes' ? v_bot.id::text) then
        v_auth := oc_authors(v_state, (v_state->>'duel_idx')::int);
        if v_bot.id <> all (v_auth) then
          update game_sessions set state = jsonb_set(state, array['votes', v_bot.id::text],
            to_jsonb(v_auth[1 + floor(random()*2)::int]::text))
            where id = v_session.id;
        end if;
      end if;
    end loop;

    select * into v_session from game_sessions where id = v_session.id;
    if v_session.status = 'active' and oc_can_advance(v_session) then
      perform advance_phase(p_party_id, false);
    end if;
  end if;
end $$;

-- ==================== LIMPIEZA ====================
-- Los helpers de banco (023) y de Prueba (003) ya no tienen quién los llame.
-- Esto supersede 024_fix_bn_grants.sql: sin función no hay permiso que filtrar.
drop function if exists bn_is_banco(text);
drop function if exists bn_deck(text, int, int, uuid[]);
drop function if exists bn_advance(uuid, game_sessions);
drop function if exists prueba_enter_phase(game_sessions, text);
drop function if exists prueba_next_phase(text);
drop function if exists prueba_can_advance(game_sessions);
drop function if exists prueba_step_turn(uuid);
