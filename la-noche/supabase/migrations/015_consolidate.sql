-- ============================================================
-- LA NOCHE — Migración 015: CONSOLIDACIÓN DE DISPATCHERS
-- Correr DESPUÉS de 014. No agrega juegos: reescribe launch_game /
-- advance_phase / submit_action / dev_bot_tick COMPLETAS con las 13
-- ramas (los 11 de 012 + paranoia de 013 + tres-rondas y parejas de
-- 014) y DROPea la cadena de renames *_012 / *_013.
--
-- Antes: launch_game (wrapper 014) → launch_game_013 (wrapper 013)
--        → launch_game_012 (todo lo demás). 3 saltos por llamada.
-- Después: una sola función por dispatcher, cero delegación.
--
-- Los helpers por juego (yn_*, es_*, vr_*, rl_*, rey_*, oc_*, mt_*,
-- mn_*, sf_*, im_*, pa_*, tr_*, pj_*) NO se tocan: siguen vigentes.
-- ============================================================

-- ==================== LAUNCH ====================
create or replace function launch_game(p_party_id uuid, p_game_type text, p_opts jsonb default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_intensity int;
  v_n int;
  v_timer int;
  v_deck jsonb;
  v_ids uuid[];
  v_state jsonb;
  v_card_ids uuid[];
  v_np int;
  v_blancas jsonb;
  v_pool jsonb;
  v_pid uuid;
  i int;
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  if p_game_type not in ('prueba','yo-nunca','el-senalado','verdad-o-reto','la-ruleta','el-rey',
                         'ocurrencias','mentiras','la-manada','sin-filtro','impostor',
                         'paranoia','tres-rondas','parejas-a-gritos') then
    raise exception 'JUEGO_NO_DISPONIBLE';
  end if;
  if exists (select 1 from game_sessions where party_id = p_party_id and status = 'active') then
    raise exception 'YA_HAY_JUEGO';
  end if;

  select coalesce((settings->>'intensity')::int, 2) into v_intensity from parties where id = p_party_id;
  v_intensity := least(5, greatest(1, coalesce((p_opts->>'intensity')::int, v_intensity)));
  v_n := least(60, greatest(3, coalesce((p_opts->>'n_cards')::int,
           case p_game_type when 'la-ruleta' then 40 when 'verdad-o-reto' then 30
                            when 'mentiras' then 6 when 'la-manada' then 8
                            when 'sin-filtro' then 8 when 'impostor' then 3
                            when 'paranoia' then 10 else 15 end)));
  v_timer := least(180, greatest(10, coalesce((p_opts->>'timer_s')::int,
               case p_game_type when 'verdad-o-reto' then 20 when 'ocurrencias' then 90
                                when 'mentiras' then 60 when 'la-manada' then 45
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

  if p_game_type = 'prueba' then
    update game_sessions set state = prueba_enter_phase(v_session, 'secreto') where id = v_session.id;

  elsif p_game_type in ('yo-nunca', 'el-senalado') then
    if v_card_ids is not null then
      select coalesce(jsonb_agg(jsonb_build_object('text', text_es, 'intensity', intensity)
               order by array_position(v_card_ids, id)), '[]') into v_deck
      from content_cards
      where id = any(v_card_ids) and game_type = p_game_type and enabled;
    else
      v_deck := deck_from_content(p_game_type, v_intensity, v_n);
    end if;
    if jsonb_array_length(v_deck) = 0 then
      delete from game_sessions where id = v_session.id;
      raise exception 'SIN_CARTAS';
    end if;
    v_session.state := jsonb_build_object('deck', v_deck, 'round_idx', -1, 'timer_s', v_timer);
    if p_game_type = 'yo-nunca' then
      update game_sessions set state = yn_enter_phase(v_session, 'pregunta') where id = v_session.id;
    else
      update game_sessions set state = es_enter_phase(v_session, 'voto') where id = v_session.id;
    end if;

  elsif p_game_type = 'verdad-o-reto' then
    if v_card_ids is not null then
      v_state := jsonb_build_object(
        'bank_verdad', (select coalesce(jsonb_agg(jsonb_build_object('text', text_es, 'intensity', intensity)
                          order by array_position(v_card_ids, id)), '[]')
                        from content_cards
                        where id = any(v_card_ids) and game_type = p_game_type and card_type = 'verdad' and enabled),
        'bank_reto',   (select coalesce(jsonb_agg(jsonb_build_object('text', text_es, 'intensity', intensity)
                          order by array_position(v_card_ids, id)), '[]')
                        from content_cards
                        where id = any(v_card_ids) and game_type = p_game_type and card_type = 'reto' and enabled));
    else
      v_state := jsonb_build_object(
        'bank_verdad', deck_from_content_typed(p_game_type, 'verdad', v_intensity, v_n),
        'bank_reto',   deck_from_content_typed(p_game_type, 'reto',   v_intensity, v_n));
    end if;
    v_state := v_state || jsonb_build_object(
      'iv', 0, 'ir', 0, 'timer_s', v_timer,
      'turn_order', to_jsonb(v_ids), 'turn_idx', -1,
      'turn_no', 0, 'total_turns', 2 * v_np);
    if jsonb_array_length(v_state->'bank_verdad') = 0 and jsonb_array_length(v_state->'bank_reto') = 0 then
      delete from game_sessions where id = v_session.id;
      raise exception 'SIN_CARTAS';
    end if;
    v_session.state := v_state;
    update game_sessions set state = vr_enter_elegir(v_session) where id = v_session.id;

  elsif p_game_type = 'la-ruleta' then
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
    v_session.state := jsonb_build_object('deck', v_deck, 'round_idx', -1, 'rules', '[]'::jsonb);
    update game_sessions set state = rl_enter_carta(v_session) where id = v_session.id;

  elsif p_game_type = 'el-rey' then
    select jsonb_agg(jsonb_build_object('r', r, 's', s) order by random()) into v_deck
    from unnest(array['A','2','3','4','5','6','7','8','9','10','J','Q','K']) r
    cross join unnest(array['♠','♥','♦','♣']) s;
    v_session.state := jsonb_build_object(
      'deck', v_deck, 'idx', 0, 'kings', 0, 'last_card', null,
      'turn_order', to_jsonb(v_ids),
      'turn_idx', next_active_turn(to_jsonb(v_ids), -1),
      'phase', 'carta', 'phase_ends_at', to_jsonb(now() + interval '30 seconds'));
    update game_sessions set state = v_session.state where id = v_session.id;

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

  elsif p_game_type = 'mentiras' then
    if v_card_ids is not null then
      select coalesce(jsonb_agg(jsonb_build_object('text', text_es, 'answer', meta->>'answer')
               order by array_position(v_card_ids, id)), '[]') into v_deck
      from content_cards
      where id = any(v_card_ids) and game_type = 'mentiras' and enabled
        and coalesce(meta->>'answer', '') <> '';
    else
      select coalesce(jsonb_agg(c.j), '[]') into v_deck from (
        select jsonb_build_object('text', text_es, 'answer', meta->>'answer') as j
        from content_cards
        where game_type = 'mentiras' and intensity <= v_intensity and enabled
          and coalesce(meta->>'answer', '') <> ''
        order by random() limit v_n
      ) c;
    end if;
    if jsonb_array_length(v_deck) = 0 then
      delete from game_sessions where id = v_session.id;
      raise exception 'SIN_CARTAS';
    end if;
    v_session.state := jsonb_build_object(
      'deck', v_deck, 'round_idx', -1, 'timer_s', v_timer,
      'scores', (select jsonb_object_agg(pid::text, 0) from unnest(v_ids) pid));
    update game_sessions set state = mt_enter_phase(v_session, 'mentir') where id = v_session.id;

  elsif p_game_type = 'la-manada' then
    if v_card_ids is not null then
      select coalesce(jsonb_agg(jsonb_build_object('text', text_es)
               order by array_position(v_card_ids, id)), '[]') into v_deck
      from content_cards
      where id = any(v_card_ids) and game_type = 'la-manada' and enabled;
    else
      select coalesce(jsonb_agg(jsonb_build_object('text', c.text_es)), '[]') into v_deck from (
        select text_es from content_cards
        where game_type = 'la-manada' and intensity <= v_intensity and enabled
        order by random() limit v_n
      ) c;
    end if;
    if jsonb_array_length(v_deck) = 0 then
      delete from game_sessions where id = v_session.id;
      raise exception 'SIN_CARTAS';
    end if;
    v_session.state := jsonb_build_object(
      'deck', v_deck, 'round_idx', -1, 'timer_s', v_timer, 'oveja', null,
      'scores', (select jsonb_object_agg(pid::text, 0) from unnest(v_ids) pid));
    update game_sessions set state = mn_enter_phase(v_session, 'responder') where id = v_session.id;

  elsif p_game_type = 'impostor' then
    -- deck = categorías (id + nombre); las palabras se leen del content al
    -- arrancar cada ronda (nunca entran al state → leak-proof)
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
      raise exception 'SIN_CARTAS'; -- solo valen categorías con meta.words (≥3)
    end if;
    update game_sessions set state = jsonb_build_object(
      'deck', v_deck, 'round_idx', -1, 'timer_s', v_timer,
      'scores', (select jsonb_object_agg(pid::text, 0) from unnest(v_ids) pid))
      where id = v_session.id;
    select * into v_session from game_sessions where id = v_session.id;
    perform im_start_round(v_session);

  elsif p_game_type = 'sin-filtro' then
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
    if v_blancas is null or jsonb_array_length(coalesce(v_blancas, '[]')) < 7 * v_np then
      select coalesce(jsonb_agg(to_jsonb(text_es) order by random()), '[]') into v_blancas
      from content_cards
      where game_type = 'sin-filtro' and card_type = 'blanca' and intensity <= v_intensity and enabled;
    end if;
    if jsonb_array_length(v_deck) = 0 or jsonb_array_length(v_blancas) < 7 * v_np then
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
          where ord > i * 7 and ord <= (i + 1) * 7) s)));
      i := i + 1;
    end loop;
    v_blancas := (select coalesce(jsonb_agg(e), '[]') from (
      select e from jsonb_array_elements(v_blancas) with ordinality t(e, ord)
      where ord > v_np * 7) s);

    v_session.state := jsonb_build_object(
      'negras', v_deck, 'negra_idx', 0, 'blancas', v_blancas, 'timer_s', v_timer,
      'turn_order', to_jsonb(v_ids), 'juez_idx', next_active_turn(to_jsonb(v_ids), -1),
      'plays', '[]'::jsonb, 'winner_idx', null,
      'phase', 'jugar', 'phase_ends_at', to_jsonb(now() + make_interval(secs => v_timer)),
      'scores', (select jsonb_object_agg(pid::text, 0) from unnest(v_ids) pid));
    update game_sessions set state = v_session.state where id = v_session.id;

  elsif p_game_type = 'paranoia' then
    perform pa_launch(p_party_id, v_session.id, p_opts, v_intensity, v_n, v_ids);

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

  elsif p_game_type = 'parejas-a-gritos' then
    v_timer := least(180, greatest(15, coalesce((p_opts->>'timer_s')::int, 45)));
    update game_sessions set state = jsonb_build_object(
      'rounds_total', least(6, greatest(2, coalesce((p_opts->>'n_cards')::int, 3))),
      'round_idx', -1, 'timer_s', v_timer, 'used', '[]'::jsonb,
      'scores', (select jsonb_object_agg(pid::text, 0) from unnest(v_ids) pid))
      where id = v_session.id;
    select * into v_session from game_sessions where id = v_session.id;
    perform pj_start_round(p_party_id, v_session);
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

  if v_session.game_type = 'prueba' then
    if not p_force and not prueba_can_advance(v_session) then return; end if;
    if v_session.state->>'phase' = 'turnos' then perform prueba_step_turn(p_party_id); return; end if;
    v_next := prueba_next_phase(v_session.state->>'phase');
    if v_next is null then perform end_game(p_party_id); return; end if;
    update game_sessions set state = prueba_enter_phase(v_session, v_next) where id = v_session.id;

  elsif v_session.game_type = 'yo-nunca' then
    if not p_force and not yn_can_advance(v_session) then return; end if;
    v_next := yn_next_phase(v_session);
    if v_next is null then perform end_game(p_party_id); return; end if;
    update game_sessions set state = yn_enter_phase(v_session, v_next) where id = v_session.id;

  elsif v_session.game_type = 'el-senalado' then
    if not p_force and not es_can_advance(v_session) then return; end if;
    v_next := es_next_phase(v_session);
    if v_next is null then perform end_game(p_party_id); return; end if;
    update game_sessions set state = es_enter_phase(v_session, v_next) where id = v_session.id;

  elsif v_session.game_type = 'verdad-o-reto' then
    if not p_force and not vr_can_advance(v_session) then return; end if;
    perform vr_step(p_party_id, v_session);

  elsif v_session.game_type = 'la-ruleta' then
    if not p_force then return; end if;
    declare v_new jsonb;
    begin
      v_new := rl_enter_carta(v_session);
      if v_new is null then perform end_game(p_party_id); return; end if;
      update game_sessions set state = v_new where id = v_session.id;
    end;

  elsif v_session.game_type = 'el-rey' then
    if v_session.state->>'phase' = 'fin' then
      if p_force then perform end_game(p_party_id); end if;
      return;
    end if;
    if not p_force and not rey_can_advance(v_session) then return; end if;
    perform rey_draw(p_party_id, v_session);

  elsif v_session.game_type = 'ocurrencias' then
    if not p_force and not oc_can_advance(v_session) then return; end if;
    v_next := oc_next_phase(v_session);
    if v_next is null then perform end_game(p_party_id); return; end if;
    update game_sessions set state = oc_enter_phase(v_session, v_next) where id = v_session.id;

  elsif v_session.game_type = 'mentiras' then
    if not p_force and not mt_can_advance(v_session) then return; end if;
    v_next := mt_next_phase(v_session);
    if v_next is null then perform end_game(p_party_id); return; end if;
    update game_sessions set state = mt_enter_phase(v_session, v_next) where id = v_session.id;

  elsif v_session.game_type = 'la-manada' then
    if v_session.state->>'phase' = 'responder' then
      if not p_force and not mn_can_advance(v_session) then return; end if;
      update game_sessions set state = mn_enter_phase(v_session, 'agrupar') where id = v_session.id;
    elsif v_session.state->>'phase' = 'agrupar' then
      if not p_force then return; end if;
      update game_sessions set state = mn_enter_phase(v_session, 'reveal') where id = v_session.id;
    elsif v_session.state->>'phase' = 'reveal' then
      if not p_force then return; end if;
      v_next := mn_next_phase(v_session);
      if v_next is null then perform end_game(p_party_id); return; end if;
      update game_sessions set state = mn_enter_phase(v_session, v_next) where id = v_session.id;
    elsif v_session.state->>'phase' = 'podio' then
      if p_force then perform end_game(p_party_id); end if;
    end if;

  elsif v_session.game_type = 'impostor' then
    if v_session.state->>'phase' = 'secreto' then
      if not p_force and not im_can_advance(v_session) then return; end if;
      update game_sessions set state = state || jsonb_build_object('phase', 'pistas', 'phase_ends_at', null)
        where id = v_session.id;
    elsif v_session.state->>'phase' = 'pistas' then
      if not p_force then return; end if; -- host manda a votar cuando ya se habló
      update game_sessions set state = state || jsonb_build_object('phase', 'voto',
        'phase_ends_at', to_jsonb(now() + make_interval(secs => coalesce((v_session.state->>'timer_s')::int, 30))))
        where id = v_session.id;
    elsif v_session.state->>'phase' = 'voto' then
      if not p_force and not im_can_advance(v_session) then return; end if;
      perform im_after_voto(v_session);
    elsif v_session.state->>'phase' = 'adivinar' then
      if not p_force and not im_can_advance(v_session) then return; end if;
      if v_session.state->>'guess' is not null then
        -- guess bloqueado → pantalla pública de confirmación (la palabra se expone)
        update game_sessions set state = state || jsonb_build_object(
          'phase', 'confirmar', 'word', im_word(v_session.id), 'phase_ends_at', null)
          where id = v_session.id;
      else
        perform im_enter_reveal(v_session, 'fallo'); -- sin guess a tiempo
      end if;
    elsif v_session.state->>'phase' = 'confirmar' then
      if not p_force then return; end if; -- escape del host = lo da por fallado
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
      perform sf_crown(p_party_id, v_session,
        floor(random() * jsonb_array_length(v_session.state->'plays'))::int);
    elsif v_session.state->>'phase' = 'resultado' then
      if not p_force then return; end if;
      perform sf_next_round(p_party_id, v_session);
    elsif v_session.state->>'phase' = 'podio' then
      if p_force then perform end_game(p_party_id); end if;
    end if;

  elsif v_session.game_type = 'paranoia' then
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

  elsif v_session.game_type = 'tres-rondas' then
    if v_session.state->>'phase' = 'turno' then
      if not p_force and not tr_can_advance(v_session) then return; end if;
      update game_sessions set state = state || jsonb_build_object('phase', 'entre', 'phase_ends_at', null)
        where id = v_session.id;
    elsif v_session.state->>'phase' = 'entre' then
      -- lo dispara el botón "¡Empezar turno!" (cualquier miembro) o el host
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
  v_order uuid[];
  v_new jsonb;
  v_idx int;
  v_auth uuid[];
  v_truth text;
  v_team text;
