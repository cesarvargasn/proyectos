-- ============================================================
-- LA NOCHE — Migración 007: Wave 1 final (Fase 3, juegos 3-5)
-- Correr DESPUÉS de 006. Requiere cartas para VoR y Ruleta:
-- supabase/content/verdad-o-reto.sql y la-ruleta.sql (npm run content).
-- El Rey no usa content_cards (baraja de 52 generada + reglas en cliente).
--
-- VERDAD O RETO ('verdad-o-reto'):
--   elegir(20s: jugador en turno elige VERDAD/RETO; timeout = random)
--   → carta (sin timer; jugador tapea Cumplí/Paso = done; host 1 reroll
--   por carta) → siguiente turno. 2 vueltas completas y fin.
--   state = { phase, phase_ends_at, bank_verdad, bank_reto, iv, ir,
--             turn_order, turn_idx, turn_no, total_turns, choice,
--             card, rerolled }
--
-- LA RULETA ('la-ruleta'):
--   puro stream (como Yo Nunca banco) pero: mazo 40 cartas en escalación
--   (orden por intensity asc), slots {p1}{p2} resueltos server-side solo
--   con jugadores conectados, card_type 'regla' se acumula en chip bar.
--   state = { phase:'carta', deck, round_idx, slots:{p1:nombre},
--             rules:[texto…] }
--
-- EL REY ('el-rey'):
--   baraja virtual de 52, turno rotativo, el del turno saca carta (30s o
--   cualquiera avanza y saca por él), reglas por rango en el cliente.
--   4º rey (o mazo agotado) = fin.
--   state = { phase:'carta'|'fin', phase_ends_at, deck:[{r,s}], idx,
--             turn_order, turn_idx, kings, last_card }
-- ============================================================

-- ---------- helpers compartidos ----------

-- mazo filtrado también por card_type
create or replace function deck_from_content_typed(p_game_type text, p_card_type text, p_intensity int, p_limit int default 30)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(c), '[]') from (
    select jsonb_build_object('text', text_es, 'intensity', intensity) as c
    from content_cards
    where game_type = p_game_type and card_type = p_card_type and intensity <= p_intensity
    order by random() limit p_limit
  ) s;
$$;

-- siguiente índice de turno con jugador activo (salta idos); -1 si no hay
create or replace function next_active_turn(p_order jsonb, p_idx int)
returns int language plpgsql stable security definer set search_path = public as $$
declare
  v_n int := jsonb_array_length(p_order);
  v_i int := p_idx;
  v_tries int := 0;
begin
  loop
    v_i := (v_i + 1) % v_n;
    v_tries := v_tries + 1;
    if exists (select 1 from players where id = (p_order->>v_i)::uuid and status = 'active') then
      return v_i;
    end if;
    if v_tries >= v_n then return -1; end if;
  end loop;
end $$;

-- ---------- verdad o reto ----------

create or replace function vr_enter_elegir(p_session game_sessions)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_idx int := next_active_turn(v_state->'turn_order', coalesce((v_state->>'turn_idx')::int, -1));
begin
  if v_idx = -1 then return null; end if; -- nadie activo
  return v_state || jsonb_build_object(
    'phase', 'elegir',
    'turn_idx', v_idx,
    'turn_no', coalesce((v_state->>'turn_no')::int, 0) + 1,
    'choice', null, 'card', null, 'rerolled', false,
    'phase_ends_at', to_jsonb(now() + interval '20 seconds'));
end $$;

-- saca carta del banco elegido (si se agotó usa el otro; ambos = null)
create or replace function vr_pick_card(p_state jsonb, p_choice text)
returns jsonb language plpgsql immutable as $$
declare
  v_key text := case p_choice when 'verdad' then 'iv' else 'ir' end;
  v_bank text := 'bank_' || p_choice;
  v_idx int := coalesce((p_state->>v_key)::int, 0);
  v_other text := case p_choice when 'verdad' then 'reto' else 'verdad' end;
begin
  if v_idx >= jsonb_array_length(p_state->v_bank) then
    -- banco agotado → intenta el otro (una sola vez)
    v_key := case v_other when 'verdad' then 'iv' else 'ir' end;
    v_bank := 'bank_' || v_other;
    v_idx := coalesce((p_state->>v_key)::int, 0);
    if v_idx >= jsonb_array_length(p_state->v_bank) then return null; end if;
    p_choice := v_other;
  end if;
  return p_state || jsonb_build_object(
    'phase', 'carta',
    'choice', p_choice,
    'card', p_state->v_bank->v_idx,
    v_key, v_idx + 1,
    'phase_ends_at', null);
