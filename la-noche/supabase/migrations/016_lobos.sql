-- ============================================================
-- LA NOCHE — Migración 016: LOBOS (fase 6, el juego insignia)
-- Correr DESPUÉS de 015. NO usa content_cards (los roles son el mazo).
-- ⚠ Esta migración solo crea helpers lb_*: los dispatchers ganan la
-- rama 'lobos' en la migración 019 (correr 016→017→018→019 juntas).
--
-- LOBOS ('lobos') — Werewolf 6–20 jugadores. Roles por conteo:
--   6–7: 2 Lobos + Vidente + Protector (resto Aldeanos)
--   8–11: 3 Lobos + Vidente + Protector + Bruja
--   12–20: 4 Lobos + Vidente + Protector + Bruja + Cazador
--
--   LEAK-PROOF: rol (y datos de rol) SOLO en player_secrets. Los lobos
--   ven los nombres de su manada; la Bruja ve a la víctima al entrar su
--   fase; la Vidente acumula visiones en su payload.
--
--   ANTI-TELL: en cada fase de noche TODOS los vivos tocan a un jugador
--   (los que no tienen rol nocturno hacen un tap de mentira). La fase
--   avanza cuando todos actuaron o vence el timer → nadie puede deducir
--   quién tiene rol por el ritmo de la pantalla.
--
--   Noche: lobos(45s) → vidente(30s) → protector(30s) → bruja(30s, si
--   hay) → amanecer (reveal muertes; muertos revelan rol). Día: debate
--   (3min) → voto (60s, sin autovoto; empate = UN revoto entre
--   empatados; empate otra vez = nadie) → linchado (rol revelado) →
--   siguiente noche. Cazador muerto (noche o voto) dispara a alguien.
--   Win: 0 lobos = aldea; lobos >= resto = lobos.
--
--   Leavers: "se los llevó la niebla" — cuentan como muertos SIN
--   revelar rol (barrido en cada resolución).
--
--   state = { phase reparto|noche_lobos|noche_vidente|noche_protector|
--             noche_bruja|amanecer|debate|voto|linchado|caza|caza_fin|fin,
--             phase_ends_at, night_no, ready:{}, acted:{}, votes:{},
--             vote_round, vote_pool:null|[pid], dead:{}, revealed:{pid:rol|'niebla'},
--             morning:[{pid,role?,niebla?}], executed, hunter, hunter_from,
--             hunter_kill:{pid,role}|null, winner:null|'lobos'|'aldea',
--             roles_pub:null|{pid:rol}, comp:{lobos,bruja,cazador} }
--   secrets = { role, wolves?:[names], potions?:{salvar,matar},
--               victima?:name|null, seen?:[{name,lobo}], picks?:{...} }
-- ============================================================

-- rol de un jugador (server only)
create or replace function lb_role_of(p_session_id uuid, p_pid uuid)
returns text language sql stable security definer set search_path = public as $$
  select payload->>'role' from player_secrets
  where game_session_id = p_session_id and player_id = p_pid;
$$;

-- vivos = repartidos (fila en secrets) + activos + no muertos en state
create or replace function lb_alive_pids(p_session game_sessions)
returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(s.player_id), '{}') from player_secrets s
  join players p on p.id = s.player_id
  where s.game_session_id = p_session.id and p.status = 'active'
    and not (p_session.state->'dead' ? s.player_id::text);
$$;

-- ganador con un mapa de muertos dado (null = sigue el juego)
create or replace function lb_winner(p_session_id uuid, p_dead jsonb)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_lobos int; v_resto int;
begin
  select count(*) filter (where s.payload->>'role' = 'lobo'),
         count(*) filter (where s.payload->>'role' <> 'lobo')
    into v_lobos, v_resto
  from player_secrets s join players p on p.id = s.player_id
  where s.game_session_id = p_session_id and p.status = 'active'
    and not (p_dead ? s.player_id::text);
  if v_lobos = 0 then return 'aldea'; end if;
  if v_lobos >= v_resto then return 'lobos'; end if;
  return null;
