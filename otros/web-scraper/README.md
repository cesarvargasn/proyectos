
# 🕸️ Simple Web Scraper GUI

Pequeña aplicación en **Python + Tkinter** que descarga el texto visible de cualquier página web y lo guarda en un archivo `.txt` con un solo clic.  
Su objetivo es **educativo**: enseñar los fundamentos de requests, parsing con Beautiful Soup y una interfaz gráfica mínima.

---

## ✨ Características

|                         | Descripción |
|-------------------------|-------------|
| **GUI cross-platform**  | Ventana Tkinter de ~500 px, sin dependencias de escritorio externas. |
| **Barra de progreso**   | Muestra el avance mientras descarga el HTML en streaming. |
| **Texto limpio**        | Elimina `<script>`, `<style>`, navegaciones, SVG & footers para quedarte con el contenido legible. |
| **Salida organizada**   | Guarda `scrape_YYYYMMDD_HHMMSS.txt` en la carpeta que elijas. |
| **User-Agent propio**   | Incluye un UA descriptivo; modifícalo si vas a distribuir la app. |

---

## 📦 Instalación

```bash
# Requiere Python 3.9 o superior
py -m pip install requests beautifulsoup4
```

Clona el repositorio o descarga `simple_scraper_gui.py`.

---

## 🚀 Uso rápido

```bash
py simple_scraper_gui.py
```

1. **Pega** la URL en el campo correspondiente (botón **Pegar** usa tu portapapeles).  
2. **Selecciona** la carpeta destino con “…” si quieres cambiarla.  
3. Pulsa **Scrapear** y espera a que la barra llegue al 100 %.  
4. Revisa el `.txt` generado en la carpeta elegida.

---

## ⚙️ ¿Cómo funciona?

1. **`requests.get(stream=True)`** descarga el HTML por chunks (8 KB).  
2. **Barra de progreso**: se actualiza comparando bytes recibidos con `Content-Length`.  
3. **`BeautifulSoup`** parsea el HTML; se eliminan tags invisibles (`script`, `style`, etc.).  
4. Se limpia el texto (líneas vacías, espacios duplicados) y se escribe al disco.

---

## 🛑 Limitaciones

| Problema | Detalle |
|----------|---------|
| **JavaScript render** | No ejecuta JS. Sitios con contenido dinámico devolverán solo la plantilla. |
| **Anti-bot** | No evita CAPTCHA, Cloudflare ni logins protegidos. |
| **Imágenes, tablas, metadata** | Extrae **texto**; no descarga imágenes ni formatea CSV. |
| **Tamaño de página** | Muy grandes (> 10 MB) pueden tardar; ajustar `chunk_size` si necesario. |

---

## 🤝 Uso responsable

- **Lee siempre** el archivo `robots.txt` y los Términos de Servicio del sitio objetivo.  
- Respeta la propiedad intelectual y la privacidad de datos personales.  
- Este proyecto es **Didáctico**; no se garantiza adecuación legal para scraping en producción.

---

## 🗺️ Roadmap (aporte bienvenido)

- [ ] Opción para guardar en **CSV** (una columna por párrafo).  
- [ ] Delay aleatorio y rotación de user-agents.  
- [ ] Modo **headless Selenium** para páginas JavaScript (requiere ChromeDriver).  
- [ ] Filtros de palabras clave y fechas antes de guardar.  
- [ ] Empaquetado `.exe` con PyInstaller.

---

## 📄 Licencia

haz lo que quieras, pero sin garantías. 