end $$;

create or replace function vr_can_advance(p_session game_sessions)
returns boolean language sql stable as $$
  select p_session.state->>'phase' = 'elegir'
     and coalesce((p_session.state->>'phase_ends_at')::timestamptz < now(), false);
$$;

-- avanza VoR: desde elegir = elección random; desde carta = siguiente turno
create or replace function vr_step(p_party_id uuid, p_session game_sessions)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_new jsonb;
begin
  if v_state->>'phase' = 'elegir' then
    v_new := vr_pick_card(v_state, case when random() < 0.5 then 'verdad' else 'reto' end);
  else -- carta → siguiente turno o fin
    if coalesce((v_state->>'turn_no')::int, 0) >= coalesce((v_state->>'total_turns')::int, 0) then
      perform end_game(p_party_id); return;
    end if;
    v_new := vr_enter_elegir(p_session);
  end if;
  if v_new is null then perform end_game(p_party_id); return; end if;
  update game_sessions set state = v_new where id = p_session.id;
end $$;

-- ---------- la ruleta ----------

create or replace function rl_enter_carta(p_session game_sessions)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_idx int := coalesce((v_state->>'round_idx')::int, -1) + 1;
  v_card jsonb;
  v_text text;
  v_slots jsonb := '{}'::jsonb;
  v_names text[];
begin
  if v_idx >= jsonb_array_length(v_state->'deck') then return null; end if;
  v_card := v_state->'deck'->v_idx;
  v_text := v_card->>'text';

  -- slots SOLO con jugadores conectados en este momento
  select array_agg(name order by random()) into v_names
  from players where party_id = p_session.party_id and status = 'active';
  if position('{p1}' in v_text) > 0 and coalesce(array_length(v_names,1),0) >= 1 then
    v_slots := v_slots || jsonb_build_object('p1', v_names[1]);
  end if;
  if position('{p2}' in v_text) > 0 and coalesce(array_length(v_names,1),0) >= 2 then
    v_slots := v_slots || jsonb_build_object('p2', v_names[2]);
  end if;

  v_state := v_state || jsonb_build_object(
    'phase', 'carta', 'round_idx', v_idx, 'slots', v_slots, 'phase_ends_at', null);

  -- regla persistente → chip bar hasta el fin del juego
  if v_card->>'card_type' = 'regla' then
    v_state := jsonb_set(v_state, '{rules}', coalesce(v_state->'rules', '[]'::jsonb) || to_jsonb(v_text));
  end if;
  return v_state;
end $$;

-- ---------- el rey ----------

create or replace function rey_draw(p_party_id uuid, p_session game_sessions)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_idx int := coalesce((v_state->>'idx')::int, 0);
  v_card jsonb := v_state->'deck'->v_idx;
  v_kings int := coalesce((v_state->>'kings')::int, 0);
  v_turn int;
begin
  if v_card is null then perform end_game(p_party_id); return; end if;
  if v_card->>'r' = 'K' then v_kings := v_kings + 1; end if;

  v_state := v_state || jsonb_build_object('last_card', v_card, 'idx', v_idx + 1, 'kings', v_kings);

  if v_kings >= 4 or v_idx + 1 >= jsonb_array_length(v_state->'deck') then
    v_state := v_state || jsonb_build_object('phase', 'fin', 'phase_ends_at', null);
  else
    v_turn := next_active_turn(v_state->'turn_order', (v_state->>'turn_idx')::int);
    if v_turn = -1 then perform end_game(p_party_id); return; end if;
    v_state := v_state || jsonb_build_object(
      'turn_idx', v_turn, 'phase_ends_at', to_jsonb(now() + interval '30 seconds'));
  end if;
  update game_sessions set state = v_state where id = p_session.id;
end $$;

create or replace function rey_can_advance(p_session game_sessions)
returns boolean language sql stable as $$
  select p_session.state->>'phase' = 'carta'
     and coalesce((p_session.state->>'phase_ends_at')::timestamptz < now(), false);
$$;

revoke execute on function deck_from_content_typed(text, text, int, int),
  next_active_turn(jsonb, int), vr_enter_elegir(game_sessions),
  vr_pick_card(jsonb, text), vr_can_advance(game_sessions),
  vr_step(uuid, game_sessions), rl_enter_carta(game_sessions),
  rey_draw(uuid, game_sessions), rey_can_advance(game_sessions)
from public, anon, authenticated;

-- ---------- dispatchers (reemplazan a los de 006) ----------

