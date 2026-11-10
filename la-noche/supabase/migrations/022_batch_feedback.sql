-- ============================================================
-- LA NOCHE — Migración 022: BATCH FEEDBACK TANDAS 1+2 (2026-07-18)
-- Correr DESPUÉS de 020 y 021.
--
-- Cambios (feedback de César):
--  · Verdad o Reto: Cumplí/Paso ya no castiga (el grupo juzga en vivo);
--    regla nueva: 2 verdades seguidas → la tercera es RETO obligado
--    (state.streaks por jugador, server-enforced).
--  · La Ruleta: countdown opcional (p_opts.countdown_s 0|3|5) al pasar
--    carta — la carta se "cocina" phase_ends_at y el cliente la tapa.
--  · El Rey: fase 'reveal' tras sacar — se ve QUIÉN sacó y la carta;
--    el turno rota solo cuando el que sacó (o el host) da "Siguiente"
--    (o a los 60s). Arregla el bug de turno fantasma.
--  · Sin Filtro: MANO FINITA (n_cards = cartas en mano, SIN refill; el
--    mazo de negras dura lo mismo); p_opts.judge_mode 'juez'|'votos'
--    (todos votan, no la propia); p_opts.suspenso (el host lee las
--    jugadas antes de mostrarlas: action 'show').
--  · Impostor: si el impostor escapa (empate/inocente) NO se revela ni
--    cambia la palabra: fase 'cazeria' → host reabre pistas y se sigue
--    la persecución con el mismo impostor. p_opts.offline: la app solo
--    reparte (host ve impostor+palabra en secret.admin y modera en vivo).
--  · Tres Rondas: p_opts.offline = "modo base": la app arma equipos y
--    dispensa palabras (action 'next_word'); turnos/puntos en vivo.
--  · Lobos: lb_launch gana p_opts — roles configurables
--    (p_opts.roles.{vidente,protector,bruja,cazador}, p_opts.wolves) y
--    p_opts.offline (host = moderador: NO recibe rol, ve todos en
--    secret.admin_roles; el juego se narra en vivo).
--  · Dos Cuartos: dc_launch gana p_opts — p_opts.offline: solo reparto
--    + card-share; el reveal final muestra presidente/bomba sin winner.
--
-- ⚠ Reescribe los 4 dispatchers completos (patrón 015/019).
-- ============================================================

-- ==================== VERDAD O RETO ====================

-- elección con regla "2 verdades seguidas → reto": p_choice null = auto
-- (timeout/bot). Devuelve el state nuevo o null si no quedan cartas.
create or replace function vr_choose(p_state jsonb, p_pid uuid, p_choice text)
returns jsonb language plpgsql volatile as $$
declare
  v_streak int := coalesce((p_state->'streaks'->>(p_pid::text))::int, 0);
  v_choice text := p_choice;
  v_new jsonb;
  v_actual text;
begin
  if v_choice is null then
    v_choice := case when v_streak >= 2 then 'reto'
                     when random() < 0.5 then 'verdad' else 'reto' end;
  elsif v_choice = 'verdad' and v_streak >= 2 then
    raise exception 'RETO_OBLIGADO';
  end if;
  v_new := vr_pick_card(p_state, v_choice);
  if v_new is null then return null; end if;
  v_actual := v_new->>'choice'; -- puede diferir si el banco se agotó
  return jsonb_set(
    jsonb_set(v_new, '{streaks}', coalesce(v_new->'streaks', '{}'::jsonb)),
    array['streaks', p_pid::text],
    to_jsonb(case when v_actual = 'verdad' then v_streak + 1 else 0 end));
end $$;

-- avanza VoR: desde elegir = elección auto (respeta streak); desde carta = sig. turno
create or replace function vr_step(p_party_id uuid, p_session game_sessions)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_pid uuid;
  v_new jsonb;
begin
  if v_state->>'phase' = 'elegir' then
    v_pid := (v_state->'turn_order'->>((v_state->>'turn_idx')::int))::uuid;
    v_new := vr_choose(v_state, v_pid, null);
  else -- carta → siguiente turno o fin
    if coalesce((v_state->>'turn_no')::int, 0) >= coalesce((v_state->>'total_turns')::int, 0) then
      perform end_game(p_party_id); return;
    end if;
    v_new := vr_enter_elegir(p_session);
  end if;
  if v_new is null then perform end_game(p_party_id); return; end if;
  update game_sessions set state = v_new where id = p_session.id;
