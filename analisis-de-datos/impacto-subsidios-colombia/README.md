# Análisis del impacto de subsidios sobre ingreso y educación en Colombia

Este proyecto examina el efecto de recibir subsidios alimentarios y de educación sobre el ingreso y el nivel educativo de los hogares colombianos. Se utilizan métodos econométricos básicos y avanzados para evaluar el impacto promedio y diferencial de estos programas sociales.

## 🎯 Objetivos del análisis

1. Comparar el ingreso promedio entre hogares que reciben y no reciben subsidios alimentarios.
2. Evaluar el efecto de recibir subsidios de educación sobre el nivel educativo alcanzado.
3. Estimar cómo varía el impacto de estos subsidios a lo largo de la distribución del ingreso.

## ⚙️ Metodología aplicada

- Comparación de medias (`ttest`)
- Regresiones lineales (OLS) con variables binarias
- Regresiones por cuantiles (`qreg`) para analizar efectos heterogéneos
- Evaluación de efectos marginales según nivel de ingreso

## 📊 Hallazgos destacados

- Los hogares que reciben **subsidios alimentarios** tienden a tener un ingreso mensual **ligeramente inferior**, aunque la diferencia no es significativa en todos los casos.
- Los subsidios de educación están **positivamente asociados al nivel educativo** alcanzado, incluso controlando por otras variables.
- En las regresiones por cuantiles se encontró que el impacto de los subsidios **varía a lo largo de la distribución del ingreso**, siendo más significativo en los cuantiles más bajos.

## 🛑 Nota sobre los datos

> ⚠️ La base de datos usada fue entregada en el contexto del curso y **no se incluye en este repositorio** por restricciones de uso. El código está diseñado para replicar el análisis con esa estructura de datos.

## 👤 Autor del código

César Andrés Vargas Nieto  
Durante periodo de estudio en la Universidad de los Andes – Facultad de Economía  
Curso: Econometría II – Año 2023
