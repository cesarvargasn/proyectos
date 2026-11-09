# 🧠 OCR Bot Multiformato

Este proyecto es una pequeña aplicación de escritorio que permite extraer texto de imágenes o archivos PDF mediante OCR (reconocimiento óptico de caracteres). Cuenta con una interfaz gráfica (GUI) amigable en inglés y español, y permite guardar los resultados en formatos `.txt` o `.docx`.

---

## 🚀 Funcionalidades

- Carga de imágenes o PDFs desde el explorador de archivos.
- OCR usando Tesseract en inglés (`eng`), español (`spa`) o ambos (`eng+spa`).
- Conversión del texto a archivos `.txt` o `.docx`.
- Interfaz gráfica sencilla, con selección de idioma.
- Visualización de progreso del procesamiento.
- Guardado automático del archivo en la carpeta seleccionada.

---

## ⚙️ Requisitos

Instala las siguientes librerías de Python:

```
py -m pip install pillow pytesseract python-docx pdf2image
```

Además, asegúrate de tener instalados en tu sistema:

- **Tesseract OCR**  
  Puedes descargarlo desde: https://github.com/tesseract-ocr/tesseract

- **Poppler for Windows** (para convertir PDFs en imágenes):  
  Puedes descargarlo desde: http://blog.alivate.com.au/poppler-windows/

---

## 🔧 Configuración de rutas

Antes de ejecutar el programa, modifica las siguientes líneas con las rutas donde tengas instalado Tesseract y Poppler en tu máquina:

```
pytesseract.pytesseract.tesseract_cmd = r"C:\Program Files\Tesseract-OCR\tesseract.exe"
POPPLER_PATH = r"C:\Program Files\poppler\Library\bin"
```

Si empacas el programa como un `.zip` o `.exe` con las carpetas incluidas, puedes usar rutas relativas como en el ejemplo del código fuente.

---

## 🧪 Uso

1. Ejecuta el archivo `.py`.
2. Selecciona el archivo PDF o imagen desde el botón correspondiente.
3. Elige el idioma para el OCR.
4. Selecciona el formato de salida (`.txt` o `.docx`).
5. Escribe un nombre de archivo y escoge una carpeta de destino.
6. Haz clic en “Procesar OCR”.
7. Al finalizar, se te preguntará si deseas abrir la carpeta donde se guardó el resultado.

---

Este proyecto es experimental y fue desarrollado con fines de aprendizaje.
