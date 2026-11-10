# Afinidad

App de afinidad para fiestas. Cada invitado se registra desde el celular y responde un cuestionario tipo Likert (1 a 5). La app calcula qué tan parecidos son por similitud coseno con pesos por categoría, y el host revela los grupos en rondas embudo: primero dos grupos, luego cuatro, luego dieciséis y al final duplas. Si el número es impar, sale un trío.

En vivo: [matching.cesarvargasn.com](https://matching.cesarvargasn.com)

## Stack

React + Vite + TypeScript + Supabase (Postgres, Auth para el admin, RLS) + Vercel.

## Correr

```
npm install
cp .env.example .env.local   # llenar con tu proyecto de Supabase
npm run dev
```

Los `migration*.sql` crean las tablas y políticas; se corren en el editor SQL de Supabase.

## Qué no está aquí

Copia pública sin historial. No incluye las preguntas del cuestionario ni datos de la base: hay que cargar preguntas propias en la tabla `questions` (desde el panel de admin o por SQL).
