-- ============================================================
-- LA NOCHE — Migración 008: Deck Curator (transversal)
-- Correr DESPUÉS de 007.
--
-- 1) content_cards.enabled — cartas apagadas no entran a ningún mazo.
-- 2) RPCs de admin (solo cuenta real, nunca anónimos): listar,
--    crear/editar, prender/apagar, borrar cartas desde la UI /cartas.
-- 3) launch_game(party, game, opts jsonb): el host configura al lanzar
--    n_cards (tamaño del mazo), intensity (tope) y timer_s (Señalado
--    voto / VoR elegir). Firma vieja de 2 args se elimina para evitar
--    ambigüedad en PostgREST.
-- ============================================================

alter table content_cards add column if not exists enabled boolean not null default true;

-- ---------- admin ----------

-- admin = sesión real (email+password); los invitados son anónimos.
create or replace function is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and not coalesce((auth.jwt()->>'is_anonymous')::boolean, false);
$$;

create or replace function admin_list_cards(p_game_type text)
returns setof content_cards language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'SOLO_ADMIN'; end if;
  return query select * from content_cards
    where game_type = p_game_type
    order by intensity, card_type, text_es;
end $$;

-- p_id null = crear; con id = editar texto/intensidad/tipo
create or replace function admin_upsert_card(
  p_id uuid, p_game_type text, p_card_type text, p_text_es text, p_intensity int)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_text text := trim(coalesce(p_text_es, ''));
begin
  if not is_admin() then raise exception 'SOLO_ADMIN'; end if;
  if v_text = '' then raise exception 'TEXTO_VACIO'; end if;
  if p_intensity not between 1 and 5 then raise exception 'INTENSIDAD_INVALIDA'; end if;

  if p_id is null then
    insert into content_cards (game_type, card_type, text_es, intensity)
      values (p_game_type, coalesce(nullif(trim(p_card_type), ''), 'default'), v_text, p_intensity)
      returning id into v_id;
  else
    update content_cards
      set text_es = v_text, intensity = p_intensity,
          card_type = coalesce(nullif(trim(p_card_type), ''), 'default')
      where id = p_id returning id into v_id;
    if v_id is null then raise exception 'CARTA_NO_EXISTE'; end if;
  end if;
  return v_id;
end $$;

create or replace function admin_set_enabled(p_id uuid, p_enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'SOLO_ADMIN'; end if;
  update content_cards set enabled = p_enabled where id = p_id;
end $$;

create or replace function admin_delete_card(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'SOLO_ADMIN'; end if;
  delete from content_cards where id = p_id;
end $$;

-- ---------- mazos respetan enabled ----------

create or replace function deck_from_content(p_game_type text, p_intensity int, p_limit int default 15)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(c), '[]') from (
    select jsonb_build_object('text', text_es, 'intensity', intensity) as c
    from content_cards
    where game_type = p_game_type and intensity <= p_intensity and enabled
    order by random() limit p_limit
  ) s;
$$;

create or replace function deck_from_content_typed(p_game_type text, p_card_type text, p_intensity int, p_limit int default 30)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(c), '[]') from (
    select jsonb_build_object('text', text_es, 'intensity', intensity) as c
    from content_cards
    where game_type = p_game_type and card_type = p_card_type
      and intensity <= p_intensity and enabled
    order by random() limit p_limit
  ) s;
$$;

-- ---------- timers configurables ----------

-- Señalado: voto usa state.timer_s (default 30)
create or replace function es_enter_phase(p_session game_sessions, p_phase text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
begin
  v_state := v_state || jsonb_build_object('phase', p_phase);
  if p_phase = 'voto' then
    v_state := v_state || jsonb_build_object(
      'round_idx', coalesce((v_state->>'round_idx')::int, -1) + 1,
      'votes', '{}'::jsonb,
      'phase_ends_at', to_jsonb(now() + make_interval(secs => coalesce((v_state->>'timer_s')::int, 30))));
  elsif p_phase = 'reveal' then
    v_state := v_state || jsonb_build_object('phase_ends_at', null);
  end if;
  return v_state;
end $$;

-- VoR: elegir usa state.timer_s (default 20)
create or replace function vr_enter_elegir(p_session game_sessions)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb := p_session.state;
  v_idx int := next_active_turn(v_state->'turn_order', coalesce((v_state->>'turn_idx')::int, -1));
begin
  if v_idx = -1 then return null; end if;
  return v_state || jsonb_build_object(
    'phase', 'elegir',
    'turn_idx', v_idx,
    'turn_no', coalesce((v_state->>'turn_no')::int, 0) + 1,
    'choice', null, 'card', null, 'rerolled', false,
    'phase_ends_at', to_jsonb(now() + make_interval(secs => coalesce((v_state->>'timer_s')::int, 20))));
end $$;

revoke execute on function is_admin() from public, anon;

-- ---------- launch_game con opciones ----------

drop function if exists launch_game(uuid, text);

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
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  if p_game_type not in ('prueba','yo-nunca','el-senalado','verdad-o-reto','la-ruleta','el-rey') then
    raise exception 'JUEGO_NO_DISPONIBLE';
  end if;
  if exists (select 1 from game_sessions where party_id = p_party_id and status = 'active') then
    raise exception 'YA_HAY_JUEGO';
  end if;

  select coalesce((settings->>'intensity')::int, 2) into v_intensity from parties where id = p_party_id;
  -- overrides del host al lanzar
  v_intensity := least(5, greatest(1, coalesce((p_opts->>'intensity')::int, v_intensity)));
  v_n := least(60, greatest(5, coalesce((p_opts->>'n_cards')::int,
           case p_game_type when 'la-ruleta' then 40 when 'verdad-o-reto' then 30 else 15 end)));
  v_timer := least(120, greatest(10, coalesce((p_opts->>'timer_s')::int,
               case p_game_type when 'verdad-o-reto' then 20 else 30 end)));
  v_ids := acting_player_ids(p_party_id);

  insert into game_sessions (party_id, game_type, state)
    values (p_party_id, p_game_type, '{}'::jsonb)
    returning * into v_session;

  if p_game_type = 'prueba' then
    update game_sessions set state = prueba_enter_phase(v_session, 'secreto') where id = v_session.id;

  elsif p_game_type in ('yo-nunca', 'el-senalado') then
    v_deck := deck_from_content(p_game_type, v_intensity, v_n);
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
    v_state := jsonb_build_object(
      'bank_verdad', deck_from_content_typed(p_game_type, 'verdad', v_intensity, v_n),
      'bank_reto',   deck_from_content_typed(p_game_type, 'reto',   v_intensity, v_n),
      'iv', 0, 'ir', 0, 'timer_s', v_timer,
      'turn_order', to_jsonb(v_ids), 'turn_idx', -1,
      'turn_no', 0, 'total_turns', 2 * array_length(v_ids, 1));
    if jsonb_array_length(v_state->'bank_verdad') = 0 and jsonb_array_length(v_state->'bank_reto') = 0 then
      delete from game_sessions where id = v_session.id;
      raise exception 'SIN_CARTAS';
    end if;
    v_session.state := v_state;
    update game_sessions set state = vr_enter_elegir(v_session) where id = v_session.id;

  elsif p_game_type = 'la-ruleta' then
    select coalesce(jsonb_agg(c), '[]') into v_deck from (
      select jsonb_build_object('text', text_es, 'intensity', intensity, 'card_type', card_type) as c
      from content_cards
      where game_type = 'la-ruleta' and intensity <= v_intensity and enabled
      order by intensity, random() limit v_n
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