end $$;

-- ==================== LA RULETA ====================

-- igual que 007 + countdown opcional: state.countdown_s > 0 →
-- phase_ends_at = ahora + countdown; el cliente tapa la carta hasta entonces.
create or replace function rl_enter_carta(p_session game_sessions)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_idx int := coalesce((v_state->>'round_idx')::int, -1) + 1;
  v_card jsonb;
  v_text text;
  v_slots jsonb := '{}'::jsonb;
  v_names text[];
  v_cd int := coalesce((v_state->>'countdown_s')::int, 0);
begin
  if v_idx >= jsonb_array_length(v_state->'deck') then return null; end if;
  v_card := v_state->'deck'->v_idx;
  v_text := v_card->>'text';

  select array_agg(name order by random()) into v_names
  from players where party_id = p_session.party_id and status = 'active';
  if position('{p1}' in v_text) > 0 and coalesce(array_length(v_names,1),0) >= 1 then
    v_slots := v_slots || jsonb_build_object('p1', v_names[1]);
  end if;
  if position('{p2}' in v_text) > 0 and coalesce(array_length(v_names,1),0) >= 2 then
    v_slots := v_slots || jsonb_build_object('p2', v_names[2]);
  end if;

  v_state := v_state || jsonb_build_object(
    'phase', 'carta', 'round_idx', v_idx, 'slots', v_slots,
    'phase_ends_at', case when v_cd > 0 then to_jsonb(now() + make_interval(secs => v_cd)) else null end);

  if v_card->>'card_type' = 'regla' then
    v_state := jsonb_set(v_state, '{rules}', coalesce(v_state->'rules', '[]'::jsonb) || to_jsonb(v_text));
  end if;
  return v_state;
end $$;

-- ==================== EL REY ====================

-- sacar carta: entra a 'reveal' (el turno NO rota todavía — se ve quién
-- sacó y qué salió). 4º rey / mazo agotado → 'fin'.
create or replace function rey_draw(p_party_id uuid, p_session game_sessions)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_idx int := coalesce((v_state->>'idx')::int, 0);
  v_card jsonb := v_state->'deck'->v_idx;
  v_kings int := coalesce((v_state->>'kings')::int, 0);
begin
  if v_card is null then perform end_game(p_party_id); return; end if;
  if v_card->>'r' = 'K' then v_kings := v_kings + 1; end if;

  v_state := v_state || jsonb_build_object('last_card', v_card, 'idx', v_idx + 1, 'kings', v_kings);

  if v_kings >= 4 or v_idx + 1 >= jsonb_array_length(v_state->'deck') then
    v_state := v_state || jsonb_build_object('phase', 'fin', 'phase_ends_at', null);
  else
    v_state := v_state || jsonb_build_object(
      'phase', 'reveal', 'phase_ends_at', to_jsonb(now() + interval '60 seconds'));
  end if;
  update game_sessions set state = v_state where id = p_session.id;
end $$;

-- "Siguiente": rota el turno y vuelve a 'carta'
create or replace function rey_next(p_party_id uuid, p_session game_sessions)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_turn int;
begin
  v_turn := next_active_turn(v_state->'turn_order', (v_state->>'turn_idx')::int);
  if v_turn = -1 then perform end_game(p_party_id); return; end if;
  update game_sessions set state = v_state || jsonb_build_object(
    'phase', 'carta', 'turn_idx', v_turn,
    'phase_ends_at', to_jsonb(now() + interval '30 seconds'))
    where id = p_session.id;
end $$;

create or replace function rey_can_advance(p_session game_sessions)
returns boolean language sql stable as $$
  select p_session.state->>'phase' in ('carta', 'reveal')
     and coalesce((p_session.state->>'phase_ends_at')::timestamptz < now(), false);
$$;

-- ==================== SIN FILTRO ====================

create or replace function sf_mode(p_state jsonb)
returns text language sql immutable as $$
  select coalesce(p_state->>'judge_mode', 'juez');
$$;

-- jugar carta SIN refill (mano finita: la tensión de gastarlas)
create or replace function sf_play_card(p_session_id uuid, p_pid uuid, p_idx int)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb;
  v_hand jsonb;
  v_card jsonb;
  v_idx int := p_idx;
