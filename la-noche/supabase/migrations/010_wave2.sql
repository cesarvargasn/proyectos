-- ============================================================
-- LA NOCHE — Migración 010: Wave 2 (Ocurrencias + Mentiras + Sin Filtro)
-- Correr DESPUÉS de 009. Requiere cartas:
--   supabase/content/ocurrencias.sql, mentiras.sql, sin-filtro.sql
--   (npm run content).
--
-- OCURRENCIAS ('ocurrencias') — estilo Quiplash:
--   N jugadores → N prompts; cada prompt tiene EXACTAMENTE 2 autores
--   (jugador i y jugador i+1 en ciclo), cada jugador escribe 2.
--   escribir(timer_s, default 90) → por cada prompt: duelo(25s, votan
--   todos menos los 2 autores) → resultado (+100/voto; APLASTADA +100
--   si te llevas todos los votos; host pasa) → podio.
--   Sin respuesta a tiempo = "[se quedó pensando]".
--   state = { phase, phase_ends_at, timer_s, players:[pid], prompts,
--             answers:{idx:{pid:text}}, duel_idx, votes:{pid:author},
--             scores:{pid:int} }
--
-- MENTIRAS ('mentiras') — estilo Fibbage:
--   cartas card_type 'pregunta' con meta {"answer":"…"} (la verdad).
--   mentir(timer_s, default 60; mentira == verdad se rechaza) →
--   elegir(30s; mentiras idénticas se fusionan; no puedes elegir la
--   tuya) → reveal (verdad +100; tu mentira +50 por víctima; host
--   pasa) → siguiente pregunta → podio.
--   state = { phase, phase_ends_at, timer_s, deck:[{text,answer}],
--             round_idx, lies:{pid:text},
--             options:[{text,authors:[pid],is_truth?}],
--             picks:{pid:idx}, scores:{pid:int} }
--
-- SIN FILTRO ('sin-filtro') — estilo CAH, 100% original:
--   cartas 'negra' (frase con ___) y 'blanca'. Mano de 7 en
--   player_secrets (devtools-proof), juez rotativo.
--   jugar(timer_s, default 45; timeout = carta random por ti) →
--   juzgar (juez corona; anónimo hasta el resultado) → resultado
--   (host pasa) → siguiente negra → podio. Ganador de ronda +1.
--   state = { phase, phase_ends_at, timer_s, negras, negra_idx,
--             blancas:[text], turn_order, juez_idx,
--             plays:[{pid,text}], winner_idx, scores:{pid:int} }
-- ============================================================

-- ============ OCURRENCIAS ============

-- autores del prompt i: players[i] y players[(i+1) % n]
create or replace function oc_authors(p_state jsonb, p_idx int)
returns uuid[] language sql immutable as $$
  select array[
    (p_state->'players'->>p_idx)::uuid,
    (p_state->'players'->>((p_idx + 1) % jsonb_array_length(p_state->'players')))::uuid];
$$;

