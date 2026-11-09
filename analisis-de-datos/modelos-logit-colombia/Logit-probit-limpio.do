// Proyecto: Modelos Logit y Probit en variables binarias de hogares colombianos
// Autor: César Andrés Vargas Nieto
// Curso: Herramientas para la toma de decisiones I
// Universidad de los Andes

// ----------------------------------------------------------------------
// PUNTO 1: Probabilidad de ahorrar ~ ingreso + género (Logit)
clear all
use "iefic_2016_s13.dta"

describe p2480 ingreso p35

logit p2480 ingreso p35
outreg2 using resultados_logit.doc, replace word ///
    ctitle("Logit: Ahorro ~ Ingreso + Género") dec(3)

// Efecto marginal del ingreso
margins, dydx(ingreso)

// Versión con ingreso en millones para interpretación más clara
gen ingreso_mill = ingreso / 1000000
logit p2480 ingreso_mill p35
margins, dydx(ingreso_mill)


// ----------------------------------------------------------------------
// PUNTO 2: Comparación de probabilidades predichas con logit
logit p2480 ingreso
predict prob_logit, pr

// Listar primeras observaciones para comparar
list p2480 prob_logit if _n <= 10

// Boxplot comparativo
graph box prob_logit, over(p2480)

// Promedio de probabilidades predichas por grupo
summarize prob_logit if p2480 == 1
summarize prob_logit if p2480 == 0
table p2480, statistic(mean prob_logit)


// ----------------------------------------------------------------------
// PUNTO 3: Ocupación ~ ingreso por pensión
clear all
use "pmd_2020.dta"

describe oc p7500s2a1

// Regresión lineal
reg oc p7500s2a1
outreg2 using regresion_oc.doc, replace word ///
    ctitle("Regresión Lineal: Ocupación ~ Ingreso por pensión") dec(4)

// Logit con ingresos en pesos
logit oc p7500s2a1
margins, dydx(p7500s2a1)

// Logit con ingreso en millones
gen pension_mill = p7500s2a1 / 1000000
logit oc pension_mill
margins, dydx(pension_mill)

// Predicciones con ambos métodos
reg oc p7500s2a1
predict ols_xb, xb

logit oc p7500s2a1
predict logit_pr, pr

// Gráfica comparativa de OLS vs Logit
twoway (scatter oc p7500s2a1, mcolor(gs12)) ///
       (connected ols_xb p7500s2a1, sort lcolor(blue)) ///
       (connected logit_pr p7500s2a1, sort lcolor(red) lpattern(dash)), ///
       legend(label(1 "Observado") label(2 "OLS") label(3 "Logit")) ///
       xtitle("Ingreso por pensión (pesos)") ///
       ytitle("Ocupación / Probabilidad") ///
       title("Comparación de Predicciones: OLS vs. Logit")


// ----------------------------------------------------------------------
// PUNTO 4: Subsidio de alimentación ~ educación + género (Logit)
clear all
use "pmd_2020.dta"

logit p6585s1 i.p6210 i.p6020
margins, dydx(*)  
margins i.p6210#i.p6020
