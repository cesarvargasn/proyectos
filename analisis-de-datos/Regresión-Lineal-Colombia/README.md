# Análisis de Regresiones Lineales y Logarítmicas en Hogares Colombianos (2016–2020)

Este proyecto presenta un conjunto de análisis econométricos realizados con datos de hogares colombianos, centrados en la relación entre ingreso, gasto en alimentación, educación y rendimientos financieros. Fue desarrollado en el contexto académico de un curso universitario de métodos cuantitativos.

## 🔍 Objetivos del proyecto

- Evaluar la relación entre ingreso y gasto alimentario mediante modelos lineales y log-log.
- Identificar presencia de heterocedasticidad en los modelos básicos y corregirla con transformaciones logarítmicas.
- Estimar modelos de regresión que incluyen variables como nivel educativo, afiliación a seguridad social y estrato.
- Comparar causalidad e interpretación económica entre ingreso y horas trabajadas.

## 🧪 Metodología y herramientas

- **Stata** fue la herramienta utilizada para procesar, estimar y visualizar.
- Modelos de regresión simple y múltiple.
- Transformaciones logarítmicas.
- Análisis gráfico de residuos para evaluar supuestos del modelo.
- Uso de `outreg2` para exportar resultados.

## 📊 Datos utilizados

Se utilizaron dos fuentes de datos:

1. **Encuesta de educación financiera y carga financiera en hogares colombianos (2016)**  
   Fuente: [www.rodrigotaborda.com](http://www.rodrigotaborda.com/?page_id=393)

2. **Base de pobreza monetaria y desigualdad en Colombia (2020)**  
   Fuente: [SugarSync folder](https://www.sugarsync.com/pf/D3570656_09703521_8031883)

> **Nota:** Los datos fueron usados con fines educativos. Para uso investigativo o público, se recomienda solicitar autorización al profesor o entidad correspondiente.

## 📂 Archivos

- `taller3_regresiones.do`: script con todos los ejercicios del taller.
- Gráficos generados: residuos vs ingreso, residuos vs ln(ingreso), boxplot de residuos² por nivel educativo.
- Exportaciones a Word mediante `outreg2`.

## 👨‍💻 Autor

César Andrés Vargas Nieto  
Durante periodo de estudio en la Universidad de los Andes – Facultad de Economía y Facultad de Administración
Año: 2024
