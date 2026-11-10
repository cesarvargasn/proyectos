-- ============================================================
-- LA NOCHE — Migración 014: Tres Rondas + Parejas a Gritos (cierra Wave 3)
-- Correr DESPUÉS de 013. Cartas: content tres-rondas.sql y parejas-a-gritos.sql
--
-- TRES RONDAS ('tres-rondas') — Fishbowl: MISMO pool en 3 rondas
--   (1 Descríbelo / 2 UNA palabra / 3 Actúalo). 2 equipos (A/B alternando).
--   Turnos de 60s: el actor ve la palabra en su celular, su equipo grita;
--   "¡La adivinaron!" +1 equipo y saca otra; "Pasar" la manda al fondo.
--   Pool agotado = ronda siguiente (mismas palabras, rebarajadas).
--   Leak conocido aceptado: palabra actual va en state (leak-proofing
--   estricto fue para Impostor). state = { phase turno|entre|podio, round,
--   pool, remaining, turn_order, turn_idx, teams:{pid:A|B},
--   team_scores:{A,B}, phase_ends_at }
--
-- PAREJAS A GRITOS ('parejas-a-gritos') — juego de César: cada ronda el
--   server arma parejas secretas por PALABRA (impar = un trío). 45s de
--   caos gritando pistas de tu palabra; luego 30s para elegir quién crees
--   que tiene TU palabra. Acierto +50, y si fue MUTUO +50 extra c/u.
--   Palabras solo en player_secrets; state no las lleva hasta reveal.
--   state = { phase gritos|elegir|reveal|podio, round_idx, rounds_total,
--   timer_s, used:[card_id], picks, groups(null hasta reveal), scores }
-- ============================================================

-- ---------- TRES RONDAS ----------
create or replace function tr_actor(p_state jsonb)
returns uuid language sql immutable as $$
  select (p_state->'turn_order'->>((p_state->>'turn_idx')::int))::uuid;
$$;