create or replace function launch_game(p_party_id uuid, p_game_type text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_intensity int;
  v_deck jsonb;
  v_ids uuid[];
  v_state jsonb;
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  if p_game_type not in ('prueba','yo-nunca','el-senalado','verdad-o-reto','la-ruleta','el-rey') then
    raise exception 'JUEGO_NO_DISPONIBLE';
  end if;
  if exists (select 1 from game_sessions where party_id = p_party_id and status = 'active') then
    raise exception 'YA_HAY_JUEGO';
  end if;

  select coalesce((settings->>'intensity')::int, 2) into v_intensity from parties where id = p_party_id;
  v_ids := acting_player_ids(p_party_id);

  insert into game_sessions (party_id, game_type, state)
    values (p_party_id, p_game_type, '{}'::jsonb)
    returning * into v_session;

  if p_game_type = 'prueba' then
    update game_sessions set state = prueba_enter_phase(v_session, 'secreto') where id = v_session.id;

  elsif p_game_type in ('yo-nunca', 'el-senalado') then
    v_deck := deck_from_content(p_game_type, v_intensity, 15);
    if jsonb_array_length(v_deck) = 0 then
      delete from game_sessions where id = v_session.id;
      raise exception 'SIN_CARTAS';
    end if;
    v_session.state := jsonb_build_object('deck', v_deck, 'round_idx', -1);
    if p_game_type = 'yo-nunca' then
      update game_sessions set state = yn_enter_phase(v_session, 'pregunta') where id = v_session.id;
    else
      update game_sessions set state = es_enter_phase(v_session, 'voto') where id = v_session.id;
    end if;

  elsif p_game_type = 'verdad-o-reto' then
    v_state := jsonb_build_object(
      'bank_verdad', deck_from_content_typed(p_game_type, 'verdad', v_intensity, 30),
      'bank_reto',   deck_from_content_typed(p_game_type, 'reto',   v_intensity, 30),
      'iv', 0, 'ir', 0,
      'turn_order', to_jsonb(v_ids), 'turn_idx', -1,
      'turn_no', 0, 'total_turns', 2 * array_length(v_ids, 1));
    if jsonb_array_length(v_state->'bank_verdad') = 0 and jsonb_array_length(v_state->'bank_reto') = 0 then
      delete from game_sessions where id = v_session.id;
      raise exception 'SIN_CARTAS';
    end if;
    v_session.state := v_state;
    update game_sessions set state = vr_enter_elegir(v_session) where id = v_session.id;

  elsif p_game_type = 'la-ruleta' then
    -- escalación: intensidad ascendente, random dentro de cada nivel
    select coalesce(jsonb_agg(c), '[]') into v_deck from (
      select jsonb_build_object('text', text_es, 'intensity', intensity, 'card_type', card_type) as c
      from content_cards
      where game_type = 'la-ruleta' and intensity <= v_intensity
      order by intensity, random() limit 40
    ) s;
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
    if not p_force then return; end if; -- solo host pasa carta
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
    perform rey_draw(p_party_id, v_session); -- timeout/force = sacar por él
  end if;
end $$;

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
begin
  if v_me is null then raise exception 'NO_MIEMBRO'; end if;
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then raise exception 'SIN_JUEGO'; end if;
  v_state := v_session.state;
  v_phase := v_state->>'phase';

  -- ----- prueba (igual que 003..006) -----
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

  -- ----- el-senalado (igual que 006) -----
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

  -- ----- verdad-o-reto -----
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

  -- ----- el-rey -----
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

  -- yo-nunca / la-ruleta: sin acciones (banco de cartas)
  raise exception 'ACCION_INVALIDA';
end $$;

create or replace function dev_bot_tick(p_party_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session game_sessions;
  v_state jsonb;
  v_phase text;
  v_bot record;
  v_targets uuid[];
  v_words text[] := array['épica','confusa','legendaria','sudorosa','inolvidable','rara','gloriosa'];
  v_order uuid[];
  v_turn uuid;
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  select * into v_session from active_session(p_party_id);
  if v_session.id is null then return; end if;
  v_phase := v_session.state->>'phase';

  -- juegos por turno: si el turno es de un bot, actúa y listo
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
    end if;
  end loop;

  select * into v_session from game_sessions where id = v_session.id;
  if v_session.status = 'active' then
    if (v_session.game_type = 'prueba' and prueba_can_advance(v_session))
       or (v_session.game_type = 'el-senalado' and es_can_advance(v_session)) then
      perform advance_phase(p_party_id, false);
    end if;
  end if;
end $$;
