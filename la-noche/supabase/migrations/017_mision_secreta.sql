-- ============================================================
-- LA NOCHE — Migración 017: MISIÓN SECRETA (fase 7, 1 de 2)
-- Correr DESPUÉS de 016. NO usa content_cards.
-- ⚠ Solo helpers ms_*: la rama 'mision-secreta' en dispatchers llega en 019.
--
-- MISIÓN SECRETA ('mision-secreta') — estilo Avalon, 5–10 jugadores.
--   Buenos vs Malos. Malos: 5-6p=2, 7-9p=3, 10p=4. Merlín (bueno, ve a
--   los malos) y Asesino (malo) SIEMPRE en juego. Los malos se conocen.
--   5 misiones; tamaños estándar por conteo; con 7+ la misión 4 (idx 3)
--   necesita DOS sabotajes para fracasar.
--   Líder rota → arma equipo (espejo EN VIVO en todas las pantallas) →
--   voto público simultáneo (se revela junto; mayoría estricta aprueba;
--   timeout = rechazo) → 5 rechazos seguidos = ganan malos → misión:
--   los del equipo juegan ÉXITO/SABOTAJE en secreto (los buenos SOLO
--   pueden éxito — el server lo fuerza) → resultado (solo cuenta de
--   sabotajes). 3 éxitos → el Asesino intenta matar a Merlín (si
--   acierta, ganan los malos). 3 fracasos = malos.
--   Historial público de propuestas y votos en state.proposals.
--
--   LEAK-PROOF: rol y lista de malos en player_secrets; el voto de
--   equipo y el de misión viajan por secrets y solo se agregan al state
--   ya resueltos (voto por jugador, misión solo el conteo).
--
--   state = { phase reparto|equipo|voto_equipo|voto_reveal|mision|
--             resultado|asesinato|fin, phase_ends_at, mission_no, sizes,
--             double_idx, lider_idx, turn_order, team_sel, team, ready,
--             acted, votes_pub, aprobada, rejects_row, results,
--             fails, proposals, asesinado, winner, motivo, roles_pub }
--   secrets = { role merlin|leal|asesino|esbirro, evil?:names, tvote?, mvote? }
-- ============================================================

create or replace function ms_role_of(p_session_id uuid, p_pid uuid)
returns text language sql stable security definer set search_path = public as $$
  select payload->>'role' from player_secrets
  where game_session_id = p_session_id and player_id = p_pid;
$$;

create or replace function ms_lider(p_state jsonb)
returns uuid language sql immutable as $$
  select (p_state->'turn_order'->>((p_state->>'lider_idx')::int))::uuid;
$$;

create or replace function ms_can_advance(p_session game_sessions)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_phase text := v_state->>'phase';
begin
  if coalesce((v_state->>'phase_ends_at')::timestamptz < now(), false)
     and v_phase in ('voto_equipo', 'mision', 'asesinato') then
    return true;
  end if;
  if v_phase = 'reparto' then
    return not exists (select 1 from players p
      where p.party_id = p_session.party_id and p.status = 'active'
        and exists (select 1 from player_secrets s where s.game_session_id = p_session.id and s.player_id = p.id)
        and not (v_state->'ready' ? p.id::text));
  elsif v_phase = 'voto_equipo' then
    return not exists (select 1 from players p
      where p.party_id = p_session.party_id and p.status = 'active'
        and exists (select 1 from player_secrets s where s.game_session_id = p_session.id and s.player_id = p.id)
        and not (v_state->'acted' ? p.id::text));
  elsif v_phase = 'mision' then
    return not exists (select 1 from jsonb_array_elements_text(v_state->'team') t
      join players p on p.id = t.value::uuid
      where p.status = 'active' and not (v_state->'acted' ? t.value));
  end if;
  return false;
end $$;

