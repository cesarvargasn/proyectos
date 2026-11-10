-- ============================================================
-- LA NOCHE — Migración 001: Spine (Fase 1)
-- Correr UNA vez en Supabase SQL Editor.
-- Arquitectura: Postgres = única fuente de verdad.
-- Toda mutación via RPC SECURITY DEFINER. Cliente nunca escribe.
-- ============================================================

-- ---------- TABLAS ----------

create table parties (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (code ~ '^[A-Z]{4}$'),
  status      text not null default 'lobby' check (status in ('lobby','in_game','ended')),
  settings    jsonb not null default '{"mode":"social","intensity":2}',
  created_at  timestamptz not null default now()
);

create table players (
  id           uuid primary key default gen_random_uuid(),
  party_id     uuid not null references parties(id) on delete cascade,
  auth_user_id uuid,                          -- null para bots
  name         text not null check (char_length(name) between 1 and 20),
  avatar       jsonb not null default '{}',   -- {symbol, color}
  is_host      boolean not null default false,
  is_bot       boolean not null default false,
  status       text not null default 'active' check (status in ('active','left','kicked')),
  last_seen    timestamptz not null default now(),
  joined_at    timestamptz not null default now(),
  unique (party_id, auth_user_id)
);

create table game_sessions (
  id          uuid primary key default gen_random_uuid(),
  party_id    uuid not null references parties(id) on delete cascade,
  game_type   text not null,
  status      text not null default 'active' check (status in ('active','ended')),
  state       jsonb not null default '{}',
  created_at  timestamptz not null default now()
);

-- REGLA MÁS IMPORTANTE DEL PROYECTO:
-- secretos solo aquí, RLS deja SELECT solo de tus propias filas.
create table player_secrets (
  id              uuid primary key default gen_random_uuid(),
  game_session_id uuid not null references game_sessions(id) on delete cascade,
  player_id       uuid not null references players(id) on delete cascade,
  payload         jsonb not null default '{}',
  created_at      timestamptz not null default now()
);

create table content_cards (
  id         uuid primary key default gen_random_uuid(),
  game_type  text not null,
  card_type  text not null default 'default',
  text_es    text not null,
  text_en    text,
  intensity  int not null default 2 check (intensity between 1 and 5),
  tags       text[] not null default '{}',
  meta       jsonb not null default '{}'
);

create index idx_players_party on players(party_id);
create index idx_sessions_party on game_sessions(party_id);
create index idx_secrets_session on player_secrets(game_session_id);
create index idx_cards_game on content_cards(game_type, intensity);

-- ---------- HELPERS ----------

-- ¿El usuario autenticado es miembro activo de esta party?
create or replace function is_member(p_party_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from players
    where party_id = p_party_id
      and auth_user_id = auth.uid()
      and status = 'active'
  );
$$;

create or replace function is_host_of(p_party_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from players
    where party_id = p_party_id
      and auth_user_id = auth.uid()
      and status = 'active'
      and is_host
  );
$$;

-- ---------- RLS ----------

alter table parties        enable row level security;
alter table players        enable row level security;
alter table game_sessions  enable row level security;
alter table player_secrets enable row level security;
alter table content_cards  enable row level security;

-- Lectura: solo miembros. Escritura: NADIE directo (solo RPCs).
create policy parties_select on parties for select to authenticated
  using (is_member(id));

create policy players_select on players for select to authenticated
  using (is_member(party_id));

create policy sessions_select on game_sessions for select to authenticated
  using (is_member(party_id));

-- Secretos: SOLO tus propias filas. Nunca las de otros.
create policy secrets_select_own on player_secrets for select to authenticated
  using (player_id in (select id from players where auth_user_id = auth.uid()));

-- content_cards: cero acceso de cliente; el server reparte via RPC.

-- ---------- RPCs ----------

