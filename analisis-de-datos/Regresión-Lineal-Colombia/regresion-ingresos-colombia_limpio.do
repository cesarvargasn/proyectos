// Proyecto: Análisis de regresiones y transformaciones logarítmicas en hogares colombianos
// Autor: César Andrés Vargas Nieto
// Curso: Herramientas para la toma de decisiones I
// Universidad de los Andes

// ----------------------------------------------------------------------
// PUNTO 1: Gasto en alimentación vs ingreso
clear all
use "iefic_2016_s13.dta"
// Regresión lineal simple
reg p2478_1 ingreso
// Exportar resultados a Word
outreg2 using resultados_taller3.doc, replace ctitle("Nivel") dec(3) title("Regresiones - Taller 3")

// Extraemos residuos y graficamos su varianza contra ingreso
predict resid, resid
gen resid_cuadrado = resid^2

scatter resid_cuadrado ingreso, ///
    title("Residuos al cuadrado vs Ingreso") ///
    ytitle("Residuos^2") xtitle("Ingreso") msymbol(o) msize(small)


// ----------------------------------------------------------------------
// PUNTO 1b: Transformación logarítmica
gen ln_gasto = ln(p2478_1) if p2478_1 > 0
gen ln_ingreso = ln(ingreso) if ingreso > 0

reg ln_gasto ln_ingreso
outreg2 using resultados_taller3.doc, append ctitle("Log-Log") dec(3)

predict resid_log, resid
gen resid_log2 = resid_log^2

scatter resid_log2 ln_ingreso, ///
    title("Residuos al cuadrado vs ln(Ingreso)") ///
    ytitle("Residuos^2") xtitle("ln(Ingreso)") msymbol(o) msize(small)


// ----------------------------------------------------------------------
// PUNTO 2: Gasto en educación vs ingreso y nivel educativo
clear all
use "iefic_2016_s13.dta"

drop if niveledu == 9 // Quitamos categorías inválidas

reg p407 ingreso i.niveledu

outreg2 using educacion.doc, replace ///
    ctitle("Gasto en educación") ///
    dec(3) label

predict resid2, resid
gen resid2_cuad = resid2^2

scatter resid2_cuad ingreso, ///
    title("Residuos² vs Ingreso") ///
    ytitle("Residuos²") xtitle("Ingreso") msymbol(o) msize(small)

graph box resid2_cuad, over(niveledu, label(angle(45))) ///
    title("Distribución de residuos² por nivel educativo") ///
    ytitle("Residuos²")


// ----------------------------------------------------------------------
// PUNTO 3: Factores que afectan ingresos por intereses
clear all
use "pmd_2020.dta"

reg p7510s5a1 ingtot i.p6210 i.p6090 i.estrato

outreg2 using punto3a.doc, replace ///
    ctitle("Intereses ~ Educ + Ingreso + SS + Estrato") ///
    dec(3) nolabel


// ----------------------------------------------------------------------
// PUNTO 4: Relación entre ingreso total y horas trabajadas
clear all
use "pmd_2020.dta"

// Modelo A: ingreso como función de horas
reg ingtot p6800

outreg2 using punto4a.doc, replace ///
    ctitle("Ingreso total ~ Horas trabajadas") dec(3) nolabel

// Modelo B: horas como función del ingreso
reg p6800 ingtot

outreg2 using punto4ainversa.doc, replace ///
    ctitle("Horas trabajadas ~ Ingreso total") dec(3) nolabel