create or replace function oc_enter_phase(p_session game_sessions, p_phase text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_d int;
  v_n int := jsonb_array_length(v_state->'players');
  v_a1 uuid; v_a2 uuid;
  v1 int; v2 int;
  s1 int; s2 int;
begin
  v_state := v_state || jsonb_build_object('phase', p_phase);

  if p_phase = 'escribir' then
    v_state := v_state || jsonb_build_object(
      'phase_ends_at', to_jsonb(now() + make_interval(secs => coalesce((v_state->>'timer_s')::int, 90))));

  elsif p_phase = 'duelo' then
    v_state := v_state || jsonb_build_object(
      'duel_idx', coalesce((v_state->>'duel_idx')::int, -1) + 1,
      'votes', '{}'::jsonb,
      'phase_ends_at', to_jsonb(now() + interval '25 seconds'));

  elsif p_phase = 'resultado' then
    -- scoring del duelo actual (una sola vez, al entrar)
    v_d := (v_state->>'duel_idx')::int;
    v_a1 := (v_state->'players'->>v_d)::uuid;
    v_a2 := (v_state->'players'->>((v_d + 1) % v_n))::uuid;
    select count(*) into v1 from jsonb_each_text(v_state->'votes') e where e.value = v_a1::text;
    select count(*) into v2 from jsonb_each_text(v_state->'votes') e where e.value = v_a2::text;
    s1 := 100 * v1 + case when v1 > 0 and v2 = 0 then 100 else 0 end;
    s2 := 100 * v2 + case when v2 > 0 and v1 = 0 then 100 else 0 end;
    v_state := jsonb_set(v_state, array['scores', v_a1::text],
      to_jsonb(coalesce((v_state->'scores'->>(v_a1::text))::int, 0) + s1));
    v_state := jsonb_set(v_state, array['scores', v_a2::text],
      to_jsonb(coalesce((v_state->'scores'->>(v_a2::text))::int, 0) + s2));
    v_state := v_state || jsonb_build_object('phase_ends_at', null);

  elsif p_phase = 'podio' then
    v_state := v_state || jsonb_build_object('phase_ends_at', null);
  end if;

  return v_state;
end $$;

create or replace function oc_can_advance(p_session game_sessions)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_phase text := v_state->>'phase';
  v_n int := jsonb_array_length(v_state->'players');
  v_d int;
  v_auth uuid[];
  v_pid uuid;
  i int;
begin
  if coalesce((v_state->>'phase_ends_at')::timestamptz < now(), false) then return true; end if;

  if v_phase = 'escribir' then
    -- listos cuando cada autor ACTIVO respondió sus prompts
    for i in 0..(v_n - 1) loop
      v_auth := oc_authors(v_state, i);
      foreach v_pid in array v_auth loop
        if exists (select 1 from players where id = v_pid and status = 'active')
           and not (coalesce(v_state->'answers'->(i::text), '{}'::jsonb) ? v_pid::text) then
          return false;
        end if;
      end loop;
    end loop;
    return true;

  elsif v_phase = 'duelo' then
    v_d := (v_state->>'duel_idx')::int;
    v_auth := oc_authors(v_state, v_d);
    -- todos los activos no-autores votaron
    return not exists (
      select 1 from players p
      where p.party_id = p_session.party_id and p.status = 'active'
        and p.id <> all (v_auth)
        and not (v_state->'votes' ? p.id::text));
  end if;

  return false;
end $$;

create or replace function oc_next_phase(p_session game_sessions)
returns text language sql stable as $$
  select case p_session.state->>'phase'
    when 'escribir' then 'duelo'
    when 'duelo' then 'resultado'
    when 'resultado' then case
      when (p_session.state->>'duel_idx')::int + 1 < jsonb_array_length(p_session.state->'prompts')
      then 'duelo' else 'podio' end
    else null end;
$$;

-- ============ MENTIRAS ============

create or replace function mt_enter_phase(p_session game_sessions, p_phase text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_truth text;
  v_opts jsonb;
  v_opt jsonb;
  v_cnt int;
  v_pid text;
  i int;
begin
  v_state := v_state || jsonb_build_object('phase', p_phase);

  if p_phase = 'mentir' then
    v_state := v_state || jsonb_build_object(
      'round_idx', coalesce((v_state->>'round_idx')::int, -1) + 1,
      'lies', '{}'::jsonb, 'options', null, 'picks', '{}'::jsonb,
      'phase_ends_at', to_jsonb(now() + make_interval(secs => coalesce((v_state->>'timer_s')::int, 60))));

  elsif p_phase = 'elegir' then
    v_truth := v_state->'deck'->((v_state->>'round_idx')::int)->>'answer';
    -- mentiras idénticas (normalizadas) se fusionan; la verdad entra como una opción más
    select coalesce(jsonb_agg(o order by random()), '[]') into v_opts from (
      select jsonb_build_object('text', min(e.value), 'authors',
               jsonb_agg(to_jsonb(e.key)), 'is_truth', false) as o
      from jsonb_each_text(v_state->'lies') e
      where lower(btrim(e.value)) <> lower(btrim(v_truth))
      group by lower(btrim(e.value))
      union all
      select jsonb_build_object('text', v_truth, 'authors', '[]'::jsonb, 'is_truth', true)
    ) s;
    v_state := v_state || jsonb_build_object(
      'options', v_opts, 'picks', '{}'::jsonb,
      'phase_ends_at', to_jsonb(now() + interval '30 seconds'));

  elsif p_phase = 'reveal' then
    -- scoring: verdad +100 al que la eligió; mentira +50 por víctima a sus autores
    for i in 0..(jsonb_array_length(v_state->'options') - 1) loop
      v_opt := v_state->'options'->i;
      select count(*) into v_cnt from jsonb_each_text(v_state->'picks') e where e.value = i::text;
      if (v_opt->>'is_truth')::boolean then
        for v_pid in select e.key from jsonb_each_text(v_state->'picks') e where e.value = i::text loop
          v_state := jsonb_set(v_state, array['scores', v_pid],
            to_jsonb(coalesce((v_state->'scores'->>v_pid)::int, 0) + 100));
        end loop;
      elsif v_cnt > 0 then
        for v_pid in select (a#>>'{}') from jsonb_array_elements(v_opt->'authors') a loop
          v_state := jsonb_set(v_state, array['scores', v_pid],
            to_jsonb(coalesce((v_state->'scores'->>v_pid)::int, 0) + 50 * v_cnt));
        end loop;
      end if;
    end loop;
    v_state := v_state || jsonb_build_object('phase_ends_at', null);

  elsif p_phase = 'podio' then
    v_state := v_state || jsonb_build_object('phase_ends_at', null);
  end if;

  return v_state;
end $$;

create or replace function mt_can_advance(p_session game_sessions)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_phase text := v_state->>'phase';
  v_key text := case v_phase when 'mentir' then 'lies' when 'elegir' then 'picks' else null end;
begin
  if v_key is null then return false; end if;
  if coalesce((v_state->>'phase_ends_at')::timestamptz < now(), false) then return true; end if;
  return not exists (
    select 1 from players p
    where p.party_id = p_session.party_id and p.status = 'active'
      and not (v_state->v_key ? p.id::text));
end $$;

create or replace function mt_next_phase(p_session game_sessions)
returns text language sql stable as $$
  select case p_session.state->>'phase'
    when 'mentir' then 'elegir'
    when 'elegir' then 'reveal'
    when 'reveal' then case
      when (p_session.state->>'round_idx')::int + 1 < jsonb_array_length(p_session.state->'deck')
      then 'mentir' else 'podio' end
    else null end;
$$;

-- ============ SIN FILTRO ============

-- juega una carta de la mano secreta (p_idx null = random), con refill
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

  v_hand := v_hand - v_idx;
  -- refill del mazo de blancas si queda
  if jsonb_array_length(v_state->'blancas') > 0 then
    v_hand := v_hand || jsonb_build_array(v_state->'blancas'->0);
    v_state := jsonb_set(v_state, '{blancas}', (v_state->'blancas') - 0);
  end if;

  update player_secrets set payload = jsonb_build_object('hand', v_hand)
    where game_session_id = p_session_id and player_id = p_pid;
  v_state := jsonb_set(v_state, '{plays}',
    (v_state->'plays') || jsonb_build_object('pid', p_pid, 'text', v_card));
  update game_sessions set state = v_state where id = p_session_id;
end $$;

create or replace function sf_juez(p_state jsonb)
returns uuid language sql immutable as $$
  select (p_state->'turn_order'->>((p_state->>'juez_idx')::int))::uuid;
$$;

create or replace function sf_can_advance(p_session game_sessions)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
begin
  if v_state->>'phase' <> 'jugar' then return false; end if;
  if coalesce((v_state->>'phase_ends_at')::timestamptz < now(), false) then return true; end if;
  return jsonb_array_length(v_state->'plays') >= (
    select count(*) from players
    where party_id = p_session.party_id and status = 'active' and id <> sf_juez(v_state));
end $$;

-- entra a juzgar: auto-juega random por los que no jugaron y baraja las jugadas
create or replace function sf_enter_juzgar(p_party_id uuid, p_session game_sessions)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb;
  v_pid uuid;
begin
  for v_pid in
    select p.id from players p
    where p.party_id = p_party_id and p.status = 'active'
      and p.id <> sf_juez(p_session.state)
      and not exists (select 1 from jsonb_array_elements(p_session.state->'plays') e
                      where (e->>'pid')::uuid = p.id)
  loop
    perform sf_play_card(p_session.id, v_pid, null);
  end loop;

  select state into v_state from game_sessions where id = p_session.id;
  v_state := jsonb_set(v_state, '{plays}',
    coalesce((select jsonb_agg(e order by random()) from jsonb_array_elements(v_state->'plays') e), '[]'));
  v_state := v_state || jsonb_build_object('phase', 'juzgar', 'phase_ends_at', null);
  update game_sessions set state = v_state where id = p_session.id;
end $$;

create or replace function sf_crown(p_party_id uuid, p_session game_sessions, p_idx int)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_winner text;
begin
  if jsonb_array_length(v_state->'plays') = 0 then
    perform end_game(p_party_id); return;
  end if;
  if v_state->'plays'->p_idx is null then raise exception 'JUGADA_INVALIDA'; end if;
  v_winner := v_state->'plays'->p_idx->>'pid';
  v_state := jsonb_set(v_state, array['scores', v_winner],
    to_jsonb(coalesce((v_state->'scores'->>v_winner)::int, 0) + 1));
  v_state := v_state || jsonb_build_object('phase', 'resultado', 'winner_idx', p_idx, 'phase_ends_at', null);
  update game_sessions set state = v_state where id = p_session.id;
end $$;

-- siguiente negra (rotando juez) o podio
create or replace function sf_next_round(p_party_id uuid, p_session game_sessions)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_juez int;
begin
  if (v_state->>'negra_idx')::int + 1 >= jsonb_array_length(v_state->'negras') then
    v_state := v_state || jsonb_build_object('phase', 'podio', 'phase_ends_at', null);
    update game_sessions set state = v_state where id = p_session.id;
    return;
  end if;
  v_juez := next_active_turn(v_state->'turn_order', (v_state->>'juez_idx')::int);
  if v_juez = -1 then perform end_game(p_party_id); return; end if;
  v_state := v_state || jsonb_build_object(
    'phase', 'jugar',
    'negra_idx', (v_state->>'negra_idx')::int + 1,
    'juez_idx', v_juez, 'plays', '[]'::jsonb, 'winner_idx', null,
    'phase_ends_at', to_jsonb(now() + make_interval(secs => coalesce((v_state->>'timer_s')::int, 45))));
  update game_sessions set state = v_state where id = p_session.id;
end $$;

revoke execute on function oc_authors(jsonb, int), oc_enter_phase(game_sessions, text),
  oc_can_advance(game_sessions), oc_next_phase(game_sessions),
  mt_enter_phase(game_sessions, text), mt_can_advance(game_sessions),
  mt_next_phase(game_sessions), sf_play_card(uuid, uuid, int), sf_juez(jsonb),
  sf_can_advance(game_sessions), sf_enter_juzgar(uuid, game_sessions),
  sf_crown(uuid, game_sessions, int), sf_next_round(uuid, game_sessions)
from public, anon, authenticated;

-- ============ DISPATCHERS (reemplazan a los de 008/009) ============

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
                         'ocurrencias','mentiras','sin-filtro') then
    raise exception 'JUEGO_NO_DISPONIBLE';
  end if;
  if exists (select 1 from game_sessions where party_id = p_party_id and status = 'active') then
    raise exception 'YA_HAY_JUEGO';
  end if;

  select coalesce((settings->>'intensity')::int, 2) into v_intensity from parties where id = p_party_id;
  v_intensity := least(5, greatest(1, coalesce((p_opts->>'intensity')::int, v_intensity)));
  v_n := least(60, greatest(3, coalesce((p_opts->>'n_cards')::int,
           case p_game_type when 'la-ruleta' then 40 when 'verdad-o-reto' then 30
                            when 'mentiras' then 6 when 'sin-filtro' then 8 else 15 end)));
  v_timer := least(180, greatest(10, coalesce((p_opts->>'timer_s')::int,
               case p_game_type when 'verdad-o-reto' then 20 when 'ocurrencias' then 90
                                when 'mentiras' then 60 when 'sin-filtro' then 45 else 30 end)));
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
    -- un prompt por jugador; cada prompt lo escriben 2 (i, i+1 en ciclo)
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
      raise exception 'SIN_CARTAS'; -- se necesita 1 prompt por jugador
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
      raise exception 'SIN_CARTAS'; -- solo valen cartas con meta.answer
    end if;
    v_session.state := jsonb_build_object(
      'deck', v_deck, 'round_idx', -1, 'timer_s', v_timer,
      'scores', (select jsonb_object_agg(pid::text, 0) from unnest(v_ids) pid));
    update game_sessions set state = mt_enter_phase(v_session, 'mentir') where id = v_session.id;

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
      raise exception 'SIN_CARTAS'; -- se necesitan negras y ≥7 blancas por jugador
    end if;

    -- repartir manos de 7 (secretas, devtools-proof)
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

  elsif v_session.game_type = 'sin-filtro' then
    if v_session.state->>'phase' = 'jugar' then
      if not p_force and not sf_can_advance(v_session) then return; end if;
      perform sf_enter_juzgar(p_party_id, v_session);
    elsif v_session.state->>'phase' = 'juzgar' then
      -- solo el host fuerza (juez ido): corona una jugada random
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

  -- ----- prueba (igual que 003..007) -----
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

  -- ----- el-senalado (igual que 006/007) -----
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

  -- ----- verdad-o-reto (igual que 007) -----
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

  -- ----- el-rey (igual que 007) -----
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

  -- ----- ocurrencias -----
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

  -- ----- mentiras -----
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

  -- ----- sin-filtro -----
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
  v_frases text[] := array['un mariachi en huelga','la abuela con jetlag','un tamal radiactivo',
    'el ex de todo el mundo','un bus sin frenos','la resaca eterna','un gato con deudas',
    'el DJ del pueblo','una arepa gigante','el vecino chismoso'];
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

  -- sin-filtro: juez bot corona; bots juegan carta
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
    end if;
  end loop;

  select * into v_session from game_sessions where id = v_session.id;
  if v_session.status = 'active' then
    if (v_session.game_type = 'prueba' and prueba_can_advance(v_session))
       or (v_session.game_type = 'el-senalado' and es_can_advance(v_session))
       or (v_session.game_type = 'ocurrencias' and oc_can_advance(v_session))
       or (v_session.game_type = 'mentiras' and mt_can_advance(v_session)) then
      perform advance_phase(p_party_id, false);
    end if;
  end if;
end $$;