-- fin de palabra pool: pasa de ronda (rebaraja) o al podio
create or replace function tr_next_pool(p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_state jsonb;
begin
  select state into v_state from game_sessions where id = p_session_id;
  if (v_state->>'round')::int >= 3 then
    update game_sessions set state = v_state || jsonb_build_object(
      'phase', 'podio', 'phase_ends_at', null) where id = p_session_id;
  else
    update game_sessions set state = v_state || jsonb_build_object(
      'round', (v_state->>'round')::int + 1,
      'remaining', (select jsonb_agg(e order by random()) from jsonb_array_elements(v_state->'pool') e),
      'phase', 'entre', 'phase_ends_at', null) where id = p_session_id;
  end if;
end $$;

create or replace function tr_can_advance(p_session game_sessions)
returns boolean language sql stable as $$
  select p_session.state->>'phase' = 'turno'
     and coalesce((p_session.state->>'phase_ends_at')::timestamptz < now(), false);
$$;

-- arranca el turno del siguiente jugador activo
create or replace function tr_next_turn(p_party_id uuid, p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_state jsonb; v_turn int;
begin
  select state into v_state from game_sessions where id = p_session_id;
  v_turn := next_active_turn(v_state->'turn_order', (v_state->>'turn_idx')::int);
  if v_turn = -1 then perform end_game(p_party_id); return; end if;
  update game_sessions set state = v_state || jsonb_build_object(
    'turn_idx', v_turn, 'phase', 'turno',
    'phase_ends_at', to_jsonb(now() + make_interval(secs => coalesce((v_state->>'timer_s')::int, 60))))
    where id = p_session_id;
end $$;

revoke execute on function tr_actor(jsonb), tr_next_pool(uuid), tr_can_advance(game_sessions),
  tr_next_turn(uuid, uuid) from public, anon, authenticated;

-- ---------- PAREJAS A GRITOS ----------
-- arma la ronda: parejas secretas por palabra (impar = trío en la última)
create or replace function pj_start_round(p_party_id uuid, p_session game_sessions)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_round int := coalesce((v_state->>'round_idx')::int, -1) + 1;
  v_ids uuid[];
  v_np int; v_nw int;
  v_words text[]; v_wids uuid[];
  v_used jsonb := coalesce(v_state->'used', '[]'::jsonb);
  i int;
begin
  if v_round >= coalesce((v_state->>'rounds_total')::int, 3) then
    update game_sessions set state = v_state || jsonb_build_object(
      'phase', 'podio', 'phase_ends_at', null) where id = p_session.id;
    return;
  end if;
  v_ids := (select array_agg(pid order by random()) from unnest(acting_player_ids(p_party_id)) pid);
  v_np := array_length(v_ids, 1);
  if v_np < 4 then perform end_game(p_party_id); return; end if;
  v_nw := v_np / 2; -- impar: el último se une a la última palabra (trío)

  select array_agg(text_es), array_agg(id) into v_words, v_wids from (
    select text_es, id from content_cards
    where game_type = 'parejas-a-gritos' and enabled
      and not (v_used ? id::text)
    order by random() limit v_nw
  ) s;
  if coalesce(array_length(v_words, 1), 0) < v_nw then
    -- pool agotado: se permite repetir
    v_used := '[]'::jsonb;
    select array_agg(text_es), array_agg(id) into v_words, v_wids from (
      select text_es, id from content_cards
      where game_type = 'parejas-a-gritos' and enabled
      order by random() limit v_nw
    ) s;
    if coalesce(array_length(v_words, 1), 0) < v_nw then
      perform end_game(p_party_id); return; -- de verdad no hay cartas
    end if;
  end if;
  for i in 1..v_nw loop
    v_used := v_used || to_jsonb(v_wids[i]::text);
  end loop;

  delete from player_secrets where game_session_id = p_session.id;
  for i in 1..v_np loop
    insert into player_secrets (game_session_id, player_id, payload)
    values (p_session.id, v_ids[i],
      jsonb_build_object('word', v_words[least((i + 1) / 2, v_nw)]));
  end loop;

  update game_sessions set state = v_state || jsonb_build_object(
    'phase', 'gritos', 'round_idx', v_round, 'used', v_used,
    'picks', '{}'::jsonb, 'groups', null,
    'phase_ends_at', to_jsonb(now() + make_interval(secs => coalesce((v_state->>'timer_s')::int, 45))))
    where id = p_session.id;
end $$;

create or replace function pj_can_advance(p_session game_sessions)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
begin
  if coalesce((v_state->>'phase_ends_at')::timestamptz < now(), false) then return true; end if;
  if v_state->>'phase' = 'elegir' then
    return not exists (select 1 from players p
      where p.party_id = p_session.party_id and p.status = 'active'
        and not (v_state->'picks' ? p.id::text));
  end if;
  return false;
end $$;

-- scoring: tu elegido tiene tu palabra +50; si fue mutuo +50 extra
create or replace function pj_reveal(p_session game_sessions)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb;
  v_words jsonb; -- {pid: word}
  r record;
  v_pick text; v_back text;
begin
  select state into v_state from game_sessions where id = p_session.id;
  select jsonb_object_agg(player_id::text, payload->>'word') into v_words
    from player_secrets where game_session_id = p_session.id;

  for r in select key as pid from jsonb_each(v_words) loop
    v_pick := v_state->'picks'->>r.pid;
    if v_pick is not null and v_words->>v_pick = v_words->>r.pid then
      v_state := jsonb_set(v_state, array['scores', r.pid],
        to_jsonb(coalesce((v_state->'scores'->>r.pid)::int, 0) + 50));
      v_back := v_state->'picks'->>v_pick;
      if v_back = r.pid then
        v_state := jsonb_set(v_state, array['scores', r.pid],
          to_jsonb(coalesce((v_state->'scores'->>r.pid)::int, 0) + 50));
      end if;
    end if;
  end loop;

  v_state := v_state || jsonb_build_object(
    'phase', 'reveal', 'phase_ends_at', null,
    'groups', (select coalesce(jsonb_agg(g), '[]') from (
      select jsonb_build_object('word', w.value, 'members',
        (select jsonb_agg(k.key) from jsonb_each_text(v_words) k where k.value = w.value)) as g
      from (select distinct value from jsonb_each_text(v_words)) w) s));
  update game_sessions set state = v_state where id = p_session.id;
end $$;

revoke execute on function pj_start_round(uuid, game_sessions), pj_can_advance(game_sessions),
  pj_reveal(game_sessions) from public, anon, authenticated;

-- ---------- DISPATCHERS (rename 013 → *_013 + wrappers) ----------
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'launch_game_013') then
    alter function launch_game(uuid, text, jsonb) rename to launch_game_013;
    alter function advance_phase(uuid, boolean) rename to advance_phase_013;
    alter function submit_action(uuid, text, jsonb) rename to submit_action_013;
    alter function dev_bot_tick(uuid) rename to dev_bot_tick_013;
  end if;
end $$;

create or replace function launch_game(p_party_id uuid, p_game_type text, p_opts jsonb default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_intensity int; v_n int; v_timer int;
  v_ids uuid[]; v_np int;
  v_pool jsonb; v_card_ids uuid[];
begin
  if p_game_type not in ('tres-rondas', 'parejas-a-gritos') then
    return launch_game_013(p_party_id, p_game_type, p_opts);
  end if;
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  if exists (select 1 from game_sessions where party_id = p_party_id and status = 'active') then
    raise exception 'YA_HAY_JUEGO';
  end if;
  select coalesce((settings->>'intensity')::int, 2) into v_intensity from parties where id = p_party_id;
  v_intensity := least(5, greatest(1, coalesce((p_opts->>'intensity')::int, v_intensity)));
  v_ids := acting_player_ids(p_party_id);
  v_np := array_length(v_ids, 1);

  insert into game_sessions (party_id, game_type, state)
    values (p_party_id, p_game_type, '{}'::jsonb) returning * into v_session;

  if p_game_type = 'tres-rondas' then
    v_n := least(40, greatest(6, coalesce((p_opts->>'n_cards')::int, least(40, 5 * v_np))));
    v_timer := least(180, greatest(15, coalesce((p_opts->>'timer_s')::int, 60)));
    if p_opts ? 'card_ids' then
      v_card_ids := array(select (e#>>'{}')::uuid from jsonb_array_elements(p_opts->'card_ids') e);
    end if;
    if v_card_ids is not null and array_length(v_card_ids, 1) > 0 then
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
      -- equipos alternando el orden barajado
      'teams', (select jsonb_object_agg(pid::text, case when ord % 2 = 0 then 'A' else 'B' end)
                from (select pid, row_number() over () as ord
                      from unnest(v_ids) pid order by random()) t),
      'team_scores', jsonb_build_object('A', 0, 'B', 0),
      'phase', 'entre', 'phase_ends_at', null)
      where id = v_session.id;
  else
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

create or replace function advance_phase(p_party_id uuid, p_force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
begin
  select * into v_session from active_session(p_party_id);
  if v_session.id is not null and v_session.game_type not in ('tres-rondas', 'parejas-a-gritos') then
    perform advance_phase_013(p_party_id, p_force); return;
  end if;
  if p_force then
    if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  elsif not is_member(p_party_id) then
    raise exception 'NO_MIEMBRO';
  end if;
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;

  if v_session.game_type = 'tres-rondas' then
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
  else
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

create or replace function submit_action(p_party_id uuid, p_action text, p_payload jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_me uuid := my_player_id(p_party_id);
  v_state jsonb;
  v_team text;
  v_target uuid;
begin
  select * into v_session from active_session(p_party_id);
  if v_session.id is not null and v_session.game_type not in ('tres-rondas', 'parejas-a-gritos') then
    perform submit_action_013(p_party_id, p_action, p_payload); return;
  end if;
  if v_me is null then raise exception 'NO_MIEMBRO'; end if;
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;
  v_state := v_session.state;

  if v_session.game_type = 'tres-rondas' then
    if v_state->>'phase' <> 'turno' or v_me <> tr_actor(v_state) then
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

  -- parejas-a-gritos
  if p_action = 'pick' and v_state->>'phase' = 'elegir' then
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
end $$;

create or replace function dev_bot_tick(p_party_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  v_bot record;
  v_targets uuid[];
  v_team text;
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then return; end if;
  if v_session.game_type not in ('tres-rondas', 'parejas-a-gritos') then
    perform dev_bot_tick_013(p_party_id); return;
  end if;
  v_state := v_session.state;

  if v_session.game_type = 'tres-rondas' then
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

  -- parejas: bots eligen random en elegir
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
end $$;
