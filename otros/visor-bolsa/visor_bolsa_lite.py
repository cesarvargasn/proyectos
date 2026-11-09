# visor_bolsa_lite.py – versión final (S-1 + S-2 + S-3)
import json, os, tkinter as tk
from tkinter import filedialog, messagebox, ttk
from datetime import date
from pathlib import Path

import mplcursors
import mplfinance as mpf
import numpy as np
import pandas as pd
import yfinance as yf
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg

CFG = Path(__file__).with_name("settings.json")


def fmt_num(n):
    if n in (None, np.nan):
        return "—"
    absn = abs(n)
    for d, s in [(1e12, " T"), (1e9, " B"), (1e6, " M"), (1e3, " K")]:
        if absn >= d:
            return f"{n/d:.1f}{s}"
    return f"{n:,.0f}"


def add_ind(df):
    c = df["Close"]
    df["SMA20"] = c.rolling(20).mean()
    df["EMA20"] = c.ewm(span=20).mean()
    std = c.rolling(20).std()
    df["BollU"], df["BollL"] = df["SMA20"] + 2 * std, df["SMA20"] - 2 * std
    macd = c.ewm(span=12).mean() - c.ewm(span=26).mean()
    df["MACD"], df["MACDs"] = macd, macd.ewm(span=9).mean()
    return df


