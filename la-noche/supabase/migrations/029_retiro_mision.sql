-- ============================================================================
-- 029_retiro_mision.sql — César 2026-11-01: MISIÓN SECRETA se borra
-- ("está muy complicado, borrarlo está bien").
--
-- launch_game = el de 028 sin 'mision-secreta' en la lista permitida ni su
-- rama. Quedan 6 JUEGOS LANZABLES: la-ruleta, impostor, tres-rondas
-- (Charadas), parejas-a-gritos, lobos, dos-cuartos.
-- Sesiones activas de Misión (si hubiera) se terminan.
-- Helpers ms_* quedan en la base sin referencias (deuda conocida, patrón 023).
-- ============================================================================

update game_sessions set status = 'ended'
  where game_type = 'mision-secreta' and status = 'active';
update parties p set status = 'lobby'
  where status = 'in_game'
    and not exists (select 1 from game_sessions s where s.party_id = p.id and s.status = 'active');

-- ==================== LAUNCH (028 sin mision-secreta) ====================
create or replace function launch_game(p_party_id uuid, p_game_type text, p_opts jsonb default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_deck jsonb;
  v_n int;
  v_ids uuid[];
  v_card_ids uuid[];
  v_np int;
  v_pool jsonb;
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  if p_game_type not in ('la-ruleta','impostor','tres-rondas','parejas-a-gritos',
                         'lobos','dos-cuartos') then
    raise exception 'JUEGO_NO_DISPONIBLE';
  end if;
  if exists (select 1 from game_sessions where party_id = p_party_id and status = 'active') then
    raise exception 'YA_HAY_JUEGO';
  end if;

  v_n := least(60, greatest(3, coalesce((p_opts->>'n_cards')::int,
           case p_game_type when 'la-ruleta' then 40 when 'impostor' then 3 else 15 end)));
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
        where game_type = 'la-ruleta' and enabled
        order by random() limit v_n
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
        where game_type = 'impostor' and enabled
          and jsonb_array_length(coalesce(meta->'words', '[]'::jsonb)) >= 3
        order by random() limit v_n
      ) c;
    end if;
    if jsonb_array_length(v_deck) = 0 then
      delete from game_sessions where id = v_session.id;
      raise exception 'SIN_CARTAS';
    end if;
    -- 028: siempre en vivo; n_impostors 1-3 (im_start_round aplica el tope)
    update game_sessions set state = jsonb_build_object(
      'deck', v_deck, 'round_idx', -1, 'offline', true,
      'n_impostors', least(3, greatest(1, coalesce((p_opts->>'n_impostors')::int, 1))),
      'scores', (select jsonb_object_agg(pid::text, 0) from unnest(v_ids) pid))
      where id = v_session.id;
    select * into v_session from game_sessions where id = v_session.id;
    perform im_start_round(v_session);

  elsif p_game_type = 'tres-rondas' then
    v_n := least(40, greatest(6, coalesce((p_opts->>'n_cards')::int, least(40, 5 * v_np))));
    if v_card_ids is not null then
      select coalesce(jsonb_agg(to_jsonb(text_es)), '[]') into v_pool
      from content_cards where id = any(v_card_ids) and game_type = 'tres-rondas' and enabled;
    else
      select coalesce(jsonb_agg(to_jsonb(text_es)), '[]') into v_pool from (
        select text_es from content_cards
        where game_type = 'tres-rondas' and enabled
        order by random() limit v_n) s;
    end if;
    if jsonb_array_length(v_pool) < 6 then
      delete from game_sessions where id = v_session.id;
      raise exception 'SIN_CARTAS';
    end if;
    -- 028: siempre MODO BASE (la app arma equipos y da palabras; el resto en vivo)
    update game_sessions set state = jsonb_build_object(
      'mode_base', true, 'phase', 'base', 'phase_ends_at', null,
      'pool', v_pool,
      'remaining', (select jsonb_agg(e order by random()) from jsonb_array_elements(v_pool) e),
      'teams', (select jsonb_object_agg(pid::text, case when ord % 2 = 0 then 'A' else 'B' end)
                from (select pid, row_number() over () as ord
                      from unnest(v_ids) pid order by random()) t))
      where id = v_session.id;

  elsif p_game_type = 'parejas-a-gritos' then
    update game_sessions set state = jsonb_build_object(
      'rounds_total', least(8, greatest(2, coalesce((p_opts->>'n_cards')::int, 3))),
      'round_idx', -1, 'used', '[]'::jsonb)
      where id = v_session.id;
    select * into v_session from game_sessions where id = v_session.id;
    perform pj_start_round(p_party_id, v_session);

  elsif p_game_type = 'lobos' then
    -- 028: siempre en vivo (host = moderador)
    perform lb_launch(p_party_id, v_session.id, p_opts || '{"offline": true}'::jsonb);

  elsif p_game_type = 'dos-cuartos' then
    perform dc_launch(p_party_id, v_session.id, p_opts);
  end if;

  update parties set status = 'in_game' where id = p_party_id;
  return v_session.id;
end $$;
