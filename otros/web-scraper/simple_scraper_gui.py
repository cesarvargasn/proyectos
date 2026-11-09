

import os
import threading
import time
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
import tkinter as tk

import requests
from bs4 import BeautifulSoup


# ---------- scraping ----------
def fetch_text(url: str, progress_callback=None) -> str:
    """Devuelve solo el texto visible de la página."""
    with requests.get(url, stream=True, timeout=15, headers={
        "User-Agent": "EduScraper/1.0 (+https://github.com/tu-portfolio)"
    }) as resp:
        resp.raise_for_status()
        total = int(resp.headers.get("content-length", 0))
        downloaded = 0
        chunks = []
        for chunk in resp.iter_content(chunk_size=8192):
            downloaded += len(chunk)
            chunks.append(chunk)
            if progress_callback and total:
                progress_callback(downloaded, total)
        html = b"".join(chunks).decode(resp.encoding or "utf-8", errors="replace")

    soup = BeautifulSoup(html, "html.parser")

    # Elimina scripts, estilos y cosas invisibles
    for tag in soup(["script", "style", "noscript", "svg", "footer", "header", "nav"]):
        tag.decompose()

    text = soup.get_text(separator="\n")
    # Limpieza básica de espacios y líneas vacías
    lines = [line.strip() for line in text.splitlines()]
    return "\n".join(line for line in lines if line)


# ---------- GUI ----------
class ScraperApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Simple Web Scraper")
        self.geometry("500x180")
        self.resizable(False, False)

        self.url = tk.StringVar()
        self.dest_folder = tk.StringVar(value=str(Path(__file__).parent))

        self._build_ui()

    def _build_ui(self):
        ttk.Label(self, text="URL de la página:").grid(row=0, column=0, sticky="w", padx=8, pady=8)
        ttk.Entry(self, textvariable=self.url, width=52).grid(row=0, column=1, padx=4)
        ttk.Button(self, text="Pegar", command=self._paste_clipboard).grid(row=0, column=2, padx=4)

        ttk.Label(self, text="Carpeta destino:").grid(row=1, column=0, sticky="w", padx=8)
        ttk.Entry(self, textvariable=self.dest_folder, width=52).grid(row=1, column=1, padx=4)
        ttk.Button(self, text="…", command=self._pick_dest).grid(row=1, column=2, padx=4)

        self.progress = ttk.Progressbar(self, orient="horizontal", length=460, mode="determinate")
        self.progress.grid(row=2, column=0, columnspan=3, padx=8, pady=16)

        ttk.Button(self, text="Scrapear", command=self._scrape_click, width=20).grid(row=3, column=0, columnspan=3)

        ttk.Label(self, text="Solo para uso educativo. Respeta los TOS y robots.txt.", foreground="grey").grid(
            row=4, column=0, columnspan=3, pady=6
        )

    # ---------- callbacks ----------
    def _paste_clipboard(self):
        try:
            self.url.set(self.clipboard_get())
        except tk.TclError:
            pass

    def _pick_dest(self):
        folder = filedialog.askdirectory(title="Carpeta destino")
        if folder:
            self.dest_folder.set(folder)

    def _scrape_click(self):
        url = self.url.get().strip()
        dest = self.dest_folder.get().strip()

        if not url:
            messagebox.showerror("Falta URL", "Pega la dirección que quieres scrapear.")
            return
        if not dest:
            messagebox.showerror("Falta destino", "Elige la carpeta donde guardar el .txt.")
            return

        self.progress["value"] = 0
        self.progress["maximum"] = 100  # provisional

        threading.Thread(target=self._do_scrape, args=(url, dest), daemon=True).start()

    # ---------- scraping thread ----------
    def _do_scrape(self, url, dest_folder):
        def update_progress(done, total):
            percent = done / total * 100
            self.progress["value"] = percent
            self.update_idletasks()

        try:
            text = fetch_text(url, progress_callback=update_progress)
        except Exception as e:
            messagebox.showerror("Error", f"No se pudo descargar la página:\n{e}")
            self.progress["value"] = 0
            return

        timestamp = time.strftime("%Y%m%d_%H%M%S")
        fname = f"scrape_{timestamp}.txt"
        out_path = Path(dest_folder, fname)
        try:
            with open(out_path, "w", encoding="utf-8") as f:
                f.write(text)
        except OSError as e:
            messagebox.showerror("Error al guardar", str(e))
            self.progress["value"] = 0
            return

        self.progress["value"] = 100
        messagebox.showinfo("Listo", f"Texto guardado en:\n{out_path}")
        self.progress["value"] = 0


if __name__ == "__main__":
    ScraperApp().mainloop()