-- Crear noche: genera código único, crea party + host.
create or replace function create_party(p_name text, p_avatar jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  v_party parties;
  v_player players;
begin
  if auth.uid() is null then raise exception 'no autenticado'; end if;
  loop
    v_code := (
      select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ', (floor(random()*24)+1)::int, 1), '')
      from generate_series(1,4)
    );
    exit when not exists (select 1 from parties where code = v_code and status <> 'ended');
  end loop;

  insert into parties (code) values (v_code) returning * into v_party;
  insert into players (party_id, auth_user_id, name, avatar, is_host)
    values (v_party.id, auth.uid(), trim(p_name), p_avatar, true)
    returning * into v_player;

  return jsonb_build_object('party_id', v_party.id, 'code', v_party.code, 'player_id', v_player.id);
end $$;

-- Unirse con código. Reconexión: si ya eras miembro, te reactiva.
create or replace function join_party(p_code text, p_name text, p_avatar jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_party parties;
  v_player players;
  v_count int;
begin
  if auth.uid() is null then raise exception 'no autenticado'; end if;

  select * into v_party from parties
    where code = upper(trim(p_code)) and status <> 'ended';
  if not found then raise exception 'CODIGO_INVALIDO'; end if;

  -- ¿ya estaba? (reconexión / volvió)
  select * into v_player from players
    where party_id = v_party.id and auth_user_id = auth.uid();
  if found then
    if v_player.status = 'kicked' then raise exception 'EXPULSADO'; end if;
    update players set status = 'active', last_seen = now() where id = v_player.id;
    return jsonb_build_object('party_id', v_party.id, 'code', v_party.code, 'player_id', v_player.id);
  end if;

  select count(*) into v_count from players
    where party_id = v_party.id and status = 'active';
  if v_count >= 20 then raise exception 'SALA_LLENA'; end if;

  insert into players (party_id, auth_user_id, name, avatar)
    values (v_party.id, auth.uid(), trim(p_name), p_avatar)
    returning * into v_player;

  return jsonb_build_object('party_id', v_party.id, 'code', v_party.code, 'player_id', v_player.id);
end $$;

-- Presencia: latido cada ~10s desde el cliente.
create or replace function heartbeat(p_party_id uuid)
returns void language sql security definer set search_path = public as $$
  update players set last_seen = now()
  where party_id = p_party_id and auth_user_id = auth.uid() and status = 'active';
$$;

create or replace function leave_party(p_party_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update players set status = 'left'
  where party_id = p_party_id and auth_user_id = auth.uid();
  -- si se fue el host, pasa a jugador humano activo más antiguo
  if not exists (select 1 from players where party_id = p_party_id and is_host and status = 'active') then
    update players set is_host = true
    where id = (
      select id from players
      where party_id = p_party_id and status = 'active' and not is_bot
      order by joined_at limit 1
    );
  end if;
end $$;

create or replace function kick_player(p_party_id uuid, p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  update players set status = 'kicked', is_host = false
  where id = p_target and party_id = p_party_id;
end $$;

create or replace function transfer_host(p_party_id uuid, p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  update players set is_host = false where party_id = p_party_id and is_host;
  update players set is_host = true
  where id = p_target and party_id = p_party_id and status = 'active' and not is_bot;
end $$;

-- Failover: si el host lleva >60s sin latir, el primero que toque toma el mando.
create or replace function claim_host(p_party_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_stale boolean;
begin
  if not is_member(p_party_id) then raise exception 'NO_MIEMBRO'; end if;
  select coalesce(bool_and(last_seen < now() - interval '60 seconds'), true) into v_stale
    from players where party_id = p_party_id and is_host and status = 'active';
  if not v_stale then raise exception 'HOST_ACTIVO'; end if;
  update players set is_host = false where party_id = p_party_id and is_host;
  update players set is_host = true
  where party_id = p_party_id and auth_user_id = auth.uid() and status = 'active';
end $$;

-- Host cambia modo (social|drinking) e intensidad (1-5) en vivo.
create or replace function update_settings(p_party_id uuid, p_settings jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  if p_settings->>'mode' not in ('social','drinking')
     or (p_settings->>'intensity')::int not between 1 and 5 then
    raise exception 'SETTINGS_INVALIDOS';
  end if;
  update parties set settings = p_settings where id = p_party_id;
end $$;

-- DEV: bots para probar. Solo host. Se quedan para siempre (plan).
create or replace function dev_add_bots(p_party_id uuid, p_n int)
returns void language plpgsql security definer set search_path = public as $$
declare
  i int;
  v_names text[] := array['Rocco','Mona','Tito','Lupe','Chino','Nena','Paco','Coco','Rita','Memo','Duna','Kiko','Vera','Lalo','Pina','Bruno','Cleo','Gato'];
  v_symbols text[] := array['★','⚡','☾','♦','▲','●','✕','♠'];
  v_colors text[] := array['#FFB224','#FF5C47','#7ED957','#5CB8FF','#C792EA','#F5EFE6'];
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  for i in 1..least(p_n, 19) loop
    insert into players (party_id, name, is_bot, avatar)
    values (
      p_party_id,
      v_names[1 + floor(random()*array_length(v_names,1))::int] || ' 🤖',
      true,
      jsonb_build_object(
        'symbol', v_symbols[1 + floor(random()*array_length(v_symbols,1))::int],
        'color',  v_colors[1 + floor(random()*array_length(v_colors,1))::int]
      )
    );
  end loop;
end $$;

create or replace function dev_remove_bots(p_party_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_host_of(p_party_id) then raise exception 'SOLO_HOST'; end if;
  delete from players where party_id = p_party_id and is_bot;
end $$;

-- ---------- REALTIME ----------
-- Notificación solamente: el cliente escucha cambios y refetchea estado canónico.
alter publication supabase_realtime add table parties;
alter publication supabase_realtime add table players;
alter publication supabase_realtime add table game_sessions;
