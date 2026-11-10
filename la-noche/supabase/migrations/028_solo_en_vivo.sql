-- ============================================================================
-- 028_solo_en_vivo.sql — feedback de César 2026-10-31 (probando los 7 finales)
--
--  1. SOLO MODO EN VIVO para Impostor, Charadas (tres-rondas) y Lobos. El
--     modo app (timers, votos y turnos en el celular) deja de ser opción:
--     launch_game fuerza offline / mode_base pase lo que pase en p_opts.
--     Las ramas viejas de advance/submit/bot_tick quedan sin quién las
--     alcance (no se tocan: solo launch_game se reescribe).
--
--  2. IMPOSTOR: elegir cuántos impostores (1, 2 o 3) con p_opts.n_impostors.
--     Tope = jugadores - 2 (siempre quedan al menos 2 con la palabra). El
--     número va al state (público: todos saben cuántos hay); quiénes son
--     solo en player_secrets + secret.admin del host.
--
--  3. LOBOS — BUG panel del moderador: admin_roles era un objeto con el
--     NOMBRE como llave, y los bots salen con nombres repetidos ("Tito 🤖"
--     dos veces) → se pisaban y faltaban filas (6 de 8). Ahora es un
--     array [{pid, name, role}], una fila por jugador sí o sí.
--
-- Dos Cuartos no cambia en SQL: los cuartos ya se sortean aparte de los
-- equipos (mezclados). Lo que confundía era el copy del cliente.
-- ============================================================================

-- ==================== IMPOSTOR: N impostores ====================
create or replace function im_start_round(p_session game_sessions)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_round int := coalesce((v_state->>'round_idx')::int, -1) + 1;
  v_card_id uuid;
  v_words jsonb;
  v_word text;
  v_ids uuid[];
  v_imps uuid[];
  v_n int;
  v_pid uuid;
  v_host uuid;
begin
  v_card_id := (v_state->'deck'->v_round->>'id')::uuid;
  select meta->'words' into v_words from content_cards where id = v_card_id;
  if v_words is null or jsonb_array_length(v_words) < 3 then
    raise exception 'SIN_CARTAS';
  end if;
  v_word := v_words->>(floor(random() * jsonb_array_length(v_words))::int);

  v_ids := acting_player_ids(p_session.party_id);
  v_n := least(greatest(coalesce((v_state->>'n_impostors')::int, 1), 1), 3,
               greatest(1, array_length(v_ids, 1) - 2));
  v_imps := array(select pid from unnest(v_ids) pid order by random() limit v_n);

  delete from player_secrets where game_session_id = p_session.id;
  foreach v_pid in array v_ids loop
    insert into player_secrets (game_session_id, player_id, payload)
    values (p_session.id, v_pid, case when v_pid = any(v_imps)
      then jsonb_build_object('role', 'impostor')
      else jsonb_build_object('role', 'normal', 'word', v_word) end);
  end loop;

  -- el host ve a los impostores y la palabra (modera en vivo)
  select id into v_host from players
    where party_id = p_session.party_id and is_host limit 1;
  if v_host is not null then
    update player_secrets set payload = payload || jsonb_build_object(
      'admin', jsonb_build_object(
        'impostores', (select jsonb_agg(name order by name) from players where id = any(v_imps)),
        'impostor', (select string_agg(name, ', ' order by name) from players where id = any(v_imps)),
        'word', v_word))
      where game_session_id = p_session.id and player_id = v_host;
  end if;

  update game_sessions set state = v_state || jsonb_build_object(
    'phase', 'secreto', 'round_idx', v_round, 'n_impostors', v_n,
    'turn_order', (select jsonb_agg(to_jsonb(pid) order by random()) from unnest(v_ids) pid),
    'ready', '{}'::jsonb, 'votes', '{}'::jsonb, 'guess', null, 'hunts', 0,
    'word', null, 'impostor', null, 'outcome', null, 'accused', null,
    'phase_ends_at', null)
  where id = p_session.id;
end $$;

