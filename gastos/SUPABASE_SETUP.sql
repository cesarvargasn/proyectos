-- ============================================================
-- Tabla de sync para Gastos y Transacciones
-- Correr UNA VEZ en: dashboard Supabase (proyecto La Noche)
--   > SQL Editor > pegar todo esto > Run
-- ============================================================

create table if not exists public.gastos_transacciones (
  hash          text primary key,
  fecha         text,
  remitente     text,
  banco         text,
  monto         double precision,
  monto_txt     text,
  comercio      text,
  contraparte   text,
  es_transaccion integer,
  parseo_ok     integer,
  texto         text,
  fuente        text,
  tipo          text,
  capturado_en  text,
  subido_en     timestamptz default now()
);

-- RLS: la key publica (anon) que va dentro del APK SOLO puede insertar.
-- No puede leer, modificar ni borrar nada (ni de esta tabla ni toca las
-- tablas de los juegos). Leer solo se puede con la service key (PC).
alter table public.gastos_transacciones enable row level security;

drop policy if exists capturador_insert_only on public.gastos_transacciones;
create policy capturador_insert_only
  on public.gastos_transacciones
  for insert
  to anon, authenticated
  with check (true);