end $$;

-- víctima de los lobos: moda de los picks de lobos VIVOS (empate = random)
create or replace function lb_wolf_victim(p_session game_sessions)
returns uuid language sql stable security definer set search_path = public as $$
  select t from (
    select (s.payload->'picks'->>'lobos')::uuid as t, count(*) as n
    from player_secrets s join players p on p.id = s.player_id
    where s.game_session_id = p_session.id and s.payload->>'role' = 'lobo'
      and p.status = 'active' and not (p_session.state->'dead' ? s.player_id::text)
      and s.payload->'picks'->>'lobos' is not null
    group by 1
  ) x order by n desc, random() limit 1;
$$;

create or replace function lb_can_advance(p_session game_sessions)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_phase text := v_state->>'phase';
  v_key text;
  v_alive uuid[] := lb_alive_pids(p_session);
begin
  if coalesce((v_state->>'phase_ends_at')::timestamptz < now(), false)
     and v_phase in ('noche_lobos','noche_vidente','noche_protector','noche_bruja',
                     'debate','voto','caza') then
    return true;
  end if;
  v_key := case when v_phase = 'reparto' then 'ready'
                when v_phase like 'noche_%' then 'acted'
                when v_phase = 'voto' then 'votes'
                else null end;
  if v_key is null then return false; end if;
  return not exists (select 1 from unnest(v_alive) pid
                     where not (v_state->v_key ? pid::text));
end $$;

-- siguiente fase de noche después de p_from, saltando roles muertos/ausentes
create or replace function lb_next_night(p_session game_sessions, p_from text)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v_seq text[] := array['noche_vidente','noche_protector','noche_bruja'];
  v_roles text[] := array['vidente','protector','bruja'];
  v_start int := coalesce(array_position(v_seq, p_from), 0);
  i int;
begin
  for i in (v_start + 1)..3 loop
    if exists (select 1 from player_secrets s join players p on p.id = s.player_id
               where s.game_session_id = p_session.id and s.payload->>'role' = v_roles[i]
                 and p.status = 'active'
                 and not (p_session.state->'dead' ? s.player_id::text)) then
      return v_seq[i];
    end if;
  end loop;
  return 'amanecer';
end $$;

