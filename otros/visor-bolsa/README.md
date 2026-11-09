
# 📈 Visor Bolsa Lite

**Visor Bolsa Lite** es una *mini‑terminal* de escritorio (tkinter + Yahoo Finance) que te deja explorar precios, indicadores técnicos y estados financieros de cualquier acción con un par de clics.  
Nació como proyecto personal / didáctico, pero es 100 % funcional y puedes modificarlo o distribuirlo a tu gusto (licencia MIT).

---

## ✨ Funcionalidades principales

| Categoría | Detalle |
|-----------|---------|
| **Precio & volumen** | Gráfico de velas con barras de volumen. |
| **Indicadores** | SMA‑20, EMA‑20, Bandas de Bollinger, MACD (línea + señal). |
| **Banda 52 w** | Sombreado entre mínimo y máximo anuales para contexto rápido. |
| **Tool‑tips** | Al pasar el ratón se muestra fecha + OHLC de cada vela. |
| **Fundamentales rápidos** | Market Cap, PER, EPS, Dividend Yield, Revenue, Net Income. |
| **Pop‑up estados** | Income Statement, Balance Sheet y Cashflow en pestañas. |
| **Watchlist** | Lista editable de favoritos; clic → carga instantánea. |
| **Rangos rápidos** | Botones 6 M, YTD, MAX sin re‑descarga si ya tienes los datos. |
| **Tema claro / oscuro** | Toggle ☀ / 🌙 en la barra superior. |
| **Exportar** | CSV de precios + indicadores; captura PNG del gráfico. |
| **Autosave** | Guarda último ticker, indicadores seleccionados, tema y watchlist en `settings.json`. |

---

## 🛠️ Instalación

```bash
# Python 3.9 +
py -m pip install yfinance pandas matplotlib mplfinance mplcursors
```

Clona el repo o descarga `visor_bolsa_lite.py` y listo.

---

## 🚀 Uso rápido

```bash
py visor_bolsa_lite.py
```

1. **Ticker** → escribe, pulsa **Buscar** o selecciónalo de la *watchlist*.  
2. Cambia **período** (1 d, 5 d, 1 m, 1 a) o usa los rangos rápidos.  
3. Marca los **indicadores** que quieras y alterna **tema** si te apetece.  
4. Explora los **Estados financieros** en el pop‑up.  
5. **Exporta** CSV o PNG desde los botones de la barra.

---

## 📚 Dependencias clave

- **yfinance** – descarga histórico y fundamentales de Yahoo Finance.  
- **mplfinance** – dibujo de velas y volumen.  
- **mplcursors** – tool‑tips interactivos.  
- **pandas / NumPy** – cálculo de indicadores y limpieza.

---

## ⚠️ Limitaciones

| Tipo | Descripción |
|------|-------------|
| **Datos EoD** | Yahoo no ofrece feed de tiempo real gratuito; precios intradía ~15 min delay. |
| **Límites API** | Demasiadas peticiones pueden devolver error 999 o captcha. |
| **Fundamentales incompletos** | Algunos tickers carecen de dividend yield o net income. |
| **Sin trading** | La app NO envía órdenes ni sustituye plataformas profesionales. |

---

## 📝 Licencia
usa, modifica y comparte libremente. Una mención al repo de origen siempre se agradece.
