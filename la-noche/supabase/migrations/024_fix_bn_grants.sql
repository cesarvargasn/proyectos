-- ============================================================================
-- 024_fix_bn_grants.sql — fix de permisos de los helpers de banco (023)
--
-- BUG: 023 revocó EXECUTE de bn_deck y bn_advance solo `from anon,
-- authenticated`, omitiendo `public`. Postgres otorga EXECUTE a PUBLIC por
-- defecto al crear una función, así que ese grant sobrevivía y ambas
-- quedaban llamables por cualquiera con la anon key (que es pública: va en
-- el bundle JS). Todas las demás migraciones del proyecto (003, 013, 021,
-- 022...) revocan `from public, anon, authenticated` — 023 fue la excepción.
--
-- Impacto que cierra:
--  · bn_deck es security definer y lee content_cards, tabla sin acceso
--    cliente por diseño. Un anon podía volcar el banco entero de cartas.
--  · bn_advance hace update sobre game_sessions sin validar host ni
--    membresía (confía en ser interna). El caller arma el record p_session,
--    o sea controla el id: podía pasar carta o terminar la noche de otros.
--
-- Idempotente y sin efectos sobre datos: solo ajusta privilegios.
-- ============================================================================

revoke execute on function bn_deck(text, int, int, uuid[])
  from public, anon, authenticated;

revoke execute on function bn_advance(uuid, game_sessions)
  from public, anon, authenticated;

-- bn_is_banco se deja accesible a propósito: es `immutable`, no toca tablas
-- y solo responde si un game_type está en la lista de bancos.

-- Verificación (debe devolver 0 filas):
--   select p.proname, r.rolname
--   from pg_proc p
--   cross join lateral aclexplode(p.proacl) a
--   join pg_roles r on r.oid = a.grantee
--   where p.proname in ('bn_deck','bn_advance') and a.privilege_type = 'EXECUTE';
