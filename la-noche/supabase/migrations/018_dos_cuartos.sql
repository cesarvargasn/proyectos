-- ============================================================
-- LA NOCHE — Migración 018: DOS CUARTOS Y LA BOMBA (fase 7, 2 de 2)
-- Correr DESPUÉS de 017. NO usa content_cards.
-- ⚠ Solo helpers dc_*: la rama 'dos-cuartos' en dispatchers llega en 019.
--
-- DOS CUARTOS ('dos-cuartos') — Two Rooms and a Boom, 6–20 jugadores.
--   Dos equipos: AZUL (con el PRESIDENTE) y ROJO (con la BOMBA). Los
--   jugadores se separan FÍSICAMENTE en dos cuartos (la app dice cuál).
--   3 rondas sincronizadas: 3:00 / 2:00 / 1:00. En cada cuarto hay un
--   líder (usurpable por voto de mayoría del cuarto). Durante la ronda
--   la gente comparte cartas EN PERSONA (el celular muestra tu carta:
--   solo color o rol completo, 5s). Al final de cada ronda los líderes
--   eligen rehenes (1–4 según conteo) que CRUZAN de cuarto. Tras la
--   ronda 3: si la Bomba quedó con el Presidente → gana ROJO; si no,
--   gana AZUL.
--
--   Rehenes por ronda: ≤10 → 1,1,1 · 11–13 → 2,1,1 · 14–17 → 3,2,1 ·
--   18+ → 4,3,2. Líderes no pueden mandarse a sí mismos.
--
--   LEAK-PROOF: rol en player_secrets. Cuartos/líderes/rehenes son
--   públicos (en persona se ven igual).
--
--   state = { phase reparto|ronda|intercambio|reveal, round 1..3,
--             phase_ends_at, rooms:{pid:1|2}, leaders:{'1','2'},
--             hostages:{'1':[],'2':[]}, h_count, usurp:{pid:target},
--             ready:{}, winner:null|'azul'|'rojo', bomba, presidente }
--   secrets = { role presidente|bomba|azul|rojo }
-- ============================================================

create or replace function dc_role_of(p_session_id uuid, p_pid uuid)
returns text language sql stable security definer set search_path = public as $$
  select payload->>'role' from player_secrets
  where game_session_id = p_session_id and player_id = p_pid;
$$;

-- rehenes que cruzan en la ronda p_round para p_np jugadores
create or replace function dc_h_count(p_np int, p_round int)
returns int language sql immutable as $$
  select case
    when p_np <= 10 then 1
    when p_np <= 13 then (array[2,1,1])[p_round]
    when p_np <= 17 then (array[3,2,1])[p_round]
    else (array[4,3,2])[p_round]
  end;
$$;

create or replace function dc_can_advance(p_session game_sessions)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_state jsonb := p_session.state;
begin
  if v_state->>'phase' = 'ronda' then
    return coalesce((v_state->>'phase_ends_at')::timestamptz < now(), false);
  end if;
  if v_state->>'phase' = 'reparto' then
    return not exists (select 1 from players p
      where p.party_id = p_session.party_id and p.status = 'active'
        and exists (select 1 from player_secrets s where s.game_session_id = p_session.id and s.player_id = p.id)
        and not (v_state->'ready' ? p.id::text));
  end if;
  return false;
end $$;

