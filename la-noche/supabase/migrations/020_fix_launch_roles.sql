-- ============================================================
-- LA NOCHE — Migración 020: FIX lanzamiento Lobos / Misión Secreta / Dos Cuartos
-- Bug: `v_roles := v_roles || 'esbirro'` — el literal sin tipo hace que
-- Postgres resuelva `||` como array_cat e intente parsear 'esbirro' como
-- array → "malformed array literal". Fix: cast ::text (array_append).
-- Re-crea SOLO las 3 funciones de launch (016/017/018 ya corridas).
-- create or replace conserva los REVOKE existentes.
-- ============================================================

-- ---------- LOBOS (016) ----------
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

-- ---------- MISIÓN SECRETA (017) ----------
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

-- ---------- DOS CUARTOS (018) ----------
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
