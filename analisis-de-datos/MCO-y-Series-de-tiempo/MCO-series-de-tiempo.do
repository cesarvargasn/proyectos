// taller 3 de econometria 2. César Vargas 
// 2023-1

clear all
*Importar la base
use "C:\Users\cesar\Downloads\WDI.dta"
*Generar los logaritmos*
generate ln_GDP = ln(GDP)
generate ln_Capital = ln(Capital)
generate ln_Labor = ln(Labor)
*Regresion por MCO
regress ln_GDP ln_Capital ln_Labor
eststo regmco
*Ahora por efectos fijos
xtreg ln_GDP ln_Capital ln_Labor, fe
eststo regfe
*Exportar los datos
outreg2 [regmco regfe] using "regresionesfinal.doc", replace
*Punto c
areg ln_GDP ln_Capital ln_Labor, absorb(id)
eststo regdummy
outreg2 [regdummy regfe] using "regresionespuntc.doc", replace
** Punto 2
clear
use "C:\Users\cesar\Downloads\WDI.dta"
drop if id!=42


browse
tsset year
gen GDP_growth = 100 * (GDP / L.GDP - 1)
*Punto a
tsline GDP_growth, title("Crecimiento PIB Colombia")
*Punto b
hprescott GDP_growth, stub(GDP_growth_hp)
tsline GDP_growth GDP_growth_hp_GDP_growth_sm_1, name(tendencia, replace)
tsline GDP_growth_hp_GDP_growth_1, name(ciclo, replace)
graph combine tendencia ciclo, name(hprescott, replace) col(1)
*Punto c
set obs 23
replace year = 2022 in 23
replace id = 42 in 23
reg GDP year
predict gdp_lin
tsline GDP gdp_lin , name(g1, replace) title(Lineal: y=b0+b1t+u)
sort year
gen growthlin = 100 * (gdp_lin / L.gdp_lin - 1)
tsline GDP_growth growthlin , name(g3, replace) title(Predicción crecimiento: Lin)
reg GDP c.year##c.year
predict gdp_cua
tsline GDP gdp_cua , name(g2, replace) title(Cuadratico: y=b0+b1t+b2t^2+u)
gen growthcua = 100 * (gdp_cua / L.gdp_cua - 1)
tsline GDP_growth growthcua , name(g4, replace) title(Predicción crecimiento: Cuadrati)
reg GDP year
estat ic
mat akaike=r(S)
reg GDP c.year##c.year
estat ic
mat akaike=akaike\r(S)
mat rownames akaike = linlin sq
matlist akaike
browse
** Parte 4 creditos
clear all
*Base de datos depurada


import excel "C:\Users\cesar\Downloads\Salario minimo mineducacion.xlsx", sheet("Hoja1") firstrow
tsset Año
tssmooth exponential min_exp=Salariomínimomensual , forecast(4)
tssmooth hwinters min_hw=Salariomínimomensual , forecast(4) iterate(25)
tssmooth ma min_pms=Salariomínimomensual , window(3 0 0)
**segunda parte
clear all
*base depurada
import excel "C:\Users\cesar\Downloads\Banrep Tasa de cambio promedios.xlsx", sheet("Hoja1") firstrow
tsset Año
tssmooth exponential tasas_exp=Tasadecambio , forecast(4)
tssmooth hwinters tasa_hw=Tasadecambio , forecast(4) iterate(25)
tssmooth ma tasa_pms=Tasadecambio , window(3 0 0)