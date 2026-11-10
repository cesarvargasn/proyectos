-- ============================================================
-- LA NOCHE — Migración 011: La Manada (cierra Wave 2)
-- Correr DESPUÉS de 010. Requiere cartas: supabase/content/la-manada.sql
-- (npm run content).
--
-- LA MANADA ('la-manada') — estilo Herd Mentality:
--   Todos responden el MISMO prompt (texto libre). Ganan puntos los que
--   quedaron en el grupo más grande (la manada). Como es texto libre, el
--   host AGRUPA a mano las respuestas equivalentes ("perro" = "el perro")
--   antes de revelar. Oveja Negra: si un jugador queda SOLO con su
--   respuesta, carga la 🐑 y no puede ganar (se pasa de ronda en ronda).
--
--   responder(timer_s, default 45) → agrupar (host fusiona grupos, sin
--   timer) → reveal (manada = grupo(s) de tamaño máximo si ≥2 → +100 c/u;
--   host pasa) → siguiente prompt → podio.
--   state = { phase, phase_ends_at, timer_s, deck:[{text}], round_idx,
--             answers:{pid:text}, groups:[{label,members:[pid]}]|null,
--             oveja:pid|null, scores:{pid:int} }
-- ============================================================

-- normaliza una respuesta para agrupar: minúsculas, sin tildes, sin espacios
-- ni puntuación → "Spider-Man", "spiderman" y "spíder man" caen en un grupo.
-- Los sinónimos reales (carro/auto) NO los detecta: eso es el merge manual del host.
create or replace function mn_norm(p_text text)
returns text language sql immutable as $$
  select regexp_replace(
    translate(lower(btrim(coalesce(p_text, ''))),
      'áéíóúüñàèìòùäëïöâêîôû', 'aeiouunaeiouaeioaeiou'),
    '[^a-z0-9]', '', 'g');
$$;

-- agrupa answers por texto normalizado; grupos grandes primero
create or replace function mn_group_answers(p_state jsonb)
returns jsonb language sql immutable as $$
  select coalesce(
    jsonb_agg(jsonb_build_object('label', label, 'members', members)
      order by jsonb_array_length(members) desc, label),
    '[]'::jsonb)
  from (
    select min(e.value) as label, jsonb_agg(e.key) as members
    from jsonb_each_text(p_state->'answers') e
    group by mn_norm(e.value)
  ) s;
$$;

