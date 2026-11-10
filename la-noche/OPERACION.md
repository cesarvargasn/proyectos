# La Noche: cómo operarla

Sitio: https://lanoche.cesarvargasn.com. Nada de esta página requiere terminal, salvo donde se indica.

## Antes de la fiesta

1. Entra a Supabase (proyecto de La Noche). Si dice que está pausado, dale **Restore** y espera unos minutos. El plan gratis lo pausa por inactividad.
2. Abre el sitio y crea una noche de prueba para confirmar que carga.
3. Revisa en Vercel que `VITE_DEV_BOTS` no esté en `true`. Si lo estaba y la cambias, haz **Redeploy**: sin eso el cambio no aplica.

## Durante la fiesta

1. **Crear:** entra a Crear e inicia sesión con tu cuenta de admin. Solo tu cuenta puede crear noches.
2. **Unir gente:** comparte el código de 4 letras o el QR. Cada quien entra sin cuenta, con nombre y avatar.
3. **Lanzar:** escoge el juego desde tu panel de host.

| Juego | Jugadores |
|---|---|
| La Ruleta | 3 a 20 |
| Impostor | 4 a 12 |
| Charadas | 4 a 16 |
| Parejas a Gritos | 6 a 20 |
| Lobos | 6 a 20 |
| Dos Cuartos y la Bomba | 6 a 20 |

Yo Nunca, Verdad o Reto y El Más Probable no se lanzan: se leen en voz alta desde `/cartas`.

## Si algo falla

| Problema | Qué hacer |
|---|---|
| Un juego se queda pegado | Usa **Forzar avance** en tu panel de host, o termina el juego |
| Alguien se salió | Que vuelva a abrir el sitio en el mismo celular y navegador |
| Alguien aparece duplicado | Entró desde otro navegador y cuenta como persona nueva: expulsa al repetido desde el lobby |
| Se te fue el celular siendo host | Pasado un minuto aparece un aviso para tomar el control, y el primero que lo toca queda de host |
| Nada carga | Supabase probablemente está pausado: mira el paso 1 de "Antes de la fiesta" |

## Cartas

- **Añadir a una base (Yo Nunca, Verdad o Reto, El Más Probable):** `/cartas`, botón añadir.
- **Editar, apagar o borrar en La Ruleta:** `/cartas`.
- **Editar palabras de Impostor, Charadas o Parejas:** no se puede desde la página. Requiere editar `content/<juego>.csv`, correr `npm run content` en terminal y pegar el SQL en Supabase.

**Cuidado:** cada archivo de `supabase/content/` borra todas las cartas de su juego y las vuelve a meter. Si añadiste cartas desde `/cartas`, se pierden al correrlo, salvo que también estén en la CSV.

## Dónde está cada cosa

- **Datos y SQL Editor:** Supabase
- **Sitio y variables:** Vercel (cada push a `main` despliega solo)
- **Código:** GitHub `cesarvargasn/lanoche`
- **Revisar cartas en lote:** abrir `tools/curar-cartas.html` en el navegador