-- entra a armar equipo (limpia lo del ciclo anterior)
create or replace function ms_enter_equipo(p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update player_secrets set payload = payload - 'tvote' - 'mvote'
    where game_session_id = p_session_id;
  update game_sessions set state = state || jsonb_build_object(
    'phase', 'equipo', 'phase_ends_at', null,
    'team_sel', '[]'::jsonb, 'team', '[]'::jsonb,
    'acted', '{}'::jsonb, 'votes_pub', null, 'aprobada', null, 'fails', null)
    where id = p_session_id;
end $$;

create or replace function ms_rotate_lider(p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_state jsonb;
begin
  select state into v_state from game_sessions where id = p_session_id;
  update game_sessions set state = jsonb_set(state, '{lider_idx}',
    to_jsonb(next_active_turn(v_state->'turn_order', (v_state->>'lider_idx')::int)))
    where id = p_session_id;
end $$;

create or replace function ms_finish(p_session_id uuid, p_winner text, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update game_sessions set state = state || jsonb_build_object(
    'phase', 'fin', 'phase_ends_at', null, 'winner', p_winner, 'motivo', p_motivo,
    'roles_pub', (select jsonb_object_agg(player_id::text, payload->>'role')
                  from player_secrets where game_session_id = p_session_id))
    where id = p_session_id;
end $$;

-- cierra el voto de equipo: revela votos y decide (timeout = rechazo)
create or replace function ms_after_tvote(p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  v_votes jsonb;
  v_si int;
  v_no int;
  v_aprobada boolean;
begin
  select * into v_session from game_sessions where id = p_session_id;
  v_state := v_session.state;

  select jsonb_object_agg(p.id::text, coalesce((s.payload->>'tvote')::boolean, false)),
         count(*) filter (where coalesce((s.payload->>'tvote')::boolean, false)),
         count(*) filter (where not coalesce((s.payload->>'tvote')::boolean, false))
    into v_votes, v_si, v_no
  from players p
  join player_secrets s on s.player_id = p.id and s.game_session_id = p_session_id
  where p.party_id = v_session.party_id and p.status = 'active';

  v_aprobada := v_si > v_no;
  v_state := v_state || jsonb_build_object(
    'phase', 'voto_reveal', 'phase_ends_at', null,
    'votes_pub', v_votes, 'aprobada', v_aprobada,
    'proposals', (v_state->'proposals') || jsonb_build_object(
      'm', (v_state->>'mission_no')::int + 1, 'lider', ms_lider(v_state),
      'team', v_state->'team', 'votes', v_votes, 'aprobada', v_aprobada));
  update game_sessions set state = v_state where id = p_session_id;
end $$;

-- cierra la misión: cuenta sabotajes (solo el conteo se hace público)
create or replace function ms_after_mission(p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  v_fails int;
  v_needed int;
  v_exito boolean;
begin
  select * into v_session from game_sessions where id = p_session_id;
  v_state := v_session.state;

  select count(*) into v_fails
  from jsonb_array_elements_text(v_state->'team') t
  join player_secrets s on s.player_id = t.value::uuid and s.game_session_id = p_session_id
  where (s.payload->>'mvote')::boolean is false; -- ausencia/timeout = éxito

  v_needed := case when (v_state->>'mission_no')::int = (v_state->>'double_idx')::int then 2 else 1 end;
  v_exito := v_fails < v_needed;

  update game_sessions set state = v_state || jsonb_build_object(
    'phase', 'resultado', 'phase_ends_at', null,
    'fails', v_fails, 'rejects_row', 0,
    'results', (v_state->'results') || to_jsonb(v_exito))
    where id = p_session_id;
end $$;

-- ---------- ACCIONES ----------

create or replace function ms_do_tvote(p_session_id uuid, p_pid uuid, p_approve boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  update player_secrets set payload = payload || jsonb_build_object('tvote', p_approve)
    where game_session_id = p_session_id and player_id = p_pid;
  if not found then raise exception 'NO_REPARTIDO'; end if;
  update game_sessions set state = jsonb_set(state, array['acted', p_pid::text], 'true')
    where id = p_session_id;
end $$;

create or replace function ms_do_mvote(p_session_id uuid, p_pid uuid, p_exito boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_role text := ms_role_of(p_session_id, p_pid);
begin
  -- los buenos NO pueden sabotear: el server lo fuerza
  if v_role in ('merlin', 'leal') then p_exito := true; end if;
  update player_secrets set payload = payload || jsonb_build_object('mvote', p_exito)
    where game_session_id = p_session_id and player_id = p_pid;
  update game_sessions set state = jsonb_set(state, array['acted', p_pid::text], 'true')
    where id = p_session_id;
end $$;

-- ---------- LAUNCH / ADVANCE / SUBMIT / BOTS ----------

create or replace function ms_launch(p_party_id uuid, p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_ids uuid[];
  v_np int;
  v_evil int;
  v_roles text[];
  v_evil_names text;
  v_sizes jsonb;
  v_pid uuid;
  i int := 0;
begin
  v_ids := (select array_agg(pid order by random()) from unnest(acting_player_ids(p_party_id)) pid);
  v_np := coalesce(array_length(v_ids, 1), 0);
  if v_np < 5 or v_np > 10 then
    delete from game_sessions where id = p_session_id;
    raise exception 'FALTAN_JUGADORES'; -- 5–10 exactos
  end if;

  v_evil := case when v_np <= 6 then 2 when v_np <= 9 then 3 else 4 end;
  v_roles := array['merlin', 'asesino'];
  for i in 2..v_evil loop v_roles := v_roles || 'esbirro'::text; end loop;
  while array_length(v_roles, 1) < v_np loop v_roles := v_roles || 'leal'::text; end loop;

  v_sizes := case v_np
    when 5 then '[2,3,2,3,3]'::jsonb
    when 6 then '[2,3,4,3,4]'::jsonb
    when 7 then '[2,3,3,4,4]'::jsonb
    else '[3,4,4,5,5]'::jsonb end;

  delete from player_secrets where game_session_id = p_session_id;
  i := 0;
  foreach v_pid in array v_ids loop
    i := i + 1;
    insert into player_secrets (game_session_id, player_id, payload)
    values (p_session_id, v_pid, jsonb_build_object('role', v_roles[i]));
  end loop;

  -- los malos se conocen; Merlín también los ve
  select string_agg(p.name, ', ') into v_evil_names
  from player_secrets s join players p on p.id = s.player_id
  where s.game_session_id = p_session_id and s.payload->>'role' in ('asesino', 'esbirro');
  update player_secrets set payload = payload || jsonb_build_object('evil', v_evil_names)
    where game_session_id = p_session_id and payload->>'role' in ('asesino', 'esbirro', 'merlin');

  update game_sessions set state = jsonb_build_object(
    'phase', 'reparto', 'phase_ends_at', null,
    'mission_no', 0, 'sizes', v_sizes,
    'double_idx', case when v_np >= 7 then 3 else -1 end,
    'lider_idx', 0,
    'turn_order', (select jsonb_agg(to_jsonb(pid) order by random()) from unnest(v_ids) pid),
    'team_sel', '[]'::jsonb, 'team', '[]'::jsonb,
    'ready', '{}'::jsonb, 'acted', '{}'::jsonb,
    'votes_pub', null, 'aprobada', null, 'rejects_row', 0,
    'results', '[]'::jsonb, 'fails', null, 'proposals', '[]'::jsonb,
    'asesinado', null, 'winner', null, 'motivo', null, 'roles_pub', null,
    'comp', jsonb_build_object('malos', v_evil, 'buenos', v_np - v_evil))
    where id = p_session_id;
end $$;

create or replace function ms_advance(p_party_id uuid, p_force boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_phase text;
  v_wins int;
  v_losses int;
begin
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;
  v_phase := v_session.state->>'phase';

  if v_phase = 'reparto' then
    if not p_force and not ms_can_advance(v_session) then return; end if;
    perform ms_enter_equipo(v_session.id);

  elsif v_phase = 'equipo' then
    if not p_force then return; end if; -- host salta al líder dormido
    perform ms_rotate_lider(v_session.id);
    perform ms_enter_equipo(v_session.id);

  elsif v_phase = 'voto_equipo' then
    if not p_force and not ms_can_advance(v_session) then return; end if;
    perform ms_after_tvote(v_session.id);

  elsif v_phase = 'voto_reveal' then
    if not p_force then return; end if;
    if coalesce((v_session.state->>'aprobada')::boolean, false) then
      update player_secrets set payload = payload - 'mvote'
        where game_session_id = v_session.id;
      update game_sessions set state = state || jsonb_build_object(
        'phase', 'mision', 'acted', '{}'::jsonb,
        'phase_ends_at', to_jsonb(now() + interval '30 seconds'))
        where id = v_session.id;
    else
      if coalesce((v_session.state->>'rejects_row')::int, 0) + 1 >= 5 then
        update game_sessions set state = state || jsonb_build_object('rejects_row', 5)
          where id = v_session.id;
        perform ms_finish(v_session.id, 'malos', 'rechazos');
      else
        update game_sessions set state = state || jsonb_build_object(
          'rejects_row', coalesce((v_session.state->>'rejects_row')::int, 0) + 1)
          where id = v_session.id;
        perform ms_rotate_lider(v_session.id);
        perform ms_enter_equipo(v_session.id);
      end if;
    end if;

  elsif v_phase = 'mision' then
    if not p_force and not ms_can_advance(v_session) then return; end if;
    perform ms_after_mission(v_session.id);

  elsif v_phase = 'resultado' then
    if not p_force then return; end if;
    select count(*) filter (where (e#>>'{}')::boolean),
           count(*) filter (where not (e#>>'{}')::boolean)
      into v_wins, v_losses
    from jsonb_array_elements(v_session.state->'results') e;
    if v_wins >= 3 then
      update game_sessions set state = state || jsonb_build_object(
        'phase', 'asesinato', 'phase_ends_at', to_jsonb(now() + interval '60 seconds'))
        where id = v_session.id;
    elsif v_losses >= 3 then
      perform ms_finish(v_session.id, 'malos', 'misiones');
    else
      update game_sessions set state = state || jsonb_build_object(
        'mission_no', (v_session.state->>'mission_no')::int + 1)
        where id = v_session.id;
      perform ms_rotate_lider(v_session.id);
      perform ms_enter_equipo(v_session.id);
    end if;

  elsif v_phase = 'asesinato' then
    -- timeout o host: el asesino dudó demasiado → ganan los buenos
    if not p_force and not ms_can_advance(v_session) then return; end if;
    perform ms_finish(v_session.id, 'buenos', 'asesino_dudo');

  elsif v_phase = 'fin' then
    if p_force then perform end_game(p_party_id); end if;
  end if;
end $$;

create or replace function ms_submit(p_party_id uuid, p_me uuid, p_action text, p_payload jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  v_phase text;
  v_pids uuid[];
  v_size int;
  v_target uuid;
begin
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;
  v_state := v_session.state;
  v_phase := v_state->>'phase';

  if p_action = 'ready' and v_phase = 'reparto' then
    if ms_role_of(v_session.id, p_me) is null then raise exception 'NO_REPARTIDO'; end if;
    update game_sessions set state = jsonb_set(state, array['ready', p_me::text], 'true')
      where id = v_session.id;

  elsif p_action = 'team_set' and v_phase = 'equipo' then
    if p_me <> ms_lider(v_state) then raise exception 'NO_ERES_EL_LIDER'; end if;
    v_size := (v_state->'sizes'->>((v_state->>'mission_no')::int))::int;
    v_pids := array(select distinct (e#>>'{}')::uuid from jsonb_array_elements(p_payload->'pids') e);
    if coalesce(array_length(v_pids, 1), 0) > v_size then raise exception 'EQUIPO_MUY_GRANDE'; end if;
    if exists (select 1 from unnest(v_pids) pid
               where ms_role_of(v_session.id, pid) is null
                  or not exists (select 1 from players where id = pid and status = 'active')) then
      raise exception 'EQUIPO_INVALIDO';
    end if;
    -- espejo en vivo: todos ven la selección del líder al instante
    update game_sessions set state = jsonb_set(state, '{team_sel}',
      coalesce((select jsonb_agg(to_jsonb(pid::text)) from unnest(v_pids) pid), '[]'::jsonb))
      where id = v_session.id;
    return;

  elsif p_action = 'team_confirm' and v_phase = 'equipo' then
    if p_me <> ms_lider(v_state) then raise exception 'NO_ERES_EL_LIDER'; end if;
    v_size := (v_state->'sizes'->>((v_state->>'mission_no')::int))::int;
    if jsonb_array_length(coalesce(v_state->'team_sel', '[]'::jsonb)) <> v_size then
      raise exception 'EQUIPO_INCOMPLETO';
    end if;
    update player_secrets set payload = payload - 'tvote' where game_session_id = v_session.id;
    update game_sessions set state = state || jsonb_build_object(
      'team', v_state->'team_sel', 'phase', 'voto_equipo', 'acted', '{}'::jsonb,
      'phase_ends_at', to_jsonb(now() + interval '30 seconds'))
      where id = v_session.id;
    return;

  elsif p_action = 'tvote' and v_phase = 'voto_equipo' then
    perform ms_do_tvote(v_session.id, p_me, coalesce((p_payload->>'approve')::boolean, false));

  elsif p_action = 'mvote' and v_phase = 'mision' then
    if not (v_state->'team' @> to_jsonb(p_me::text)) then raise exception 'NO_ESTAS_EN_LA_MISION'; end if;
    perform ms_do_mvote(v_session.id, p_me, coalesce((p_payload->>'exito')::boolean, true));

  elsif p_action = 'kill' and v_phase = 'asesinato' then
    if ms_role_of(v_session.id, p_me) <> 'asesino' then raise exception 'NO_ERES_EL_ASESINO'; end if;
    v_target := (p_payload->>'target')::uuid;
    if v_target is null or ms_role_of(v_session.id, v_target) is null then
      raise exception 'OBJETIVO_INVALIDO';
    end if;
    update game_sessions set state = state || jsonb_build_object('asesinado', v_target)
      where id = v_session.id;
    if ms_role_of(v_session.id, v_target) = 'merlin' then
      perform ms_finish(v_session.id, 'malos', 'asesinato');
    else
      perform ms_finish(v_session.id, 'buenos', 'merlin_oculto');
    end if;
    return;

  else
    raise exception 'ACCION_INVALIDA';
  end if;

  select * into v_session from game_sessions where id = v_session.id;
  if v_session.status = 'active' and ms_can_advance(v_session) then
    perform advance_phase(p_party_id, false);
  end if;
end $$;

create or replace function ms_bot_tick(p_party_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  v_phase text;
  v_bot record;
  v_lider uuid;
  v_size int;
  v_role text;
  v_targets uuid[];
begin
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then return; end if;
  v_state := v_session.state;
  v_phase := v_state->>'phase';

  if v_phase = 'equipo' then
    v_lider := ms_lider(v_state);
    if exists (select 1 from players where id = v_lider and is_bot and status = 'active') then
      v_size := (v_state->'sizes'->>((v_state->>'mission_no')::int))::int;
      v_targets := array(select s.player_id from player_secrets s
        join players p on p.id = s.player_id
        where s.game_session_id = v_session.id and p.status = 'active'
        order by random() limit v_size);
      update game_sessions set state = jsonb_set(state, '{team_sel}',
        (select jsonb_agg(to_jsonb(pid::text)) from unnest(v_targets) pid))
        where id = v_session.id;
      update player_secrets set payload = payload - 'tvote' where game_session_id = v_session.id;
      update game_sessions set state = state || jsonb_build_object(
        'team', (select jsonb_agg(to_jsonb(pid::text)) from unnest(v_targets) pid),
        'phase', 'voto_equipo', 'acted', '{}'::jsonb,
        'phase_ends_at', to_jsonb(now() + interval '30 seconds'))
        where id = v_session.id;
    end if;
    return;
  end if;

  if v_phase = 'asesinato' then
    if exists (select 1 from player_secrets s join players p on p.id = s.player_id
               where s.game_session_id = v_session.id and s.payload->>'role' = 'asesino'
                 and p.is_bot and p.status = 'active') then
      v_targets := array(select s.player_id from player_secrets s
        where s.game_session_id = v_session.id
          and s.payload->>'role' in ('merlin', 'leal'));
      perform ms_submit(p_party_id,
        (select s.player_id from player_secrets s where s.game_session_id = v_session.id
          and s.payload->>'role' = 'asesino'),
        'kill', jsonb_build_object('target',
          v_targets[1 + floor(random()*array_length(v_targets,1))::int]));
    end if;
    return;
  end if;

  for v_bot in select p.id from players p
               where p.party_id = p_party_id and p.is_bot and p.status = 'active'
                 and exists (select 1 from player_secrets s
                             where s.game_session_id = v_session.id and s.player_id = p.id) loop
    v_state := (select state from game_sessions where id = v_session.id);

    if v_phase = 'reparto' and not (v_state->'ready' ? v_bot.id::text) then
      update game_sessions set state = jsonb_set(state, array['ready', v_bot.id::text], 'true')
        where id = v_session.id;
    elsif v_phase = 'voto_equipo' and not (v_state->'acted' ? v_bot.id::text) then
      perform ms_do_tvote(v_session.id, v_bot.id, random() < 0.7);
    elsif v_phase = 'mision' and (v_state->'team' @> to_jsonb(v_bot.id::text))
          and not (v_state->'acted' ? v_bot.id::text) then
      v_role := ms_role_of(v_session.id, v_bot.id);
      perform ms_do_mvote(v_session.id, v_bot.id,
        case when v_role in ('asesino', 'esbirro') then random() >= 0.4 else true end);
    end if;
  end loop;

  select * into v_session from game_sessions where id = v_session.id;
  if v_session.status = 'active' and ms_can_advance(v_session) then
    perform advance_phase(p_party_id, false);
  end if;
end $$;

revoke execute on function
  ms_role_of(uuid, uuid), ms_lider(jsonb), ms_can_advance(game_sessions),
  ms_enter_equipo(uuid), ms_rotate_lider(uuid), ms_finish(uuid, text, text),
  ms_after_tvote(uuid), ms_after_mission(uuid),
  ms_do_tvote(uuid, uuid, boolean), ms_do_mvote(uuid, uuid, boolean),
  ms_launch(uuid, uuid), ms_advance(uuid, boolean),
  ms_submit(uuid, uuid, text, jsonb), ms_bot_tick(uuid)
from public, anon, authenticated;