-- si el líder de un cuarto se fue / cruzó, elige otro al azar del cuarto
create or replace function dc_fix_leaders(p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  r int;
  v_lid uuid;
  v_new uuid;
begin
  select * into v_session from game_sessions where id = p_session_id;
  v_state := v_session.state;
  for r in 1..2 loop
    v_lid := (v_state->'leaders'->>(r::text))::uuid;
    if v_lid is null
       or coalesce((v_state->'rooms'->>(v_lid::text))::int, 0) <> r
       or not exists (select 1 from players where id = v_lid and status = 'active') then
      select p.id into v_new from players p
      where p.party_id = v_session.party_id and p.status = 'active'
        and (v_state->'rooms'->>(p.id::text))::int = r
      order by random() limit 1;
      v_state := jsonb_set(v_state, array['leaders', r::text], coalesce(to_jsonb(v_new::text), 'null'::jsonb));
    end if;
  end loop;
  update game_sessions set state = v_state where id = p_session_id;
end $$;

-- entra a la ronda p_round con su timer (3:00 / 2:00 / 1:00)
create or replace function dc_enter_ronda(p_session_id uuid, p_round int)
returns void language plpgsql security definer set search_path = public as $$
declare v_np int;
begin
  select count(*) into v_np from player_secrets where game_session_id = p_session_id;
  update game_sessions set state = state || jsonb_build_object(
    'phase', 'ronda', 'round', p_round,
    'h_count', dc_h_count(v_np, p_round),
    'hostages', jsonb_build_object('1', '[]'::jsonb, '2', '[]'::jsonb),
    'usurp', '{}'::jsonb,
    'phase_ends_at', to_jsonb(now() + make_interval(secs => (array[180,120,60])[p_round])))
    where id = p_session_id;
  perform dc_fix_leaders(p_session_id);
end $$;

-- fin de ronda: completa rehenes que falten (random, sin líderes)
create or replace function dc_enter_intercambio(p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  r int;
  v_need int;
  v_have jsonb;
  v_fill uuid[];
begin
  select * into v_session from game_sessions where id = p_session_id;
  v_state := v_session.state;
  v_need := (v_state->>'h_count')::int;
  for r in 1..2 loop
    v_have := coalesce(v_state->'hostages'->(r::text), '[]'::jsonb);
    if jsonb_array_length(v_have) < v_need then
      v_fill := array(select p.id from players p
        where p.party_id = v_session.party_id and p.status = 'active'
          and (v_state->'rooms'->>(p.id::text))::int = r
          and p.id::text <> coalesce(v_state->'leaders'->>(r::text), '')
          and not (v_have @> to_jsonb(p.id::text))
        order by random() limit (v_need - jsonb_array_length(v_have)));
      v_have := v_have || coalesce((select jsonb_agg(to_jsonb(pid::text)) from unnest(v_fill) pid), '[]'::jsonb);
      v_state := jsonb_set(v_state, array['hostages', r::text], v_have);
    end if;
  end loop;
  v_state := v_state || jsonb_build_object('phase', 'intercambio', 'phase_ends_at', null);
  update game_sessions set state = v_state where id = p_session_id;
end $$;

-- aplica el cruce de rehenes y pasa a la siguiente ronda o al reveal
create or replace function dc_apply_swap(p_party_id uuid, p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  e record;
  v_pres uuid;
  v_bomba uuid;
begin
  select * into v_session from game_sessions where id = p_session_id;
  v_state := v_session.state;
  for e in select value as pid from jsonb_array_elements_text(v_state->'hostages'->'1') loop
    v_state := jsonb_set(v_state, array['rooms', e.pid], '2');
  end loop;
  for e in select value as pid from jsonb_array_elements_text(v_state->'hostages'->'2') loop
    v_state := jsonb_set(v_state, array['rooms', e.pid], '1');
  end loop;

  if (v_state->>'round')::int >= 3 then
    select player_id into v_pres from player_secrets
      where game_session_id = p_session_id and payload->>'role' = 'presidente';
    select player_id into v_bomba from player_secrets
      where game_session_id = p_session_id and payload->>'role' = 'bomba';
    v_state := v_state || jsonb_build_object(
      'phase', 'reveal', 'phase_ends_at', null,
      'presidente', v_pres, 'bomba', v_bomba,
      'winner', case when v_state->'rooms'->>(v_pres::text) = v_state->'rooms'->>(v_bomba::text)
                     then 'rojo' else 'azul' end);
    update game_sessions set state = v_state where id = p_session_id;
  else
    update game_sessions set state = v_state where id = p_session_id;
    perform dc_enter_ronda(p_session_id, (v_state->>'round')::int + 1);
  end if;
end $$;

-- ---------- LAUNCH / ADVANCE / SUBMIT / BOTS ----------

create or replace function dc_launch(p_party_id uuid, p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_ids uuid[];
  v_np int;
  v_roles text[] := array[]::text[];
  v_azules int;
  v_pid uuid;
  i int := 0;
begin
  v_ids := (select array_agg(pid order by random()) from unnest(acting_player_ids(p_party_id)) pid);
  v_np := coalesce(array_length(v_ids, 1), 0);
  if v_np < 6 then
    delete from game_sessions where id = p_session_id;
    raise exception 'FALTAN_JUGADORES';
  end if;

  -- presidente cuenta como azul; bomba como rojo; equipos parejos
  v_azules := v_np / 2 + (v_np % 2); -- azul se queda el impar
  v_roles := array['presidente', 'bomba'];
  for i in 2..v_azules loop v_roles := v_roles || 'azul'::text; end loop;
  while array_length(v_roles, 1) < v_np loop v_roles := v_roles || 'rojo'::text; end loop;

  delete from player_secrets where game_session_id = p_session_id;
  i := 0;
  foreach v_pid in array v_ids loop
    i := i + 1;
    insert into player_secrets (game_session_id, player_id, payload)
    values (p_session_id, v_pid, jsonb_build_object('role', v_roles[i]));
  end loop;

  -- cuartos: mitad y mitad sobre OTRO barajado (roles ≠ cuartos)
  update game_sessions set state = jsonb_build_object(
    'phase', 'reparto', 'phase_ends_at', null, 'round', 0,
    'rooms', (select jsonb_object_agg(pid::text, case when ord <= (v_np + 1) / 2 then 1 else 2 end)
              from (select pid, row_number() over (order by random()) as ord
                    from unnest(v_ids) pid) t),
    'leaders', jsonb_build_object('1', null, '2', null),
    'hostages', jsonb_build_object('1', '[]'::jsonb, '2', '[]'::jsonb),
    'h_count', dc_h_count(v_np, 1), 'usurp', '{}'::jsonb,
    'ready', '{}'::jsonb, 'winner', null, 'bomba', null, 'presidente', null)
    where id = p_session_id;
  perform dc_fix_leaders(p_session_id);
end $$;

create or replace function dc_advance(p_party_id uuid, p_force boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_phase text;
begin
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;
  v_phase := v_session.state->>'phase';

  if v_phase = 'reparto' then
    if not p_force and not dc_can_advance(v_session) then return; end if;
    perform dc_enter_ronda(v_session.id, 1);
  elsif v_phase = 'ronda' then
    if not p_force and not dc_can_advance(v_session) then return; end if;
    perform dc_enter_intercambio(v_session.id);
  elsif v_phase = 'intercambio' then
    if not p_force then return; end if; -- el host confirma el cruce físico
    perform dc_apply_swap(p_party_id, v_session.id);
  elsif v_phase = 'reveal' then
    if p_force then perform end_game(p_party_id); end if;
  end if;
end $$;

create or replace function dc_submit(p_party_id uuid, p_me uuid, p_action text, p_payload jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  v_phase text;
  v_room int;
  v_pids uuid[];
  v_target uuid;
  v_votes int;
  v_members int;
begin
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;
  v_state := v_session.state;
  v_phase := v_state->>'phase';

  if p_action = 'ready' and v_phase = 'reparto' then
    if dc_role_of(v_session.id, p_me) is null then raise exception 'NO_REPARTIDO'; end if;
    update game_sessions set state = jsonb_set(state, array['ready', p_me::text], 'true')
      where id = v_session.id;
    select * into v_session from game_sessions where id = v_session.id;
    if v_session.status = 'active' and dc_can_advance(v_session) then
      perform advance_phase(p_party_id, false);
    end if;
    return;
  end if;

  if p_action = 'hostages' and v_phase = 'ronda' then
    v_room := (v_state->'rooms'->>(p_me::text))::int;
    if v_state->'leaders'->>(v_room::text) <> p_me::text then raise exception 'NO_ERES_EL_LIDER'; end if;
    v_pids := array(select distinct (e#>>'{}')::uuid from jsonb_array_elements(p_payload->'pids') e);
    if coalesce(array_length(v_pids, 1), 0) > (v_state->>'h_count')::int then
      raise exception 'DEMASIADOS_REHENES';
    end if;
    if exists (select 1 from unnest(v_pids) pid
               where pid = p_me
                  or coalesce((v_state->'rooms'->>(pid::text))::int, 0) <> v_room
                  or not exists (select 1 from players where id = pid and status = 'active')) then
      raise exception 'REHEN_INVALIDO'; -- de tu cuarto, activos, y tú no
    end if;
    update game_sessions set state = jsonb_set(state, array['hostages', v_room::text],
      coalesce((select jsonb_agg(to_jsonb(pid::text)) from unnest(v_pids) pid), '[]'::jsonb))
      where id = v_session.id;
    return;
  end if;

  if p_action = 'usurpar' and v_phase = 'ronda' then
    v_room := (v_state->'rooms'->>(p_me::text))::int;
    v_target := (p_payload->>'target')::uuid;
    if v_target is null or coalesce((v_state->'rooms'->>(v_target::text))::int, 0) <> v_room then
      raise exception 'OBJETIVO_INVALIDO';
    end if;
    if v_state->'leaders'->>(v_room::text) = v_target::text then raise exception 'YA_ES_LIDER'; end if;
    v_state := jsonb_set(v_state, array['usurp', p_me::text], to_jsonb(v_target::text));

    -- mayoría del cuarto → nuevo líder (y se limpian los votos del cuarto)
    select count(*) into v_votes from jsonb_each_text(v_state->'usurp') e
      where e.value = v_target::text
        and (v_state->'rooms'->>(e.key))::int = v_room;
    select count(*) into v_members from players p
      where p.party_id = p_party_id and p.status = 'active'
        and (v_state->'rooms'->>(p.id::text))::int = v_room;
    if v_votes * 2 > v_members then
      v_state := jsonb_set(v_state, array['leaders', v_room::text], to_jsonb(v_target::text));
      v_state := jsonb_set(v_state, '{usurp}', coalesce((
        select jsonb_object_agg(e.key, e.value) from jsonb_each(v_state->'usurp') e
        where (v_state->'rooms'->>(e.key))::int <> v_room), '{}'::jsonb));
      -- si el líder saliente tenía rehenes elegidos, se respetan (salvo el nuevo líder)
      v_state := jsonb_set(v_state, array['hostages', v_room::text], coalesce((
        select jsonb_agg(e) from jsonb_array_elements(v_state->'hostages'->(v_room::text)) e
        where e #>> '{}' <> v_target::text), '[]'::jsonb));
    end if;
    update game_sessions set state = v_state where id = v_session.id;
    return;
  end if;

  raise exception 'ACCION_INVALIDA';
end $$;

create or replace function dc_bot_tick(p_party_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  v_bot record;
  r int;
  v_lid uuid;
  v_pids uuid[];
begin
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then return; end if;
  v_state := v_session.state;

  if v_state->>'phase' = 'reparto' then
    for v_bot in select p.id from players p
                 where p.party_id = p_party_id and p.is_bot and p.status = 'active'
                   and exists (select 1 from player_secrets s
                               where s.game_session_id = v_session.id and s.player_id = p.id)
                   and not (v_state->'ready' ? p.id::text) loop
      update game_sessions set state = jsonb_set(state, array['ready', v_bot.id::text], 'true')
        where id = v_session.id;
    end loop;
    select * into v_session from game_sessions where id = v_session.id;
    if v_session.status = 'active' and dc_can_advance(v_session) then
      perform advance_phase(p_party_id, false);
    end if;
    return;
  end if;

  if v_state->>'phase' = 'ronda' then
    -- líder bot: si aún no eligió rehenes completos, elige random
    for r in 1..2 loop
      v_lid := (v_state->'leaders'->>(r::text))::uuid;
      if v_lid is not null
         and exists (select 1 from players where id = v_lid and is_bot and status = 'active')
         and jsonb_array_length(coalesce(v_state->'hostages'->(r::text), '[]'::jsonb)) < (v_state->>'h_count')::int then
        v_pids := array(select p.id from players p
          where p.party_id = p_party_id and p.status = 'active'
            and (v_state->'rooms'->>(p.id::text))::int = r and p.id <> v_lid
          order by random() limit (v_state->>'h_count')::int);
        update game_sessions set state = jsonb_set(state, array['hostages', r::text],
          coalesce((select jsonb_agg(to_jsonb(pid::text)) from unnest(v_pids) pid), '[]'::jsonb))
          where id = v_session.id;
        v_state := (select state from game_sessions where id = v_session.id);
      end if;
    end loop;
    select * into v_session from game_sessions where id = v_session.id;
    if v_session.status = 'active' and dc_can_advance(v_session) then
      perform advance_phase(p_party_id, false);
    end if;
  end if;
end $$;

revoke execute on function
  dc_role_of(uuid, uuid), dc_h_count(int, int), dc_can_advance(game_sessions),
  dc_fix_leaders(uuid), dc_enter_ronda(uuid, int), dc_enter_intercambio(uuid),
  dc_apply_swap(uuid, uuid), dc_launch(uuid, uuid), dc_advance(uuid, boolean),
  dc_submit(uuid, uuid, text, jsonb), dc_bot_tick(uuid)
from public, anon, authenticated;
