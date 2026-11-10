-- ============================================================
-- LA NOCHE — Migración 002: crear noche solo admin (César)
-- Correr en SQL Editor DESPUÉS de 001_spine.sql.
--
-- Modelo (igual que matching app): UNA cuenta real de Supabase
-- Auth (email+password) para el admin. Invitados siguen 100%
-- anónimos y solo pueden UNIRSE, nunca crear.
-- Crear la cuenta: Authentication → Users → Add user.
-- ============================================================

create or replace function create_party(p_name text, p_avatar jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  v_party parties;
  v_player players;
begin
  -- Solo usuarios reales (no anónimos). Fail-closed si falta el claim.
  if auth.uid() is null
     or coalesce((auth.jwt()->>'is_anonymous')::boolean, true) then
    raise exception 'SOLO_ADMIN';
  end if;

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
