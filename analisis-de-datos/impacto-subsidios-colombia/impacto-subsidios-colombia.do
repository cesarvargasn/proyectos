// taller 4 econometria 2

clear all
import excel "C:\Users\cesar\Downloads\PIB_producción.xlsx", sheet("Hoja1") firstrow
**Ahora identificar el modelo
gen tiempo = yq(Año, Trimestre)
tsset tiempo, quarterly
tsappend, add(3)
tsline Produccion
corrgram Produccion
ac Produccion
pac Produccion
dfuller Produccion, trend regress lags(2)
dfuller Produccion, trend regress lags(1)
*Estaconaria con un lag
ac Produccion
pac Produccion
*Estimamos
arima Produccion, arima(1,0,1)
arima Produccion, arima(1,0,0)
outreg2 using "Arimafinal.doc"
*
*Arima 1 0 0 queda al final
*Validamos
predict residuos, residuals
ac residuos
wntestq residuos
*Los residuales son ruido blanco
armaroots
*predecir
predict produccion_1, dynamic(tq(2021q3))
tsline produccion_1 Produccion
br