STYLE = {
    "light": mpf.make_mpf_style(base_mpf_style="yahoo", gridcolor="#ddd"),
    "dark": mpf.make_mpf_style(base_mpf_style="nightclouds",
                               figcolor="#1e1e1e", gridcolor="#444")
}


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Visor Bolsa Lite"); self.geometry("1180x680")
        self.resizable(False, False)
        # ------- estado (se carga de settings.json) ------
        self.ticker = tk.StringVar(); self.period = tk.StringVar()
        self.theme = tk.StringVar();  self.watch = []
        self.show_sma = tk.BooleanVar(); self.show_ema = tk.BooleanVar()
        self.show_boll = tk.BooleanVar(); self.show_macd = tk.BooleanVar()
        self.load_settings()
        # ------- GUI blocks ------------------------------
        self._watchlist(); self._controls(); self._canvas(); self._side()
        # auto-load último ticker
        self.after(200, self.fetch)

    # -------------- Watchlist pane ----------------------
    def _watchlist(self):
        lf = ttk.Frame(self, width=120); lf.pack(side="left", fill="y")
        ttk.Label(lf, text="Watchlist", font=("Segoe UI", 10, "bold")).pack(pady=(6, 2))
        self.lst = tk.Listbox(lf, height=28, exportselection=False)
        self.lst.pack(padx=6, fill="both", expand=True)
        self.lst.bind("<<ListboxSelect>>", self._select_watch)
        ttk.Button(lf, text="＋", width=3, command=self._add_watch).pack(pady=4)
        ttk.Button(lf, text="－", width=3, command=self._del_watch).pack()
        for t in self.watch: self.lst.insert(tk.END, t)

    # -------------- Top controls ------------------------
    def _controls(self):
        f = ttk.Frame(self); f.pack(fill="x", padx=5, pady=6)
        ttk.Label(f, text="Ticker:").grid(row=0, column=0)
        ttk.Entry(f, textvariable=self.ticker, width=9).grid(row=0, column=1)
        ttk.Label(f, text="Período:").grid(row=0, column=2, padx=(10, 0))
        for i, (txt, val) in enumerate([("1d", "1d"), ("5d", "5d"),
                                        ("1m", "1mo"), ("1y", "1y")]):
            ttk.Radiobutton(f, text=txt, variable=self.period, value=val)\
                .grid(row=0, column=3 + i)
        ttk.Button(f, text="Buscar", command=self.fetch).grid(row=0, column=7, padx=6)
        # rango rápido
        ttk.Button(f, text="6 M", command=lambda: self._range(180)).grid(row=0, column=8)
        ttk.Button(f, text="YTD", command=self._ytd).grid(row=0, column=9)
        ttk.Button(f, text="MAX", command=lambda: self._range(None)).grid(row=0, column=10)
        # indicadores
        for i, (txt, var) in enumerate(
                [("SMA20", self.show_sma), ("EMA20", self.show_ema),
                 ("Boll", self.show_boll), ("MACD", self.show_macd)]):
            ttk.Checkbutton(f, text=txt, variable=var).grid(row=1, column=i, sticky="w")
        ttk.Button(f, text="Finanzas", command=self._popup_fin).grid(row=1, column=5)
        ttk.Button(f, text="CSV", command=self._to_csv, width=5).grid(row=1, column=6)
        ttk.Button(f, text="PNG", command=self._to_png, width=5).grid(row=1, column=7)
        ttk.Button(f, text="☀/🌙", command=self._swap_theme, width=4).grid(row=1, column=8, padx=4)
        self.status = ttk.Label(f, text="Listo"); self.status.grid(row=2, column=0, columnspan=11, sticky="w")

    # -------------- Chart area --------------------------
    def _canvas(self):
        self.cframe = ttk.Frame(self); self.cframe.pack(side="left", fill="both", expand=True)
        self.canvas = None

    # -------------- Fundamentals panel ------------------
    def _side(self):
        sp = ttk.Frame(self, width=270); sp.pack(side="right", fill="y", padx=6, pady=6)
        self.lbl = {}; ttk.Label(sp, text="Fundamentales", font=("Segoe UI", 10, "bold"))\
            .pack(anchor="w", pady=(0, 6))
        for k in ["MarketCap", "PER", "EPS", "DivYield", "Revenue", "NetIncome"]:
            l = ttk.Label(sp, text=f"{k}: —", justify="left"); l.pack(anchor="w", pady=2); self.lbl[k] = l

    # -------------- Data fetch / plot -------------------
    def fetch(self, *_):
        tic = self.ticker.get().strip().upper()
        if not tic: return
        per = self.period.get() or "1mo"
        self.status["text"] = "Descargando…"; self.update()

        intr = {"1d": "5m", "5d": "30m", "1mo": "1d", "1y": "1d"}[per]
        df = yf.download(tic, period=per, interval=intr, auto_adjust=False, progress=False)
        if df.empty:
            messagebox.showinfo("Vacío", "Yahoo no devolvió datos."); return
        if isinstance(df.columns, pd.MultiIndex):
            df.columns = df.columns.get_level_values(0)
        if "Close" not in df:
            df["Close"] = df["Adj Close"]
        self.df = add_ind(df)
        self._draw_chart()
        self._fundamentals(tic)
        self.status["text"] = "Actualizado"

    def _draw_chart(self):
        for w in self.cframe.winfo_children(): w.destroy()
        ap = []
        if self.show_sma.get(): ap.append(mpf.make_addplot(self.df["SMA20"], color="blue"))
        if self.show_ema.get(): ap.append(mpf.make_addplot(self.df["EMA20"], color="orange"))
        if self.show_boll.get():
            ap += [mpf.make_addplot(self.df["BollU"], color="grey", alpha=0.25),
                   mpf.make_addplot(self.df["BollL"], color="grey", alpha=0.25)]
        ratios = (5, 1) if self.show_macd.get() else None
        if self.show_macd.get():
            ap += [mpf.make_addplot(self.df["MACD"], panel=1, color="cyan"),
                   mpf.make_addplot(self.df["MACDs"], panel=1, color="magenta")]
        style = STYLE[self.theme.get()]
        lo, hi = self.df["Low"].min(), self.df["High"].max()
        fig, ax = mpf.plot(self.df, type='candle', volume=True,
                           addplot=ap, style=style, returnfig=True,
                           panel_ratios=ratios,
                           title=f"{self.ticker.get()} – {self.period.get()}")

        ax[0].axhspan(lo, hi, alpha=0.05, color='yellow')
        self.canvas = FigureCanvasTkAgg(fig, master=self.cframe)
        self.canvas.draw(); self.canvas.get_tk_widget().pack(fill="both", expand=True)
        mplcursors.cursor(ax[0].containers[0], hover=True).connect("add", self._tip)

    def _tip(self, sel):
        i = int(sel.target.index); r = self.df.iloc[i]
        sel.annotation.set(text=f"{r.name:%Y-%m-%d}\nO:{r.Open:.2f}  H:{r.High:.2f}\n"
                                f"L:{r.Low:.2f}  C:{r.Close:.2f}",
                           fontsize=8, bbox=dict(boxstyle="round", fc="w", alpha=0.8))

    # -------------- Fundamentals ------------------------
    def _fundamentals(self, t):
        y = yf.Ticker(t); fi, info = y.fast_info, y.info
        def g(kf, ki):
            v = fi.get(kf)
            return v if v not in (None, np.nan) else info.get(ki)
        m = {
            "MarketCap": fmt_num(g("market_cap", "marketCap")),
            "PER": fmt_num(g("trailing_pe", "trailingPE")) + "×",
            "EPS": fmt_num(g("eps", "trailingEps")),
            "DivYield": f"{(g('dividend_yield','dividendYield') or 0)*100:.2f} %",
            "Revenue": fmt_num(info.get("totalRevenue")),
            "NetIncome": fmt_num(info.get("netIncomeToCommon")),
        }
        for k, v in m.items(): self.lbl[k]["text"] = f"{k}: {v}"

    # -------------- Pop-up Financials -------------------
    def _popup_fin(self):
        if not hasattr(self, "df"): return
        y = yf.Ticker(self.ticker.get())
        t = tk.Toplevel(self); t.title("Estados financieros"); t.geometry("700x420")
        nb = ttk.Notebook(t); nb.pack(fill="both", expand=True)
        for tab, dget in [("Income", y.income_stmt),
                          ("Balance", y.balance_sheet),
                          ("Cashflow", y.cashflow)]:
            df = dget.fillna(np.nan)
            fr = ttk.Frame(nb); nb.add(fr, text=tab)
            cols = ["Concepto"] + [c.date() for c in df.columns]
            tree = ttk.Treeview(fr, columns=cols, show="headings")
            for c in cols: tree.heading(c, text=str(c))
            for idx, row in df.iterrows():
                tree.insert("", tk.END, values=[idx] + [fmt_num(v) for v in row])
            tree.pack(fill="both", expand=True)
            ttk.Scrollbar(fr, orient="vertical", command=tree.yview)\
                .pack(side="right", fill="y")
            tree.configure(yscrollcommand=lambda *args, tr=tree: tr.yview(*args))

    # -------------- Export ------------------------------
    def _to_csv(self):
        if not hasattr(self, "df"): return
        fn = filedialog.asksaveasfilename(defaultextension=".csv",
                                          initialfile=f"{self.ticker.get()}_{self.period.get()}.csv")
        if fn:
            self.df.to_csv(fn); os.startfile(Path(fn).parent)

    def _to_png(self):
        if self.canvas:
            fn = filedialog.asksaveasfilename(defaultextension=".png",
                                              initialfile=f"{self.ticker.get()}_{self.period.get()}.png")
            if fn:
                self.canvas.figure.savefig(fn, dpi=150); os.startfile(Path(fn).parent)

    # -------------- Watchlist ops -----------------------
    def _add_watch(self):
        t = self.ticker.get().strip().upper()
        if t and t not in self.watch:
            self.watch.append(t); self.lst.insert(tk.END, t)

    def _del_watch(self):
        sel = self.lst.curselection()
        if sel:
            idx = sel[0]; self.watch.pop(idx); self.lst.delete(idx)

    def _select_watch(self, *_):
        sel = self.lst.curselection()
        if sel:
            self.ticker.set(self.lst.get(sel)); self.fetch()

    # -------------- Range zoom --------------------------
    def _range(self, days):
        if not hasattr(self, "df"): return
        if days is None:  # max
            df = self.df
        elif days == "YTD":
            this_year = date.today().replace(month=1, day=1)
            df = self.df[self.df.index >= str(this_year)]
        else:
            df = self.df.iloc[-days:]
        self.df = df; self._draw_chart()

    def _ytd(self): self._range("YTD")

    # -------------- Theme swap --------------------------
    def _swap_theme(self): self.theme.set("dark" if self.theme.get() == "light" else "light"); self._draw_chart()

    # -------------- Save / load prefs -------------------
    def load_settings(self):
        d = {}
        if CFG.exists():
            try: d = json.loads(CFG.read_text())
            except Exception: pass
        self.ticker.set(d.get("ticker", "AAPL"))
        self.period.set(d.get("period", "1mo"))
        self.theme.set(d.get("theme", "light"))
        self.watch = d.get("watch", ["AAPL", "MSFT", "TSLA"])
        self.show_sma.set(d.get("sma", True))
        self.show_ema.set(d.get("ema", False))
        self.show_boll.set(d.get("boll", False))
        self.show_macd.set(d.get("macd", False))

    def save_settings(self):
        data = dict(ticker=self.ticker.get(), period=self.period.get(),
                    theme=self.theme.get(), watch=self.watch,
                    sma=self.show_sma.get(), ema=self.show_ema.get(),
                    boll=self.show_boll.get(), macd=self.show_macd.get())
        try: CFG.write_text(json.dumps(data))
        except Exception: pass

    def quit(self):
        self.save_settings()
        super().quit()


if __name__ == "__main__":
    app = App()
    app.protocol("WM_DELETE_WINDOW", app.quit)
    app.mainloop()

