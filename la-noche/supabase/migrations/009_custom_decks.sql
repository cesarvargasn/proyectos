-- ============================================================
-- LA NOCHE — Migración 009: mazos armados a mano
-- Correr DESPUÉS de 008.
--
-- launch_game acepta p_opts.card_ids (uuid[]): el host compone el
-- mazo en el deck builder y el server lo usa EN ESE ORDEN (importa
-- en La Ruleta: la escalación es el orden del array). Se ignoran ids
-- de otro juego o cartas apagadas. Sin card_ids → random como antes.
-- VoR: los ids elegidos se separan en bancos por card_type.
-- ============================================================

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
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  if p_game_type not in ('prueba','yo-nunca','el-senalado','verdad-o-reto','la-ruleta','el-rey') then
    raise exception 'JUEGO_NO_DISPONIBLE';
  end if;
  if exists (select 1 from game_sessions where party_id = p_party_id and status = 'active') then
    raise exception 'YA_HAY_JUEGO';
  end if;

  select coalesce((settings->>'intensity')::int, 2) into v_intensity from parties where id = p_party_id;
  v_intensity := least(5, greatest(1, coalesce((p_opts->>'intensity')::int, v_intensity)));
  v_n := least(60, greatest(5, coalesce((p_opts->>'n_cards')::int,
           case p_game_type when 'la-ruleta' then 40 when 'verdad-o-reto' then 30 else 15 end)));
  v_timer := least(120, greatest(10, coalesce((p_opts->>'timer_s')::int,
               case p_game_type when 'verdad-o-reto' then 20 else 30 end)));
  v_ids := acting_player_ids(p_party_id);

  -- mazo explícito del deck builder (orden = orden del array)
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
      'turn_no', 0, 'total_turns', 2 * array_length(v_ids, 1));
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
  end if;

  update parties set status = 'in_game' where id = p_party_id;
  return v_session.id;
end $$;