begin
  select state into v_state from game_sessions where id = p_session_id;
  select payload->'hand' into v_hand from player_secrets
    where game_session_id = p_session_id and player_id = p_pid;
  if v_hand is null or jsonb_array_length(v_hand) = 0 then return; end if;

  if v_idx is null then v_idx := floor(random() * jsonb_array_length(v_hand))::int; end if;
  v_card := v_hand->v_idx;
  if v_card is null then raise exception 'CARTA_INVALIDA'; end if;

  v_hand := v_hand - v_idx; -- sin refill

  update player_secrets set payload = jsonb_build_object('hand', v_hand)
    where game_session_id = p_session_id and player_id = p_pid;
  v_state := jsonb_set(v_state, '{plays}',
    (v_state->'plays') || jsonb_build_object('pid', p_pid, 'text', v_card));
  update game_sessions set state = v_state where id = p_session_id;
end $$;

-- jugadores activos que aún tienen cartas (y no son el juez, en modo juez)
create or replace function sf_players_with_cards(p_session game_sessions, p_excl_juez boolean)
returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(p.id), '{}') from players p
  join player_secrets s on s.player_id = p.id and s.game_session_id = p_session.id
  where p.party_id = p_session.party_id and p.status = 'active'
    and jsonb_array_length(coalesce(s.payload->'hand', '[]'::jsonb)) > 0
    and (not p_excl_juez or p.id <> sf_juez(p_session.state));
$$;

create or replace function sf_can_advance(p_session game_sessions)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_needed int;
begin
  if v_state->>'phase' <> 'jugar' then return false; end if;
  if coalesce((v_state->>'phase_ends_at')::timestamptz < now(), false) then return true; end if;
  v_needed := coalesce(array_length(sf_players_with_cards(p_session, sf_mode(v_state) = 'juez'), 1), 0);
  return jsonb_array_length(v_state->'plays') >= v_needed;
end $$;

-- entra a juzgar: auto-juega por los que faltan (y tienen cartas), baraja;
-- suspenso → shown=false (solo el host ve hasta dar 'show')
create or replace function sf_enter_juzgar(p_party_id uuid, p_session game_sessions)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb;
  v_pid uuid;
begin
  foreach v_pid in array sf_players_with_cards(p_session, sf_mode(p_session.state) = 'juez') loop
    if not exists (select 1 from jsonb_array_elements(
        (select state->'plays' from game_sessions where id = p_session.id)) e
        where (e->>'pid')::uuid = v_pid) then
      perform sf_play_card(p_session.id, v_pid, null);
    end if;
  end loop;

  select state into v_state from game_sessions where id = p_session.id;
  v_state := jsonb_set(v_state, '{plays}',
    coalesce((select jsonb_agg(e order by random()) from jsonb_array_elements(v_state->'plays') e), '[]'));
  v_state := v_state || jsonb_build_object(
    'phase', 'juzgar', 'phase_ends_at', null,
    'votes', '{}'::jsonb,
    'shown', not coalesce((v_state->>'suspenso')::boolean, false));
  update game_sessions set state = v_state where id = p_session.id;
end $$;

-- cierra la votación (modo votos): jugada con más votos (empate = random)
create or replace function sf_after_votes(p_party_id uuid, p_session game_sessions)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_idx int;
begin
  select idx into v_idx from (
    select (e.value)::int as idx, count(*) as n
    from jsonb_each_text(coalesce(v_state->'votes', '{}'::jsonb)) e
    group by 1
  ) t order by n desc, random() limit 1;
  if v_idx is null then
    v_idx := floor(random() * greatest(1, jsonb_array_length(v_state->'plays')))::int;
  end if;
  perform sf_crown(p_party_id, p_session, v_idx);
end $$;

-- siguiente negra o podio (también si ya casi nadie tiene cartas)
create or replace function sf_next_round(p_party_id uuid, p_session game_sessions)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_juez int;
  v_left int;
begin
  select count(*) into v_left from players p
  join player_secrets s on s.player_id = p.id and s.game_session_id = p_session.id
  where p.party_id = p_session.party_id and p.status = 'active'
    and jsonb_array_length(coalesce(s.payload->'hand', '[]'::jsonb)) > 0;

  if (v_state->>'negra_idx')::int + 1 >= jsonb_array_length(v_state->'negras')
     or v_left < 2 then
    v_state := v_state || jsonb_build_object('phase', 'podio', 'phase_ends_at', null);
    update game_sessions set state = v_state where id = p_session.id;
    return;
  end if;
  v_juez := next_active_turn(v_state->'turn_order', (v_state->>'juez_idx')::int);
  if v_juez = -1 then perform end_game(p_party_id); return; end if;
  v_state := v_state || jsonb_build_object(
    'phase', 'jugar',
    'negra_idx', (v_state->>'negra_idx')::int + 1,
    'juez_idx', v_juez, 'plays', '[]'::jsonb, 'winner_idx', null, 'votes', '{}'::jsonb,
    'phase_ends_at', to_jsonb(now() + make_interval(secs => coalesce((v_state->>'timer_s')::int, 45))));
  update game_sessions set state = v_state where id = p_session.id;