begin
  if v_me is null then raise exception 'NO_MIEMBRO'; end if;
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;
  v_state := v_session.state;
  v_phase := v_state->>'phase';

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

  if v_session.game_type = 'el-senalado' then
    if p_action = 'vote' and v_phase = 'voto' then
      v_target := (p_payload->>'target')::uuid;
      if v_target = v_me then raise exception 'NO_AUTOVOTO'; end if;
      if not exists (select 1 from players where id = v_target and party_id = p_party_id and status = 'active') then
        raise exception 'VOTO_INVALIDO';
      end if;
      v_state := jsonb_set(v_state, array['votes', v_me::text], to_jsonb(v_target::text));
    else
      raise exception 'ACCION_INVALIDA';
    end if;
    update game_sessions set state = v_state where id = v_session.id;
    select * into v_session from game_sessions where id = v_session.id;
    if es_can_advance(v_session) then perform advance_phase(p_party_id, false); end if;
    return;
  end if;

  if v_session.game_type = 'verdad-o-reto' then
    if p_action = 'choose' and v_phase = 'elegir' then
      if (v_state->'turn_order'->>((v_state->>'turn_idx')::int))::uuid <> v_me then
        raise exception 'NO_ES_TU_TURNO';
      end if;
      if p_payload->>'value' not in ('verdad','reto') then raise exception 'ELECCION_INVALIDA'; end if;
      v_new := vr_pick_card(v_state, p_payload->>'value');
      if v_new is null then perform end_game(p_party_id); return; end if;
      update game_sessions set state = v_new where id = v_session.id;
    elsif p_action = 'done' and v_phase = 'carta' then
      if (v_state->'turn_order'->>((v_state->>'turn_idx')::int))::uuid <> v_me
         and not is_host_of(p_party_id) then
        raise exception 'NO_ES_TU_TURNO';
      end if;
      perform vr_step(p_party_id, v_session);
    elsif p_action = 'reroll' and v_phase = 'carta' then
      if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
      if coalesce((v_state->>'rerolled')::boolean, false) then raise exception 'YA_REROLL'; end if;
      v_new := vr_pick_card(v_state, v_state->>'choice');
      if v_new is null then perform end_game(p_party_id); return; end if;
      update game_sessions set state = v_new || jsonb_build_object('rerolled', true) where id = v_session.id;
    else
      raise exception 'ACCION_INVALIDA';
    end if;
    return;
  end if;

  if v_session.game_type = 'el-rey' then
    if p_action = 'draw' and v_phase = 'carta' then
      if (v_state->'turn_order'->>((v_state->>'turn_idx')::int))::uuid <> v_me then
        raise exception 'NO_ES_TU_TURNO';
      end if;
      perform rey_draw(p_party_id, v_session);
    else
      raise exception 'ACCION_INVALIDA';
    end if;
    return;
  end if;

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

  if v_session.game_type = 'mentiras' then
    if p_action = 'lie' and v_phase = 'mentir' then
      v_text := left(trim(coalesce(p_payload->>'text','')), 80);
      if v_text = '' then raise exception 'TEXTO_VACIO'; end if;
      v_truth := v_state->'deck'->((v_state->>'round_idx')::int)->>'answer';
      if lower(btrim(v_text)) = lower(btrim(v_truth)) then raise exception 'ES_LA_VERDAD'; end if;
      v_state := jsonb_set(v_state, array['lies', v_me::text], to_jsonb(v_text));

    elsif p_action = 'pick' and v_phase = 'elegir' then
      v_idx := (p_payload->>'idx')::int;
      if v_state->'options'->v_idx is null then raise exception 'OPCION_INVALIDA'; end if;
      if v_state->'options'->v_idx->'authors' ? v_me::text then raise exception 'TU_MENTIRA'; end if;
      v_state := jsonb_set(v_state, array['picks', v_me::text], to_jsonb(v_idx::text));

    else
      raise exception 'ACCION_INVALIDA';
    end if;
    update game_sessions set state = v_state where id = v_session.id;
    select * into v_session from game_sessions where id = v_session.id;
    if mt_can_advance(v_session) then perform advance_phase(p_party_id, false); end if;
    return;
  end if;

  if v_session.game_type = 'la-manada' then
    if p_action = 'answer' and v_phase = 'responder' then
      v_text := left(trim(coalesce(p_payload->>'text','')), 60);
      if v_text = '' then raise exception 'TEXTO_VACIO'; end if;
      v_state := jsonb_set(v_state, array['answers', v_me::text], to_jsonb(v_text));
      update game_sessions set state = v_state where id = v_session.id;
      select * into v_session from game_sessions where id = v_session.id;
      if mn_can_advance(v_session) then perform advance_phase(p_party_id, false); end if;
    elsif p_action = 'merge' and v_phase = 'agrupar' then
      if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
      perform mn_merge(v_session, (p_payload->>'a')::int, (p_payload->>'b')::int);
    else
      raise exception 'ACCION_INVALIDA';
    end if;
    return;
  end if;

  if v_session.game_type = 'impostor' then
    if p_action = 'ready' and v_phase = 'secreto' then
      v_state := jsonb_set(v_state, array['ready', v_me::text], 'true');
      update game_sessions set state = v_state where id = v_session.id;
      select * into v_session from game_sessions where id = v_session.id;
      if im_can_advance(v_session) then perform advance_phase(p_party_id, false); end if;

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
      perform advance_phase(p_party_id, false); -- pasa directo a confirmar

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
      if v_me = sf_juez(v_state) then raise exception 'ERES_EL_JUEZ'; end if;
      if exists (select 1 from jsonb_array_elements(v_state->'plays') e where (e->>'pid')::uuid = v_me) then
        raise exception 'YA_JUGASTE';
      end if;
      perform sf_play_card(v_session.id, v_me, (p_payload->>'idx')::int);
      select * into v_session from game_sessions where id = v_session.id;
      if sf_can_advance(v_session) then perform advance_phase(p_party_id, false); end if;

    elsif p_action = 'crown' and v_phase = 'juzgar' then
      if v_me <> sf_juez(v_state) then raise exception 'SOLO_EL_JUEZ'; end if;
      perform sf_crown(p_party_id, v_session, (p_payload->>'idx')::int);

    else
      raise exception 'ACCION_INVALIDA';
    end if;
    return;
  end if;

  if v_session.game_type = 'paranoia' then
    if p_action = 'point' and v_phase = 'senalar' then
      if v_me <> pa_asker(v_state) then raise exception 'NO_ES_TU_TURNO'; end if;
      v_target := (p_payload->>'target')::uuid;
      if v_target = v_me then raise exception 'NO_AUTOSENALADO'; end if;
      if not exists (select 1 from players where id = v_target and party_id = p_party_id and status = 'active') then
        raise exception 'SENALADO_INVALIDO';
      end if;
      update game_sessions set state = state || jsonb_build_object(
        'phase', 'decidir', 'target', v_target,
        'phase_ends_at', to_jsonb(now() + interval '30 seconds'))
        where id = v_session.id;
    elsif p_action = 'decide' and v_phase = 'decidir' then
      if v_me <> (v_state->>'target')::uuid then raise exception 'NO_ERES_EL_SENALADO'; end if;
      perform pa_decide(p_party_id, v_session, coalesce((p_payload->>'pay')::boolean, false));
    else
      raise exception 'ACCION_INVALIDA';
    end if;
    return;
  end if;

  if v_session.game_type = 'tres-rondas' then
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
  v_words text[] := array['épica','confusa','legendaria','sudorosa','inolvidable','rara','gloriosa'];
  v_frases text[] := array['un mariachi en huelga','la abuela con jetlag','un tamal radiactivo',
    'el ex de todo el mundo','un bus sin frenos','la resaca eterna','un gato con deudas',
    'el DJ del pueblo','una arepa gigante','el vecino chismoso'];
  v_herd text[] := array['perro','gato','pizza','cerveza','rojo'];
  v_order uuid[];
  v_turn uuid;
  v_auth uuid[];
  v_idx int;
  v_truth text;
  v_lie text;
  v_who uuid;
  v_team text;
  i int;
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then return; end if;
  v_phase := v_session.state->>'phase';

  if v_session.game_type in ('verdad-o-reto', 'el-rey') then
    v_state := v_session.state;
    v_turn := (v_state->'turn_order'->>((v_state->>'turn_idx')::int))::uuid;
    if exists (select 1 from players where id = v_turn and is_bot and status = 'active') then
      if v_session.game_type = 'verdad-o-reto' then
        if v_phase = 'elegir' then
          v_state := vr_pick_card(v_state, case when random() < 0.5 then 'verdad' else 'reto' end);
          if v_state is null then perform end_game(p_party_id); return; end if;
          update game_sessions set state = v_state where id = v_session.id;
        elsif v_phase = 'carta' then
          perform vr_step(p_party_id, v_session);
        end if;
      elsif v_session.game_type = 'el-rey' and v_phase = 'carta' then
        perform rey_draw(p_party_id, v_session);
      end if;
    end if;
    return;
  end if;

  if v_session.game_type = 'sin-filtro' then
    v_state := v_session.state;
    if v_phase = 'juzgar' then
      if exists (select 1 from players where id = sf_juez(v_state) and is_bot and status = 'active')
         and jsonb_array_length(v_state->'plays') > 0 then
        perform sf_crown(p_party_id, v_session,
          floor(random() * jsonb_array_length(v_state->'plays'))::int);
      end if;
      return;
    elsif v_phase = 'jugar' then
      for v_bot in select id from players where party_id = p_party_id and is_bot and status = 'active' loop
        v_state := (select state from game_sessions where id = v_session.id);
        if v_bot.id <> sf_juez(v_state)
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

  -- impostor: bots dan ready, votan random y (si el impostor es bot) adivinan random
  if v_session.game_type = 'impostor' then
    v_state := v_session.state;
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

  if v_session.game_type = 'paranoia' then
    if v_phase = 'senalar' then
      v_who := pa_asker(v_session.state);
      if exists (select 1 from players where id = v_who and is_bot and status = 'active') then
        v_targets := array(select id from players
          where party_id = p_party_id and status = 'active' and id <> v_who);
        update game_sessions set state = state || jsonb_build_object(
          'phase', 'decidir', 'target', v_targets[1 + floor(random()*array_length(v_targets,1))::int],
          'phase_ends_at', to_jsonb(now() + interval '30 seconds'))
          where id = v_session.id;
      end if;
    elsif v_phase = 'decidir' then
      v_who := (v_session.state->>'target')::uuid;
      if exists (select 1 from players where id = v_who and is_bot and status = 'active') then
        perform pa_decide(p_party_id, v_session, random() < 0.5);
      elsif pa_can_advance(v_session) then
        perform advance_phase(p_party_id, false);
      end if;
    end if;
    return;
  end if;

  if v_session.game_type = 'tres-rondas' then
    v_state := v_session.state;
    if v_state->>'phase' = 'turno'
       and exists (select 1 from players where id = tr_actor(v_state) and is_bot and status = 'active') then
      if coalesce((v_state->>'phase_ends_at')::timestamptz < now(), false) then
        update game_sessions set state = state || jsonb_build_object('phase', 'entre', 'phase_ends_at', null)
          where id = v_session.id;
      else
        -- el bot "adivina" una por tick
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
      -- si el siguiente activo es bot, arranca solo
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

    elsif v_session.game_type = 'el-senalado' then
      if v_phase = 'voto' and not (v_state->'votes' ? v_bot.id::text) then
        v_targets := array(select id from players where party_id = p_party_id and status = 'active' and id <> v_bot.id);
        update game_sessions set state = jsonb_set(state, array['votes', v_bot.id::text],
          to_jsonb(v_targets[1 + floor(random()*array_length(v_targets,1))::int]::text))
          where id = v_session.id;
      end if;

    elsif v_session.game_type = 'ocurrencias' then
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

    elsif v_session.game_type = 'mentiras' then
      if v_phase = 'mentir' and not (v_state->'lies' ? v_bot.id::text) then
        v_truth := v_state->'deck'->((v_state->>'round_idx')::int)->>'answer';
        v_lie := v_frases[1 + floor(random()*array_length(v_frases,1))::int];
        if lower(btrim(v_lie)) = lower(btrim(v_truth)) then v_lie := v_lie || ' (dudoso)'; end if;
        update game_sessions set state = jsonb_set(state, array['lies', v_bot.id::text], to_jsonb(v_lie))
          where id = v_session.id;
      elsif v_phase = 'elegir' and not (v_state->'picks' ? v_bot.id::text) then
        v_idx := (select (t.ord - 1)::int from
          jsonb_array_elements(v_state->'options') with ordinality t(e, ord)
          where not (t.e->'authors' ? v_bot.id::text)
          order by random() limit 1);
        if v_idx is not null then
          update game_sessions set state = jsonb_set(state, array['picks', v_bot.id::text],
            to_jsonb(v_idx::text))
            where id = v_session.id;
        end if;
      end if;

    elsif v_session.game_type = 'la-manada' then
      if v_phase = 'responder' and not (v_state->'answers' ? v_bot.id::text) then
        update game_sessions set state = jsonb_set(state, array['answers', v_bot.id::text],
          to_jsonb(v_herd[1 + floor(random()*array_length(v_herd,1))::int]))
          where id = v_session.id;
      end if;
    end if;
  end loop;

  select * into v_session from game_sessions where id = v_session.id;
  if v_session.status = 'active' then
    if (v_session.game_type = 'prueba' and prueba_can_advance(v_session))
       or (v_session.game_type = 'el-senalado' and es_can_advance(v_session))
       or (v_session.game_type = 'ocurrencias' and oc_can_advance(v_session))
       or (v_session.game_type = 'mentiras' and mt_can_advance(v_session))
       or (v_session.game_type = 'la-manada' and mn_can_advance(v_session)) then
      perform advance_phase(p_party_id, false);
    end if;
  end if;
end $$;

-- ==================== LIMPIEZA DE LA CADENA ====================
drop function if exists launch_game_013(uuid, text, jsonb);
drop function if exists advance_phase_013(uuid, boolean);
drop function if exists submit_action_013(uuid, text, jsonb);
drop function if exists dev_bot_tick_013(uuid);
drop function if exists launch_game_012(uuid, text, jsonb);
drop function if exists advance_phase_012(uuid, boolean);
drop function if exists submit_action_012(uuid, text, jsonb);
drop function if exists dev_bot_tick_012(uuid);
