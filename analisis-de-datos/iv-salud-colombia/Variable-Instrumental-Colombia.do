**Punto 1 practico
clear all
ssc intall outreg2
ssc install estout
use "C:\Users\cesar\Downloads/politica"
*a
collapse (mean) lnw, by(politica anho)
sort anho



list
asdoc list
*b
clear all
use "C:\Users\cesar\Downloads/politica"
gen politica_anho = politica*anho
reg lnw politica anho politica_anho
outreg2 using "regpunt1.doc", replace
*e
reg lnw politica anho politica_anho profesional rural
outreg2 using "regpunt1n2.doc", replace
Punto 2
*** trabajo econoetri 2
clear
ssc install outreg2
use "C:\Users\cesar\Downloads\trabajo_fem.dta"
*B.
reg trabaja educ_madre educ_padre hijos_vivos


outreg2 using "Regresion1.doc"
*D.
predict trabaja_mpl, xb
sum trabaja_mpl
outreg2 using puntod.doc, replace sum(detail) keep(trabaja_mpl) eqkeep(mean N min max sd)
*f
estat hettest
*G
*estimar modelos y efectos mar
logit trabaja educ_madre educ_padre hijos_vivos
outreg2 using "logitG.doc", label replace
mfx compute, dydx at(mean)
outreg2 using "logitmar.doc", replace mfx
margins, dydx(*) at(educ_madre=10 educ_padre=3 hijos_vivos=0) post
outreg2 using "logitii.doc", append
estat classification
probit trabaja educ_madre educ_padre hijos_vivos
outreg2 using "probitG.doc", label replace
mfx compute, dydx at(mean)
outreg2 using "probitmar.doc", replace mfx
margins, dydx(*) at(educ_madre=10 educ_padre=3 hijos_vivos=0) post
outreg2 using "probitii.doc", append
estat classification