end $$;

-- ==================== IMPOSTOR ====================

-- reparte la ronda; en offline el host además recibe secret.admin
create or replace function im_start_round(p_session game_sessions)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_round int := coalesce((v_state->>'round_idx')::int, -1) + 1;
  v_card_id uuid;
  v_words jsonb;
  v_word text;
  v_ids uuid[];
  v_imp uuid;
  v_pid uuid;
  v_host uuid;
  v_offline boolean := coalesce((v_state->>'offline')::boolean, false);
begin
  v_card_id := (v_state->'deck'->v_round->>'id')::uuid;
  select meta->'words' into v_words from content_cards where id = v_card_id;
  if v_words is null or jsonb_array_length(v_words) < 3 then
    raise exception 'SIN_CARTAS';
  end if;
  v_word := v_words->>(floor(random() * jsonb_array_length(v_words))::int);

  v_ids := acting_player_ids(p_session.party_id);
  v_imp := v_ids[1 + floor(random() * array_length(v_ids, 1))::int];

  delete from player_secrets where game_session_id = p_session.id;
  foreach v_pid in array v_ids loop
    insert into player_secrets (game_session_id, player_id, payload)
    values (p_session.id, v_pid, case when v_pid = v_imp
      then jsonb_build_object('role', 'impostor')
      else jsonb_build_object('role', 'normal', 'word', v_word) end);
  end loop;

  -- modo offline: el host ve al impostor y la palabra (modera en vivo)
  if v_offline then
    select id into v_host from players
      where party_id = p_session.party_id and is_host limit 1;
    if v_host is not null then
      update player_secrets set payload = payload || jsonb_build_object(
        'admin', jsonb_build_object(
          'impostor', (select name from players where id = v_imp),
          'word', v_word))
        where game_session_id = p_session.id and player_id = v_host;
    end if;
  end if;

  update game_sessions set state = v_state || jsonb_build_object(
    'phase', 'secreto', 'round_idx', v_round,
    'turn_order', (select jsonb_agg(to_jsonb(pid) order by random()) from unnest(v_ids) pid),
    'ready', '{}'::jsonb, 'votes', '{}'::jsonb, 'guess', null, 'hunts', 0,
    'word', null, 'impostor', null, 'outcome', null, 'accused', null,
    'phase_ends_at', case when v_offline then null
                          else to_jsonb(now() + interval '45 seconds') end)
  where id = p_session.id;
end $$;

