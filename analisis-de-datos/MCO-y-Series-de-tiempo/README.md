# Análisis de series de tiempo y crecimiento económico en Colombia

Este proyecto aplica modelos econométricos para analizar el crecimiento económico colombiano y pronosticar variables macroeconómicas clave, como el PIB, el salario mínimo y la tasa de cambio, utilizando técnicas de series de tiempo.

## 🎯 Objetivos del análisis

1. Estimar la función de producción agregada usando modelos de panel con datos de múltiples países.
2. Analizar el crecimiento del PIB de Colombia mediante descomposición temporal y proyecciones.
3. Pronosticar el salario mínimo y la tasa de cambio promedio en Colombia utilizando métodos de suavizamiento.

## ⚙️ Metodología

### Parte 1 – Modelos de producción
- Estimación por **Mínimos Cuadrados Ordinarios (MCO)**.
- Estimación con **efectos fijos** (`xtreg, fe`) y con **efectos fijos por `areg`**.
- Comparación entre modelos y exportación de resultados (`outreg2`).

### Parte 2 – PIB de Colombia
- Cálculo del **crecimiento del PIB** a partir de datos anuales.
- **Descomposición de la serie** usando el filtro de **Hodrick-Prescott**.
- Ajuste de **tendencia lineal y cuadrática** para pronóstico del PIB.
- Comparación de tasas de crecimiento observadas vs. proyectadas.
- Selección de modelos con criterios de información (AIC).

### Parte 3 – Pronósticos macroeconómicos
Se aplicaron métodos de suavizamiento exponencial, de medias móviles y estacionales para:

- **Salario mínimo mensual** (datos del Ministerio de Educación).
- **Tasa de cambio promedio** (datos del Banco de la República).

Herramientas usadas:
- `tssmooth exponential`, `tssmooth hwinters`, `tssmooth ma`
- `tsset`, `predict`, `tsline`, `estat ic`

## 📊 Hallazgos destacados

- Se encontró una relación positiva entre el logaritmo del capital y la producción en el modelo de MCO y efectos fijos.
- La tendencia cuadrática del PIB ofrece un mejor ajuste que la lineal según el criterio de Akaike.
- Las predicciones del crecimiento con modelos cuadráticos tienden a ajustarse mejor a la evolución reciente del PIB.
- Para las series del salario mínimo y la tasa de cambio, los modelos de suavizamiento permiten visualizar patrones y realizar proyecciones a corto plazo.

## 🛑 Nota sobre los datos

> ⚠️ Las bases de datos utilizadas en este proyecto provienen de fuentes oficiales (WDI, MinEducación, Banrep), pero no se incluyen en este repositorio por temas de licencia y derechos de uso.

## 👤 Autor del código

Parte de un ejercicio de clase, Econometria 2

César Andrés Vargas Nieto  
Durante periodo de estudio en la Universidad de los Andes – Facultad de Economía  
Curso: Econometría II – Año 2023