-- entra a una fase de noche (resetea acted; bruja recibe a la víctima)
create or replace function lb_enter_night_phase(p_session_id uuid, p_phase text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_victim uuid;
  v_name text;
begin
  select * into v_session from game_sessions where id = p_session_id;
  if p_phase = 'noche_bruja' then
    v_victim := lb_wolf_victim(v_session);
    if v_victim is not null then
      select name into v_name from players where id = v_victim;
    end if;
    update player_secrets set payload = payload || jsonb_build_object('victima', v_name)
      where game_session_id = p_session_id and payload->>'role' = 'bruja';
  end if;
  update game_sessions set state = state || jsonb_build_object(
    'phase', p_phase, 'acted', '{}'::jsonb,
    'phase_ends_at', to_jsonb(now() + make_interval(secs =>
      case when p_phase = 'noche_lobos' then 45 else 30 end)))
    where id = p_session_id;
end $$;

-- arranca la noche night_no+1 (limpia picks y víctima de la anterior)
create or replace function lb_start_night(p_party_id uuid, p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update player_secrets set payload = payload - 'picks' - 'victima'
    where game_session_id = p_session_id;
  update game_sessions set state = state || jsonb_build_object(
    'night_no', coalesce((state->>'night_no')::int, 0) + 1,
    'executed', null, 'hunter', null, 'hunter_from', null, 'hunter_kill', null,
    'morning', '[]'::jsonb, 'votes', '{}'::jsonb, 'vote_round', 1, 'vote_pool', null)
    where id = p_session_id;
  perform lb_enter_night_phase(p_session_id, 'noche_lobos');
end $$;

-- marca a los que se fueron como muertos por la niebla (sin revelar rol)
-- devuelve el state actualizado; p_morning=true además los anota en morning
create or replace function lb_sweep_niebla(p_session_id uuid, p_state jsonb, p_morning boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select s.player_id as pid from player_secrets s
           join players p on p.id = s.player_id
           where s.game_session_id = p_session_id and p.status <> 'active'
             and not (p_state->'dead' ? s.player_id::text) loop
    p_state := jsonb_set(p_state, array['dead', r.pid::text], 'true');
    p_state := jsonb_set(p_state, array['revealed', r.pid::text], to_jsonb('niebla'::text));
    if p_morning then
      p_state := jsonb_set(p_state, '{morning}',
        (p_state->'morning') || jsonb_build_object('pid', r.pid, 'niebla', true));
    end if;
  end loop;
  return p_state;
end $$;

-- resolución del amanecer: víctima vs protector/bruja + niebla + win check
create or replace function lb_resolve_night(p_party_id uuid, p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  v_victim uuid;
  v_prot uuid;
  v_bruja jsonb;
  v_role text;
  v_saved boolean := false;
  v_kill uuid;
begin
  select * into v_session from game_sessions where id = p_session_id;
  v_state := lb_sweep_niebla(p_session_id, v_session.state, true);

  v_session.state := v_state; -- para que victim/alive respeten la niebla
  v_victim := lb_wolf_victim(v_session);
  if v_victim is not null and (v_state->'dead' ? v_victim::text) then
    v_victim := null; -- la niebla se lo llevó primero
  end if;

  select (s.payload->'picks'->>'protector')::uuid into v_prot
  from player_secrets s join players p on p.id = s.player_id
  where s.game_session_id = p_session_id and s.payload->>'role' = 'protector'
    and p.status = 'active' and not (v_state->'dead' ? s.player_id::text);

  select s.payload->'picks'->'bruja' into v_bruja
  from player_secrets s join players p on p.id = s.player_id
  where s.game_session_id = p_session_id and s.payload->>'role' = 'bruja'
    and p.status = 'active' and not (v_state->'dead' ? s.player_id::text);

  v_saved := (v_victim is not null and v_victim = v_prot)
          or (coalesce(v_bruja->>'accion', '') = 'salvar');

  -- muerte por lobos
  if v_victim is not null and not v_saved then
    v_role := lb_role_of(p_session_id, v_victim);
    v_state := jsonb_set(v_state, array['dead', v_victim::text], 'true');
    v_state := jsonb_set(v_state, array['revealed', v_victim::text], to_jsonb(v_role));
    v_state := jsonb_set(v_state, '{morning}',
      (v_state->'morning') || jsonb_build_object('pid', v_victim, 'role', v_role));
    if v_role = 'cazador' then
      v_state := v_state || jsonb_build_object('hunter', v_victim, 'hunter_from', 'noche');
    end if;
  end if;

  -- poción de matar (no la para el protector)
  v_kill := (v_bruja->>'target')::uuid;
  if coalesce(v_bruja->>'accion', '') = 'matar' and v_kill is not null
     and not (v_state->'dead' ? v_kill::text) then
    v_role := lb_role_of(p_session_id, v_kill);
    if v_role is not null then
      v_state := jsonb_set(v_state, array['dead', v_kill::text], 'true');
      v_state := jsonb_set(v_state, array['revealed', v_kill::text], to_jsonb(v_role));
      v_state := jsonb_set(v_state, '{morning}',
        (v_state->'morning') || jsonb_build_object('pid', v_kill, 'role', v_role));
      if v_role = 'cazador' then
        v_state := v_state || jsonb_build_object('hunter', v_kill, 'hunter_from', 'noche');
      end if;
    end if;
  end if;

  -- pociones gastadas
  if coalesce(v_bruja->>'accion', '') in ('salvar', 'matar') then
    update player_secrets set payload = jsonb_set(payload,
      array['potions', v_bruja->>'accion'], 'false')
      where game_session_id = p_session_id and payload->>'role' = 'bruja';
  end if;

  v_state := v_state || jsonb_build_object(
    'phase', 'amanecer', 'phase_ends_at', null, 'acted', '{}'::jsonb,
    'winner', lb_winner(p_session_id, v_state->'dead'));
  update game_sessions set state = v_state where id = p_session_id;
end $$;

-- cierre del voto de día: linchado / revoto / nadie
create or replace function lb_after_voto(p_party_id uuid, p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  v_tied uuid[];
  v_top uuid;
  v_role text;
begin
  select * into v_session from game_sessions where id = p_session_id;
  v_state := lb_sweep_niebla(p_session_id, v_session.state, false);

  select array_agg(target) into v_tied from (
    select e.value::uuid as target, count(*) as n
    from jsonb_each_text(v_state->'votes') e
    group by 1
  ) x where n = (select max(m.cnt) from (
    select count(*) as cnt from jsonb_each_text(v_state->'votes') e2 group by e2.value) m);

  if v_tied is null or array_length(v_tied, 1) = 0 then
    -- nadie votó
    v_state := v_state || jsonb_build_object('phase', 'linchado', 'executed', null, 'phase_ends_at', null);
  elsif array_length(v_tied, 1) > 1 then
    if coalesce((v_state->>'vote_round')::int, 1) = 1 then
      -- UN revoto entre los empatados
      update game_sessions set state = v_state || jsonb_build_object(
        'vote_round', 2, 'votes', '{}'::jsonb,
        'vote_pool', (select jsonb_agg(to_jsonb(t::text)) from unnest(v_tied) t),
        'phase_ends_at', to_jsonb(now() + interval '60 seconds'))
        where id = p_session_id;
      return;
    end if;
    v_state := v_state || jsonb_build_object('phase', 'linchado', 'executed', null, 'phase_ends_at', null);
  else
    v_top := v_tied[1];
    v_role := lb_role_of(p_session_id, v_top);
    v_state := jsonb_set(v_state, array['dead', v_top::text], 'true');
    v_state := jsonb_set(v_state, array['revealed', v_top::text], to_jsonb(v_role));
    v_state := v_state || jsonb_build_object('phase', 'linchado', 'executed', v_top, 'phase_ends_at', null);
    if v_role = 'cazador' then
      v_state := v_state || jsonb_build_object('hunter', v_top, 'hunter_from', 'dia');
    end if;
    v_state := v_state || jsonb_build_object('winner', lb_winner(p_session_id, v_state->'dead'));
  end if;
  update game_sessions set state = v_state where id = p_session_id;
end $$;

-- entra a fin: revela TODOS los roles
create or replace function lb_enter_fin(p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update game_sessions set state = state || jsonb_build_object(
    'phase', 'fin', 'phase_ends_at', null,
    'roles_pub', (select jsonb_object_agg(player_id::text, payload->>'role')
                  from player_secrets where game_session_id = p_session_id))
    where id = p_session_id;
end $$;

-- ---------- ACCIONES (validación server; las usan submit y bots) ----------

create or replace function lb_do_night_pick(p_session_id uuid, p_pid uuid, p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_phase text;
  v_key text;
  v_role text;
  v_tname text;
begin
  select * into v_session from game_sessions where id = p_session_id;
  v_phase := v_session.state->>'phase';
  if v_phase not like 'noche_%' then raise exception 'FASE_INVALIDA'; end if;
  if not (p_pid = any (lb_alive_pids(v_session))) then raise exception 'ESTAS_MUERTO'; end if;
  if not (p_target = any (lb_alive_pids(v_session))) then raise exception 'OBJETIVO_INVALIDO'; end if;

  v_key := replace(v_phase, 'noche_', '');
  v_role := lb_role_of(p_session_id, p_pid);

  if v_key = 'bruja' and v_role = 'bruja' then
    -- la bruja que solo tapea = no usa poción
    update player_secrets set payload = jsonb_set(
      jsonb_set(coalesce(payload, '{}'), '{picks}', coalesce(payload->'picks', '{}'::jsonb)),
      '{picks,bruja}', jsonb_build_object('accion', 'nada'))
      where game_session_id = p_session_id and player_id = p_pid;
  else
    update player_secrets set payload = jsonb_set(
      jsonb_set(coalesce(payload, '{}'), '{picks}', coalesce(payload->'picks', '{}'::jsonb)),
      array['picks', v_key], to_jsonb(p_target::text))
      where game_session_id = p_session_id and player_id = p_pid;
    -- visión de la vidente: resultado inmediato en su pantalla
    if v_key = 'vidente' and v_role = 'vidente' then
      select name into v_tname from players where id = p_target;
      update player_secrets set payload = jsonb_set(payload, '{seen}',
        coalesce(payload->'seen', '[]'::jsonb) || jsonb_build_object(
          'name', v_tname, 'lobo', lb_role_of(p_session_id, p_target) = 'lobo'))
        where game_session_id = p_session_id and player_id = p_pid;
    end if;
  end if;

  update game_sessions set state = jsonb_set(state, array['acted', p_pid::text], 'true')
    where id = p_session_id;
end $$;

create or replace function lb_do_bruja(p_session_id uuid, p_pid uuid, p_accion text, p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_pay jsonb;
begin
  select * into v_session from game_sessions where id = p_session_id;
  if v_session.state->>'phase' <> 'noche_bruja' then raise exception 'FASE_INVALIDA'; end if;
  if lb_role_of(p_session_id, p_pid) <> 'bruja' then raise exception 'NO_ERES_LA_BRUJA'; end if;
  if not (p_pid = any (lb_alive_pids(v_session))) then raise exception 'ESTAS_MUERTA'; end if;
  if p_accion not in ('nada', 'salvar', 'matar') then raise exception 'ACCION_INVALIDA'; end if;

  select payload into v_pay from player_secrets
    where game_session_id = p_session_id and player_id = p_pid;
  if p_accion = 'salvar' and not coalesce((v_pay->'potions'->>'salvar')::boolean, false) then
    raise exception 'SIN_POCION';
  end if;
  if p_accion = 'matar' then
    if not coalesce((v_pay->'potions'->>'matar')::boolean, false) then raise exception 'SIN_POCION'; end if;
    if p_target is null or not (p_target = any (lb_alive_pids(v_session))) then
      raise exception 'OBJETIVO_INVALIDO';
    end if;
  end if;

  update player_secrets set payload = jsonb_set(
    jsonb_set(coalesce(payload, '{}'), '{picks}', coalesce(payload->'picks', '{}'::jsonb)),
    '{picks,bruja}', jsonb_strip_nulls(jsonb_build_object('accion', p_accion, 'target', p_target)))
    where game_session_id = p_session_id and player_id = p_pid;
  update game_sessions set state = jsonb_set(state, array['acted', p_pid::text], 'true')
    where id = p_session_id;
end $$;

create or replace function lb_do_vote(p_session_id uuid, p_pid uuid, p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_session game_sessions;
begin
  select * into v_session from game_sessions where id = p_session_id;
  if v_session.state->>'phase' <> 'voto' then raise exception 'FASE_INVALIDA'; end if;
  if not (p_pid = any (lb_alive_pids(v_session))) then raise exception 'ESTAS_MUERTO'; end if;
  if p_target = p_pid then raise exception 'NO_AUTOVOTO'; end if;
  if not (p_target = any (lb_alive_pids(v_session))) then raise exception 'VOTO_INVALIDO'; end if;
  if v_session.state->'vote_pool' is not null
     and jsonb_typeof(v_session.state->'vote_pool') = 'array'
     and not (v_session.state->'vote_pool' @> to_jsonb(p_target::text)) then
    raise exception 'SOLO_EMPATADOS';
  end if;
  update game_sessions set state = jsonb_set(state, array['votes', p_pid::text], to_jsonb(p_target::text))
    where id = p_session_id;
end $$;

create or replace function lb_do_shoot(p_session_id uuid, p_pid uuid, p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  v_role text;
begin
  select * into v_session from game_sessions where id = p_session_id;
  v_state := v_session.state;
  if v_state->>'phase' <> 'caza' then raise exception 'FASE_INVALIDA'; end if;
  if (v_state->>'hunter')::uuid <> p_pid then raise exception 'NO_ERES_EL_CAZADOR'; end if;
  if p_target = p_pid or not (p_target = any (lb_alive_pids(v_session))) then
    raise exception 'OBJETIVO_INVALIDO';
  end if;
  v_role := lb_role_of(p_session_id, p_target);
  v_state := jsonb_set(v_state, array['dead', p_target::text], 'true');
  v_state := jsonb_set(v_state, array['revealed', p_target::text], to_jsonb(v_role));
  v_state := v_state || jsonb_build_object(
    'phase', 'caza_fin', 'phase_ends_at', null,
    'hunter_kill', jsonb_build_object('pid', p_target, 'role', v_role),
    'winner', lb_winner(p_session_id, v_state->'dead'));
  update game_sessions set state = v_state where id = p_session_id;
end $$;

-- ---------- LAUNCH / ADVANCE / SUBMIT / BOTS (los llama el dispatcher) ----------

create or replace function lb_launch(p_party_id uuid, p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_ids uuid[];
  v_np int;
  v_wolves int;
  v_roles text[];
  v_wnames text;
  v_pid uuid;
  i int := 0;
begin
  v_ids := (select array_agg(pid order by random()) from unnest(acting_player_ids(p_party_id)) pid);
  v_np := coalesce(array_length(v_ids, 1), 0);
  if v_np < 6 then
    delete from game_sessions where id = p_session_id;
    raise exception 'FALTAN_JUGADORES';
  end if;

  v_wolves := case when v_np <= 7 then 2 when v_np <= 11 then 3 else 4 end;
  v_roles := array_fill('lobo'::text, array[v_wolves]) || array['vidente', 'protector'];
  if v_np >= 8 then v_roles := v_roles || 'bruja'::text; end if;
  if v_np >= 12 then v_roles := v_roles || 'cazador'::text; end if;
  while array_length(v_roles, 1) < v_np loop
    v_roles := v_roles || 'aldeano'::text;
  end loop;

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

  -- los lobos se conocen entre sí (nombres)
  select string_agg(p.name, ', ') into v_wnames
  from player_secrets s join players p on p.id = s.player_id
  where s.game_session_id = p_session_id and s.payload->>'role' = 'lobo';
  update player_secrets set payload = payload || jsonb_build_object('wolves', v_wnames)
    where game_session_id = p_session_id and payload->>'role' = 'lobo';

  update game_sessions set state = jsonb_build_object(
    'phase', 'reparto', 'phase_ends_at', null, 'night_no', 0,
    'ready', '{}'::jsonb, 'acted', '{}'::jsonb, 'votes', '{}'::jsonb,
    'vote_round', 1, 'vote_pool', null,
    'dead', '{}'::jsonb, 'revealed', '{}'::jsonb, 'morning', '[]'::jsonb,
    'executed', null, 'hunter', null, 'hunter_from', null, 'hunter_kill', null,
    'winner', null, 'roles_pub', null,
    'comp', jsonb_build_object('lobos', v_wolves, 'bruja', v_np >= 8, 'cazador', v_np >= 12))
    where id = p_session_id;
end $$;

create or replace function lb_advance(p_party_id uuid, p_force boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_phase text;
  v_next text;
begin
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;
  v_phase := v_session.state->>'phase';

  if v_phase = 'reparto' then
    if not p_force and not lb_can_advance(v_session) then return; end if;
    perform lb_start_night(p_party_id, v_session.id);

  elsif v_phase in ('noche_lobos', 'noche_vidente', 'noche_protector') then
    if not p_force and not lb_can_advance(v_session) then return; end if;
    v_next := lb_next_night(v_session, v_phase);
    if v_next = 'amanecer' then
      perform lb_resolve_night(p_party_id, v_session.id);
    else
      perform lb_enter_night_phase(v_session.id, v_next);
    end if;

  elsif v_phase = 'noche_bruja' then
    if not p_force and not lb_can_advance(v_session) then return; end if;
    perform lb_resolve_night(p_party_id, v_session.id);

  elsif v_phase = 'amanecer' then
    if not p_force then return; end if;
    if v_session.state->>'winner' is not null then
      perform lb_enter_fin(v_session.id);
    elsif v_session.state->>'hunter' is not null and v_session.state->>'hunter_kill' is null then
      update game_sessions set state = state || jsonb_build_object(
        'phase', 'caza', 'phase_ends_at', to_jsonb(now() + interval '30 seconds'))
        where id = v_session.id;
    else
      update game_sessions set state = state || jsonb_build_object(
        'phase', 'debate', 'phase_ends_at', to_jsonb(now() + interval '180 seconds'))
        where id = v_session.id;
    end if;

  elsif v_phase = 'debate' then
    if not p_force and not lb_can_advance(v_session) then return; end if;
    update game_sessions set state = state || jsonb_build_object(
      'phase', 'voto', 'votes', '{}'::jsonb, 'vote_round', 1, 'vote_pool', null,
      'phase_ends_at', to_jsonb(now() + interval '60 seconds'))
      where id = v_session.id;

  elsif v_phase = 'voto' then
    if not p_force and not lb_can_advance(v_session) then return; end if;
    perform lb_after_voto(p_party_id, v_session.id);

  elsif v_phase = 'linchado' then
    if not p_force then return; end if;
    if v_session.state->>'winner' is not null then
      perform lb_enter_fin(v_session.id);
    elsif v_session.state->>'hunter' is not null and v_session.state->>'hunter_kill' is null
          and v_session.state->>'hunter_from' = 'dia' then
      update game_sessions set state = state || jsonb_build_object(
        'phase', 'caza', 'phase_ends_at', to_jsonb(now() + interval '30 seconds'))
        where id = v_session.id;
    else
      perform lb_start_night(p_party_id, v_session.id);
    end if;

  elsif v_phase = 'caza' then
    -- timeout o host: el cazador no disparó
    if not p_force and not lb_can_advance(v_session) then return; end if;
    update game_sessions set state = state || jsonb_build_object(
      'phase', 'caza_fin', 'phase_ends_at', null, 'hunter_kill', null)
      where id = v_session.id;

  elsif v_phase = 'caza_fin' then
    if not p_force then return; end if;
    if v_session.state->>'winner' is not null then
      perform lb_enter_fin(v_session.id);
    elsif v_session.state->>'hunter_from' = 'noche' then
      update game_sessions set state = state || jsonb_build_object(
        'phase', 'debate', 'phase_ends_at', to_jsonb(now() + interval '180 seconds'))
        where id = v_session.id;
    else
      perform lb_start_night(p_party_id, v_session.id);
    end if;

  elsif v_phase = 'fin' then
    if p_force then perform end_game(p_party_id); end if;
  end if;
end $$;

create or replace function lb_submit(p_party_id uuid, p_me uuid, p_action text, p_payload jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_phase text;
begin
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;
  v_phase := v_session.state->>'phase';

  if p_action = 'ready' and v_phase = 'reparto' then
    if not (p_me = any (lb_alive_pids(v_session))) then raise exception 'NO_REPARTIDO'; end if;
    update game_sessions set state = jsonb_set(state, array['ready', p_me::text], 'true')
      where id = v_session.id;
  elsif p_action = 'night_pick' then
    perform lb_do_night_pick(v_session.id, p_me, (p_payload->>'target')::uuid);
  elsif p_action = 'bruja' then
    perform lb_do_bruja(v_session.id, p_me, p_payload->>'accion', (p_payload->>'target')::uuid);
  elsif p_action = 'vote' then
    perform lb_do_vote(v_session.id, p_me, (p_payload->>'target')::uuid);
  elsif p_action = 'shoot' then
    perform lb_do_shoot(v_session.id, p_me, (p_payload->>'target')::uuid);
    return; -- shoot ya cambió de fase
  else
    raise exception 'ACCION_INVALIDA';
  end if;

  select * into v_session from game_sessions where id = v_session.id;
  if v_session.status = 'active' and lb_can_advance(v_session) then
    perform advance_phase(p_party_id, false);
  end if;
end $$;

create or replace function lb_bot_tick(p_party_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_phase text;
  v_bot record;
  v_alive uuid[];
  v_targets uuid[];
  v_role text;
begin
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then return; end if;
  v_phase := v_session.state->>'phase';
  v_alive := lb_alive_pids(v_session);

  if v_phase = 'caza' then
    if exists (select 1 from players where id = (v_session.state->>'hunter')::uuid
               and is_bot and status = 'active') then
      v_targets := array(select pid from unnest(v_alive) pid where pid <> (v_session.state->>'hunter')::uuid);
      if array_length(v_targets, 1) > 0 then
        perform lb_do_shoot(v_session.id, (v_session.state->>'hunter')::uuid,
          v_targets[1 + floor(random()*array_length(v_targets,1))::int]);
      end if;
    end if;
    return;
  end if;

  for v_bot in select p.id from players p
               where p.party_id = p_party_id and p.is_bot and p.status = 'active'
                 and p.id = any (v_alive) loop
    v_session.state := (select state from game_sessions where id = v_session.id);

    if v_phase = 'reparto' and not (v_session.state->'ready' ? v_bot.id::text) then
      update game_sessions set state = jsonb_set(state, array['ready', v_bot.id::text], 'true')
        where id = v_session.id;

    elsif v_phase like 'noche_%' and not (v_session.state->'acted' ? v_bot.id::text) then
      v_role := lb_role_of(v_session.id, v_bot.id);
      if v_phase = 'noche_bruja' and v_role = 'bruja' then
        perform lb_do_bruja(v_session.id, v_bot.id, 'nada', null);
      else
        v_targets := array(select pid from unnest(v_alive) pid where pid <> v_bot.id);
        perform lb_do_night_pick(v_session.id, v_bot.id,
          v_targets[1 + floor(random()*array_length(v_targets,1))::int]);
      end if;

    elsif v_phase = 'voto' and not (v_session.state->'votes' ? v_bot.id::text) then
      if v_session.state->'vote_pool' is not null
         and jsonb_typeof(v_session.state->'vote_pool') = 'array' then
        v_targets := array(select (e#>>'{}')::uuid from jsonb_array_elements(v_session.state->'vote_pool') e
                           where (e#>>'{}')::uuid <> v_bot.id);
      else
        v_targets := array(select pid from unnest(v_alive) pid where pid <> v_bot.id);
      end if;
      if array_length(v_targets, 1) > 0 then
        perform lb_do_vote(v_session.id, v_bot.id,
          v_targets[1 + floor(random()*array_length(v_targets,1))::int]);
      end if;
    end if;
  end loop;

  select * into v_session from game_sessions where id = v_session.id;
  if v_session.status = 'active' and lb_can_advance(v_session) then
    perform advance_phase(p_party_id, false);
  end if;
end $$;

revoke execute on function
  lb_role_of(uuid, uuid), lb_alive_pids(game_sessions), lb_winner(uuid, jsonb),
  lb_wolf_victim(game_sessions), lb_can_advance(game_sessions),
  lb_next_night(game_sessions, text), lb_enter_night_phase(uuid, text),
  lb_start_night(uuid, uuid), lb_sweep_niebla(uuid, jsonb, boolean),
  lb_resolve_night(uuid, uuid), lb_after_voto(uuid, uuid), lb_enter_fin(uuid),
  lb_do_night_pick(uuid, uuid, uuid), lb_do_bruja(uuid, uuid, text, uuid),
  lb_do_vote(uuid, uuid, uuid), lb_do_shoot(uuid, uuid, uuid),
  lb_launch(uuid, uuid), lb_advance(uuid, boolean),
  lb_submit(uuid, uuid, text, jsonb), lb_bot_tick(uuid)
from public, anon, authenticated;