-- el impostor escapó del voto: NO se revela — la cacería continúa
create or replace function im_escape(p_session game_sessions, p_accused uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update game_sessions set state = state || jsonb_build_object(
    'phase', 'cazeria', 'accused', p_accused,
    'hunts', coalesce((state->>'hunts')::int, 0) + 1,
    'votes', '{}'::jsonb, 'phase_ends_at', null)
    where id = p_session.id;
end $$;

-- cierra el voto: empate/inocente = cacería sigue; impostor señalado = adivinar
create or replace function im_after_voto(p_session game_sessions)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_imp uuid := im_impostor(p_session.id);
  v_top uuid;
  v_ties int;
begin
  select target, count(*) over () into v_top, v_ties from (
    select e.value::uuid as target, count(*) as n
    from jsonb_each_text(v_state->'votes') e
    group by e.value
    order by n desc
  ) s where n = (select max(cnt) from (
    select count(*) as cnt from jsonb_each_text(v_state->'votes') e2 group by e2.value) m)
  limit 1;

  if v_top is null or v_ties > 1 or v_top <> v_imp then
    perform im_escape(p_session, case when v_ties > 1 then null else v_top end);
  else
    update game_sessions set state = v_state || jsonb_build_object(
      'phase', 'adivinar', 'accused', v_imp,
      'phase_ends_at', to_jsonb(now() + interval '45 seconds'))
    where id = p_session.id;
  end if;
end $$;

-- ==================== TRES RONDAS (modo base sin cambios server aparte del launch/submit) ====================
-- (la lógica vive en los dispatchers de abajo)

-- ==================== LOBOS ====================

drop function if exists lb_launch(uuid, uuid);

-- p_opts: { roles: {vidente,protector,bruja,cazador}, wolves: int, offline: bool }
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
  -- barajar roles (los ids ya vienen barajados, doble seguro)
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

  -- moderador (offline): fila propia con TODOS los roles
  if v_offline and v_host is not null then
    insert into player_secrets (game_session_id, player_id, payload)
    values (p_session_id, v_host, jsonb_build_object(
      'role', 'moderador',
      'admin_roles', (select jsonb_object_agg(p.name, s.payload->>'role')
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

-- lb_alive_pids/lb_winner deben ignorar al moderador (offline)
create or replace function lb_alive_pids(p_session game_sessions)
returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(s.player_id), '{}') from player_secrets s
  join players p on p.id = s.player_id
  where s.game_session_id = p_session.id and p.status = 'active'
    and s.payload->>'role' <> 'moderador'
    and not (p_session.state->'dead' ? s.player_id::text);
$$;

create or replace function lb_winner(p_session_id uuid, p_dead jsonb)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_lobos int; v_resto int;
begin
  select count(*) filter (where s.payload->>'role' = 'lobo'),
         count(*) filter (where s.payload->>'role' not in ('lobo', 'moderador'))
    into v_lobos, v_resto
  from player_secrets s join players p on p.id = s.player_id
  where s.game_session_id = p_session_id and p.status = 'active'
    and not (p_dead ? s.player_id::text);
  if v_lobos = 0 then return 'aldea'; end if;
  if v_lobos >= v_resto then return 'lobos'; end if;
  return null;
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

  -- modo offline: reparto persistente; host cierra con reveal de roles
  if coalesce((v_session.state->>'offline')::boolean, false) then
    if not p_force then return; end if;
    if v_phase = 'reparto' then
      perform lb_enter_fin(v_session.id);
    elsif v_phase = 'fin' then
      perform end_game(p_party_id);
    end if;
    return;
  end if;

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

-- ==================== DOS CUARTOS ====================

drop function if exists dc_launch(uuid, uuid);

-- p_opts: { offline: bool } — offline = solo reparto + card-share
create or replace function dc_launch(p_party_id uuid, p_session_id uuid, p_opts jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
declare
  v_ids uuid[];
  v_np int;
  v_roles text[] := array[]::text[];
  v_azules int;
  v_pid uuid;
  v_offline boolean := coalesce((p_opts->>'offline')::boolean, false);
  i int := 0;
begin
  v_ids := (select array_agg(pid order by random()) from unnest(acting_player_ids(p_party_id)) pid);
  v_np := coalesce(array_length(v_ids, 1), 0);
  if v_np < 6 then
    delete from game_sessions where id = p_session_id;
    raise exception 'FALTAN_JUGADORES';
  end if;

  v_azules := v_np / 2 + (v_np % 2);
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

  update game_sessions set state = jsonb_build_object(
    'phase', 'reparto', 'phase_ends_at', null, 'round', 0,
    'offline', v_offline,
    'rooms', (select jsonb_object_agg(pid::text, case when ord <= (v_np + 1) / 2 then 1 else 2 end)
              from (select pid, row_number() over (order by random()) as ord
                    from unnest(v_ids) pid) t),
    'leaders', jsonb_build_object('1', null, '2', null),
    'hostages', jsonb_build_object('1', '[]'::jsonb, '2', '[]'::jsonb),
    'h_count', dc_h_count(v_np, 1), 'usurp', '{}'::jsonb,
    'ready', '{}'::jsonb, 'winner', null, 'bomba', null, 'presidente', null)
    where id = p_session_id;
  if not v_offline then
    perform dc_fix_leaders(p_session_id);
  end if;
end $$;

create or replace function dc_advance(p_party_id uuid, p_force boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_phase text;
  v_pres uuid;
  v_bomba uuid;
begin
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;
  v_phase := v_session.state->>'phase';

  -- offline: reparto persistente → reveal (presidente/bomba, sin winner) → fin
  if coalesce((v_session.state->>'offline')::boolean, false) then
    if not p_force then return; end if;
    if v_phase = 'reparto' then
      select player_id into v_pres from player_secrets
        where game_session_id = v_session.id and payload->>'role' = 'presidente';
      select player_id into v_bomba from player_secrets
        where game_session_id = v_session.id and payload->>'role' = 'bomba';
      update game_sessions set state = state || jsonb_build_object(
        'phase', 'reveal', 'phase_ends_at', null,
        'presidente', v_pres, 'bomba', v_bomba, 'winner', null)
        where id = v_session.id;
    elsif v_phase = 'reveal' then
      perform end_game(p_party_id);
    end if;
    return;
  end if;

  if v_phase = 'reparto' then
    if not p_force and not dc_can_advance(v_session) then return; end if;
    perform dc_enter_ronda(v_session.id, 1);
  elsif v_phase = 'ronda' then
    if not p_force and not dc_can_advance(v_session) then return; end if;
    perform dc_enter_intercambio(v_session.id);
  elsif v_phase = 'intercambio' then
    if not p_force then return; end if;
    perform dc_apply_swap(p_party_id, v_session.id);
  elsif v_phase = 'reveal' then
    if p_force then perform end_game(p_party_id); end if;
  end if;
end $$;

revoke execute on function
  vr_choose(jsonb, uuid, text), vr_step(uuid, game_sessions),
  rl_enter_carta(game_sessions),
  rey_draw(uuid, game_sessions), rey_next(uuid, game_sessions), rey_can_advance(game_sessions),
  sf_mode(jsonb), sf_play_card(uuid, uuid, int), sf_players_with_cards(game_sessions, boolean),
  sf_can_advance(game_sessions), sf_enter_juzgar(uuid, game_sessions),
  sf_after_votes(uuid, game_sessions), sf_next_round(uuid, game_sessions),
  im_start_round(game_sessions), im_escape(game_sessions, uuid), im_after_voto(game_sessions),
  lb_launch(uuid, uuid, jsonb), lb_alive_pids(game_sessions), lb_winner(uuid, jsonb),
  lb_advance(uuid, boolean),
  dc_launch(uuid, uuid, jsonb), dc_advance(uuid, boolean)
from public, anon, authenticated;

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
                         'paranoia','tres-rondas','parejas-a-gritos',
                         'lobos','mision-secreta','dos-cuartos') then
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
      'iv', 0, 'ir', 0, 'timer_s', v_timer, 'streaks', '{}'::jsonb,
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
    v_session.state := jsonb_build_object('deck', v_deck, 'round_idx', -1, 'rules', '[]'::jsonb,
      'countdown_s', least(10, greatest(0, coalesce((p_opts->>'countdown_s')::int, 0))));
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
    if v_session.state->>'phase' = 'reveal' then
      perform rey_next(p_party_id, v_session); -- rota el turno
    else
      perform rey_draw(p_party_id, v_session); -- timeout/force = sacar por él
    end if;

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

  elsif v_session.game_type = 'paranoia' then
    if v_session.state->>'phase' = 'senalar' then
      if not p_force then return; end if;
      perform pa_start_turn(p_party_id, v_session);
    elsif v_session.state->>'phase' = 'decidir' then
      if not p_force and not pa_can_advance(v_session) then return; end if;
      update game_sessions set state = state || jsonb_build_object(
        'phase', 'reveal', 'decision', 'enterrada', 'question', null, 'phase_ends_at', null)
        where id = v_session.id;
    elsif v_session.state->>'phase' = 'reveal' then
      if not p_force then return; end if;
      perform pa_start_turn(p_party_id, v_session);
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
  v_order uuid[];
  v_new jsonb;
  v_idx int;
  v_auth uuid[];
  v_truth text;
  v_team text;
  v_needed int;
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
      v_new := vr_choose(v_state, v_me, p_payload->>'value');
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
    elsif p_action = 'next' and v_phase = 'reveal' then
      if (v_state->'turn_order'->>((v_state->>'turn_idx')::int))::uuid <> v_me
         and not is_host_of(p_party_id) then
        raise exception 'NO_ES_TU_TURNO';
      end if;
      perform rey_next(p_party_id, v_session);
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
  v_needed int;
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
          v_state := vr_choose(v_state, v_turn, null);
          if v_state is null then perform end_game(p_party_id); return; end if;
          update game_sessions set state = v_state where id = v_session.id;
        elsif v_phase = 'carta' then
          perform vr_step(p_party_id, v_session);
        end if;
      elsif v_session.game_type = 'el-rey' then
        if v_phase = 'carta' then
          perform rey_draw(p_party_id, v_session);
        elsif v_phase = 'reveal' then
          perform rey_next(p_party_id, v_session);
        end if;
      end if;
    end if;
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