create or replace function mn_enter_phase(p_session game_sessions, p_phase text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_groups jsonb;
  v_max int;
  v_singles text[];
  v_grp jsonb;
  v_pid text;
begin
  v_state := v_state || jsonb_build_object('phase', p_phase);

  if p_phase = 'responder' then
    v_state := v_state || jsonb_build_object(
      'round_idx', coalesce((v_state->>'round_idx')::int, -1) + 1,
      'answers', '{}'::jsonb, 'groups', null,
      'phase_ends_at', to_jsonb(now() + make_interval(secs => coalesce((v_state->>'timer_s')::int, 45))));

  elsif p_phase = 'agrupar' then
    v_state := v_state || jsonb_build_object(
      'groups', mn_group_answers(v_state), 'phase_ends_at', null);

  elsif p_phase = 'reveal' then
    v_groups := v_state->'groups';
    select max(jsonb_array_length(g->'members')) into v_max
      from jsonb_array_elements(v_groups) g;
    -- la manada = grupo(s) de tamaño máximo, solo si son ≥2 (si todos únicos, nadie gana)
    if coalesce(v_max, 0) >= 2 then
      for v_grp in select g from jsonb_array_elements(v_groups) g
                   where jsonb_array_length(g->'members') = v_max loop
        for v_pid in select (m#>>'{}') from jsonb_array_elements(v_grp->'members') m loop
          v_state := jsonb_set(v_state, array['scores', v_pid],
            to_jsonb(coalesce((v_state->'scores'->>v_pid)::int, 0) + 100));
        end loop;
      end loop;
    end if;
    -- oveja negra: si hay EXACTAMENTE un grupo de tamaño 1, la 🐑 pasa a ese jugador
    select array_agg(g->'members'->>0) into v_singles
      from jsonb_array_elements(v_groups) g where jsonb_array_length(g->'members') = 1;
    if coalesce(array_length(v_singles, 1), 0) = 1 then
      v_state := jsonb_set(v_state, '{oveja}', to_jsonb(v_singles[1]));
    end if;
    v_state := v_state || jsonb_build_object('phase_ends_at', null);

  elsif p_phase = 'podio' then
    v_state := v_state || jsonb_build_object('phase_ends_at', null);
  end if;

  return v_state;
end $$;

create or replace function mn_can_advance(p_session game_sessions)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
begin
  if v_state->>'phase' <> 'responder' then return false; end if;
  if coalesce((v_state->>'phase_ends_at')::timestamptz < now(), false) then return true; end if;
  return not exists (
    select 1 from players p
    where p.party_id = p_session.party_id and p.status = 'active'
      and not (v_state->'answers' ? p.id::text));
end $$;

create or replace function mn_next_phase(p_session game_sessions)
returns text language sql stable as $$
  select case p_session.state->>'phase'
    when 'reveal' then case
      when (p_session.state->>'round_idx')::int + 1 < jsonb_array_length(p_session.state->'deck')
      then 'responder' else 'podio' end
    else null end;
$$;

-- host fusiona dos grupos durante 'agrupar' (el fusionado queda al frente)
create or replace function mn_merge(p_session game_sessions, p_a int, p_b int)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb;
  v_groups jsonb;
  v_a jsonb; v_b jsonb; v_merged jsonb; v_rest jsonb;
begin
  select state into v_state from game_sessions where id = p_session.id;
  if v_state->>'phase' <> 'agrupar' then raise exception 'FASE_INVALIDA'; end if;
  v_groups := v_state->'groups';
  if p_a = p_b then return; end if;
  v_a := v_groups->p_a; v_b := v_groups->p_b;
  if v_a is null or v_b is null then raise exception 'GRUPO_INVALIDO'; end if;
  v_merged := jsonb_build_object('label', v_a->>'label',
    'members', (v_a->'members') || (v_b->'members'));
  select coalesce(jsonb_agg(g order by ord), '[]'::jsonb) into v_rest
    from jsonb_array_elements(v_groups) with ordinality t(g, ord)
    where (ord - 1) <> p_a and (ord - 1) <> p_b;
  v_groups := jsonb_build_array(v_merged) || v_rest;
  update game_sessions set state = jsonb_set(v_state, '{groups}', v_groups) where id = p_session.id;
end $$;

revoke execute on function mn_norm(text), mn_group_answers(jsonb), mn_enter_phase(game_sessions, text),
  mn_can_advance(game_sessions), mn_next_phase(game_sessions), mn_merge(game_sessions, int, int)
from public, anon, authenticated;

-- ============ DISPATCHERS (reemplazan a los de 010; +la-manada) ============

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
  v_pid uuid;
  i int;
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  if p_game_type not in ('prueba','yo-nunca','el-senalado','verdad-o-reto','la-ruleta','el-rey',
                         'ocurrencias','mentiras','la-manada','sin-filtro') then
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
                            when 'sin-filtro' then 8 else 15 end)));
  v_timer := least(180, greatest(10, coalesce((p_opts->>'timer_s')::int,
               case p_game_type when 'verdad-o-reto' then 20 when 'ocurrencias' then 90
                                when 'mentiras' then 60 when 'la-manada' then 45
                                when 'sin-filtro' then 45 else 30 end)));
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
      'iv', 0, 'ir', 0, 'timer_s', v_timer,
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
    -- deck de prompts (1 por ronda); todos responden el mismo prompt
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

  elsif p_game_type = 'sin-filtro' then
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
    if v_blancas is null or jsonb_array_length(coalesce(v_blancas, '[]')) < 7 * v_np then
      select coalesce(jsonb_agg(to_jsonb(text_es) order by random()), '[]') into v_blancas
      from content_cards
      where game_type = 'sin-filtro' and card_type = 'blanca' and intensity <= v_intensity and enabled;
    end if;
    if jsonb_array_length(v_deck) = 0 or jsonb_array_length(v_blancas) < 7 * v_np then
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
          where ord > i * 7 and ord <= (i + 1) * 7) s)));
      i := i + 1;
    end loop;
    v_blancas := (select coalesce(jsonb_agg(e), '[]') from (
      select e from jsonb_array_elements(v_blancas) with ordinality t(e, ord)
      where ord > v_np * 7) s);

    v_session.state := jsonb_build_object(
      'negras', v_deck, 'negra_idx', 0, 'blancas', v_blancas, 'timer_s', v_timer,
      'turn_order', to_jsonb(v_ids), 'juez_idx', next_active_turn(to_jsonb(v_ids), -1),
      'plays', '[]'::jsonb, 'winner_idx', null,
      'phase', 'jugar', 'phase_ends_at', to_jsonb(now() + make_interval(secs => v_timer)),
      'scores', (select jsonb_object_agg(pid::text, 0) from unnest(v_ids) pid));
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
    perform rey_draw(p_party_id, v_session);

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
      if not p_force then return; end if; -- host cierra la agrupación
      update game_sessions set state = mn_enter_phase(v_session, 'reveal') where id = v_session.id;
    elsif v_session.state->>'phase' = 'reveal' then
      if not p_force then return; end if;
      v_next := mn_next_phase(v_session);
      if v_next is null then perform end_game(p_party_id); return; end if;
      update game_sessions set state = mn_enter_phase(v_session, v_next) where id = v_session.id;
    elsif v_session.state->>'phase' = 'podio' then
      if p_force then perform end_game(p_party_id); end if;
    end if;

  elsif v_session.game_type = 'sin-filtro' then
    if v_session.state->>'phase' = 'jugar' then
      if not p_force and not sf_can_advance(v_session) then return; end if;
      perform sf_enter_juzgar(p_party_id, v_session);
    elsif v_session.state->>'phase' = 'juzgar' then
      if not p_force then return; end if;
      perform sf_crown(p_party_id, v_session,
        floor(random() * jsonb_array_length(v_session.state->'plays'))::int);
    elsif v_session.state->>'phase' = 'resultado' then
      if not p_force then return; end if;
      perform sf_next_round(p_party_id, v_session);
    elsif v_session.state->>'phase' = 'podio' then
      if p_force then perform end_game(p_party_id); end if;
    end if;
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
  v_idx int;
  v_auth uuid[];
  v_truth text;
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

  if v_session.game_type = 'sin-filtro' then
    if p_action = 'play' and v_phase = 'jugar' then
      if v_me = sf_juez(v_state) then raise exception 'ERES_EL_JUEZ'; end if;
      if exists (select 1 from jsonb_array_elements(v_state->'plays') e where (e->>'pid')::uuid = v_me) then
        raise exception 'YA_JUGASTE';
      end if;
      perform sf_play_card(v_session.id, v_me, (p_payload->>'idx')::int);
      select * into v_session from game_sessions where id = v_session.id;
      if sf_can_advance(v_session) then perform advance_phase(p_party_id, false); end if;

    elsif p_action = 'crown' and v_phase = 'juzgar' then
      if v_me <> sf_juez(v_state) then raise exception 'SOLO_EL_JUEZ'; end if;
      perform sf_crown(p_party_id, v_session, (p_payload->>'idx')::int);

    else
      raise exception 'ACCION_INVALIDA';
    end if;
    return;
  end if;

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

  if v_session.game_type = 'sin-filtro' then
    v_state := v_session.state;
    if v_phase = 'juzgar' then
      if exists (select 1 from players where id = sf_juez(v_state) and is_bot and status = 'active')
         and jsonb_array_length(v_state->'plays') > 0 then
        perform sf_crown(p_party_id, v_session,
          floor(random() * jsonb_array_length(v_state->'plays'))::int);
      end if;
      return;
    elsif v_phase = 'jugar' then
      for v_bot in select id from players where party_id = p_party_id and is_bot and status = 'active' loop
        v_state := (select state from game_sessions where id = v_session.id);
        if v_bot.id <> sf_juez(v_state)
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
        -- set chico → los bots se agrupan solos (para probar manada/oveja)
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
