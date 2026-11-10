# Contenido de los juegos

Un CSV por juego: `content/<game_type>.csv` — el nombre del archivo **es** el
`game_type` (ver ids en `src/games/registry.ts`, p.ej. `yo-nunca.csv`,
`la-ruleta.csv`). Los archivos que empiezan con `_` son plantillas y se ignoran.

## Flujo

1. Autorar/editar cartas en el CSV (Excel o Google Sheets, exportar como CSV).
2. `npm run content` → genera `supabase/content/<game_type>.sql`.
3. Pegar ese .sql en el editor SQL de Supabase. Es idempotente: borra y
   reinserta solo las cartas de ese juego, se puede correr mil veces.

## Columnas

| columna    | obligatoria | qué es |
|------------|-------------|--------|
| `text_es`  | sí          | texto de la carta |
| `intensity`| no (def. 2) | 1 suave … 5 fuego |
| `card_type`| no          | subtipo por juego: `verdad`/`reto`, `directa`/`grupal`/`duelo`/`reto`/`regla`… |
| `text_en`  | no          | traducción (v1 no se usa, schema bilingüe día uno) |
| `tags`     | no          | separadas por `;` |
| `meta`     | no          | JSON extra, p.ej. `{"rondas":3}` |

## Tokens en text_es

- `{p1}`, `{p2}`… — jugadores al azar (solo conectados; los resuelve el server).
- `{drink:N}` — castigo según modo: trago (`toma N`) o social (`pierde N puntos`).
  **Regla del proyecto: toda carta con `{drink:N}` debe funcionar en modo social.**

## Targets fase 9

Yo Nunca 100+ · VoR 60 verdades + 60 retos · Señalado 80+ · Ruleta 150+ ·
Ocurrencias 100+ · Mentiras 60+ · Manada 60+ · Sin Filtro 60/300+ ·
Impostor 40+ categorías · Paranoia 60+ · Tres Rondas 4 packs · Parejas 120.