-- ==================== LOBOS: panel del moderador sin choques de nombre ====================
create or replace function lb_launch(p_party_id uuid, p_session_id uuid, p_opts jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
declare
  v_ids uuid[];
  v_np int;
  v_wolves int;
  v_roles text[];
  v_wnames text;
  v_pid uuid;
  v_host uuid;
  v_offline boolean := coalesce((p_opts->>'offline')::boolean, false);
  v_vid boolean;
  v_prot boolean;
  v_bruja boolean;
  v_caza boolean;
  i int := 0;
begin
  select id into v_host from players where party_id = p_party_id and is_host limit 1;

  v_ids := (select array_agg(pid order by random()) from unnest(acting_player_ids(p_party_id)) pid);
  if v_offline and v_host is not null then
    v_ids := array(select pid from unnest(v_ids) pid where pid <> v_host); -- host = moderador
  end if;
  v_np := coalesce(array_length(v_ids, 1), 0);
  if (not v_offline and v_np < 6) or (v_offline and v_np < 4) then
    delete from game_sessions where id = p_session_id;
    raise exception 'FALTAN_JUGADORES';
  end if;

  v_wolves := coalesce((p_opts->>'wolves')::int,
                       case when v_np <= 7 then 2 when v_np <= 11 then 3 else 4 end);
  v_wolves := least(greatest(v_wolves, 1), greatest(1, v_np - 2));
  v_vid   := coalesce((p_opts->'roles'->>'vidente')::boolean, true);
  v_prot  := coalesce((p_opts->'roles'->>'protector')::boolean, true);
  v_bruja := coalesce((p_opts->'roles'->>'bruja')::boolean, v_np >= 8);
  v_caza  := coalesce((p_opts->'roles'->>'cazador')::boolean, v_np >= 12);

  v_roles := array_fill('lobo'::text, array[v_wolves]);
  if v_vid then v_roles := v_roles || 'vidente'::text; end if;
  if v_prot then v_roles := v_roles || 'protector'::text; end if;
  if v_bruja then v_roles := v_roles || 'bruja'::text; end if;
  if v_caza then v_roles := v_roles || 'cazador'::text; end if;
  if array_length(v_roles, 1) > v_np then
    delete from game_sessions where id = p_session_id;
    raise exception 'FALTAN_JUGADORES'; -- más roles que jugadores
  end if;
  while array_length(v_roles, 1) < v_np loop
    v_roles := v_roles || 'aldeano'::text;
  end loop;
  v_roles := (select array_agg(r order by random()) from unnest(v_roles) r);

  delete from player_secrets where game_session_id = p_session_id;
  foreach v_pid in array v_ids loop
    i := i + 1;
    insert into player_secrets (game_session_id, player_id, payload)
    values (p_session_id, v_pid,
      case v_roles[i]
        when 'bruja' then jsonb_build_object('role', 'bruja',
          'potions', jsonb_build_object('salvar', true, 'matar', true))
        else jsonb_build_object('role', v_roles[i])
      end);
  end loop;

  select string_agg(p.name, ', ') into v_wnames
  from player_secrets s join players p on p.id = s.player_id
  where s.game_session_id = p_session_id and s.payload->>'role' = 'lobo';
  update player_secrets set payload = payload || jsonb_build_object('wolves', v_wnames)
    where game_session_id = p_session_id and payload->>'role' = 'lobo';

  -- moderador (offline): UNA FILA POR JUGADOR (028: array, ya no objeto por nombre)
  if v_offline and v_host is not null then
    insert into player_secrets (game_session_id, player_id, payload)
    values (p_session_id, v_host, jsonb_build_object(
      'role', 'moderador',
      'admin_roles', (select coalesce(jsonb_agg(jsonb_build_object(
                        'pid', p.id, 'name', p.name, 'role', s.payload->>'role')
                        order by s.payload->>'role' = 'aldeano', s.payload->>'role', p.name), '[]'::jsonb)
                      from player_secrets s join players p on p.id = s.player_id
                      where s.game_session_id = p_session_id
                        and s.payload->>'role' <> 'moderador')));
  end if;

  update game_sessions set state = jsonb_build_object(
    'phase', 'reparto', 'phase_ends_at', null, 'night_no', 0,
    'offline', v_offline,
    'ready', '{}'::jsonb, 'acted', '{}'::jsonb, 'votes', '{}'::jsonb,
    'vote_round', 1, 'vote_pool', null,
    'dead', '{}'::jsonb, 'revealed', '{}'::jsonb, 'morning', '[]'::jsonb,
    'executed', null, 'hunter', null, 'hunter_from', null, 'hunter_kill', null,
    'winner', null, 'roles_pub', null,
    'comp', jsonb_build_object('lobos', v_wolves, 'vidente', v_vid,
      'protector', v_prot, 'bruja', v_bruja, 'cazador', v_caza))
    where id = p_session_id;
end $$;

-- ==================== LAUNCH (027 + modo en vivo forzado + n_impostors) ====================
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
                         'lobos','mision-secreta','dos-cuartos') then
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

  elsif p_game_type = 'mision-secreta' then
    perform ms_launch(p_party_id, v_session.id);

  elsif p_game_type = 'dos-cuartos' then
    perform dc_launch(p_party_id, v_session.id, p_opts);
  end if;

  update parties set status = 'in_game' where id = p_party_id;
  return v_session.id;
end $$;

revoke execute on function im_start_round(game_sessions) from public, anon, authenticated;
revoke execute on function lb_launch(uuid, uuid, jsonb) from public, anon, authenticated;
