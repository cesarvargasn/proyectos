import xlwings as xw
import numpy as np

# 1. Abrimos tu Excel
wb = xw.Book(r"C:/Users/cesar/Downloads/Sport limited final.xlsx")
sht = wb.sheets['Escenarios']

# 2. Definimos número de simulaciones
n_simulaciones = 5000  # Ahora sí, 5,000 simulaciones
npvs = []

# 3. Simulamos
for i in range(n_simulaciones):
    
    # 3.1 Simulamos un valor para cada variable
    sales_growth = np.random.normal(0.07, 0.0025)   # Sales Growth simulado
    cogs = np.random.triangular(0.58, 0.59, 0.60)    # COGS simulado
    tax_rate = np.random.triangular(0.37, 0.38, 0.40)  # Taxes simulado

    # 3.2 Solo modificamos I5, I6, I13 (Excel hará el resto)
    sht.range('I5').value = sales_growth
    sht.range('I6').value = cogs
    sht.range('I13').value = tax_rate

    # 3.3 Recalculamos todo el Excel
    wb.app.calculate()

    # 3.4 Leemos el NPV en la celda C203
    npv = sht.range('C203').value
    npvs.append(npv)

    # 3.5 Imprimir progreso
    if i + 1 == int(n_simulaciones * 0.25):
        print("✅ 25% completado...")
    elif i + 1 == int(n_simulaciones * 0.5):
        print("✅ 50% completado...")
    elif i + 1 == int(n_simulaciones * 0.75):
        print("✅ 75% completado...")
    elif i + 1 == n_simulaciones:
        print("✅ 100% completado...")

# 4. Guardamos los resultados en un array de numpy
npvs = np.array(npvs)

# 5. Imprimimos resultados finales
print("\nResultados finales:")
print(f"NPV promedio: {npvs.mean():.2f} USD")
print(f"Probabilidad de NPV > 0: {(npvs > 0).mean() * 100:.2f}%")
print(f"Percentil 5 del NPV: {np.percentile(npvs, 5):.2f} USD")

np.save(r'C:/Users/cesar/Downloads/npvs.npy', npvs)

