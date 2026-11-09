# Análisis exploratorio de conversación en WhatsApp

Este script permite analizar de forma exploratoria un chat de WhatsApp exportado en formato `.txt` (sin incluir medios). El objetivo es obtener métricas generales de interacción, longitud de mensajes, inicio de conversaciones y frecuencia de palabras.

## 📌 Qué hace el script

- Extrae fecha, hora, autor y contenido de cada mensaje.
- Calcula:
  - Mensajes por persona (%)
  - Preguntas enviadas
  - Mensajes largos (30+ palabras)
  - Conversaciones iniciadas (pausas ≥8 horas)
  - Palabras más frecuentes (sin signos)
- Genera:
  - CSV con toda la conversación estructurada
  - Gráfico circular de participación

## 📂 Requisitos

- Archivo `.txt` exportado directamente desde WhatsApp.
- Python 3 con:
  - `pandas`
  - `matplotlib`

## ⚠️ Notas

- No se incluye el archivo original del chat por privacidad.
- Asegúrate de tener el mismo formato de exportación (WhatsApp en español con hora `a.m.` / `p.m.` y corchetes).

## 🧑 Autor

César Andrés Vargas Nieto  
2025
