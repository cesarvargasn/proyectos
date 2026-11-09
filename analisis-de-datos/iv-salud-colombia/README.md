# Estimación del impacto del estado de salud sobre los ingresos usando variables instrumentales

Este proyecto aplica métodos de variables instrumentales (IV) para estimar el efecto causal del estado de salud sobre el ingreso laboral en Colombia. Se parte del supuesto de que la salud puede estar correlacionada con factores no observables que también afectan el ingreso, por lo que se requiere un instrumento válido.

## 🎯 Objetivo del análisis

- Estimar el efecto del estado de salud sobre el ingreso mensual.
- Comparar estimaciones por MCO y por variables instrumentales.
- Evaluar la validez del instrumento propuesto (tipo de afiliación al sistema de salud).

## ⚙️ Metodología

- Regresiones por Mínimos Cuadrados Ordinarios (MCO)
- Estimación IV usando `ivregress` y `ivreg2`
- Pruebas de endogeneidad y validez del instrumento:
  - Prueba de relevancia del instrumento
  - Prueba de sobreidentificación (Hansen J)
  - Prueba de Hausman para endogeneidad

## 📊 Variables clave

- Variable dependiente: ingreso mensual del hogar
- Variable explicativa: estado de salud del encuestado
- Instrumento: tipo de afiliación (régimen contributivo vs subsidiado)

## 🛑 Nota sobre los datos

> ⚠️ Por razones de licencia y privacidad, la base de datos utilizada en este análisis no se incluye en este repositorio. Los scripts pueden requerir ajustes si se utilizan otras bases.

## 👤 Autor del código

César Andrés Vargas Nieto  
Durante periodo de estudio en la Universidad de los Andes – Facultad de Economía  
Curso: Econometría II – Año 2023
