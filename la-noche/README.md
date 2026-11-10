# La Noche

Plataforma de juegos de fiesta: el host corre la sesión, los invitados entran una vez con un código de 4 letras desde el celular, y 16 juegos corren sobre un mismo backbone toda la noche.

## Stack (fijo — no desviarse)

React 18 + Vite + TypeScript + Framer Motion + Supabase (Postgres, Realtime, Anonymous Auth, RPC) + Vercel. Mobile-first web.

Reglas de arquitectura clave:

- Postgres es la única fuente de verdad; el estado del juego vive en `game_sessions.state` (JSONB).
- Toda mutación pasa por RPC `security definer` con validación en servidor. El cliente nunca escribe estado.
- Secretos (roles, palabras, manos) en `player_secrets` con RLS — a prueba de devtools.
- Timers anclados al servidor (`phase_ends_at`). Reconexión reconstruye cualquier pantalla desde un fetch.

## Design system — Warm Brutalist (dark only)

- Tokens en `src/styles/global.css`: charcoal `#1A1614`, off-white `#F5EFE6`, ámbar `#FFB224`, coral `#FF5C47`.
- Bordes 2–3px, sombras duras `4px 4px 0`, cero blur/gradientes/border-radius.
- Tipos: Archivo Black (display) + Space Grotesk (body), self-hosted vía Fontsource.

## Correr

```
npm install
cp .env.example .env.local   # llenar credenciales de Supabase
npm run dev
```

## Deploy

Vercel conectado a GitHub, auto-deploy en push a `main`. Dominio: lanoche.cesarvargasn.com.

## Qué no está aquí

Esta es una copia pública sin historial. Las cartas de los juegos no se incluyen: `content/` solo trae la plantilla y las instrucciones, y `supabase/content/` se genera con `npm run content` a partir de tus propias CSV. Tampoco hay datos de la base.
