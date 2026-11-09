// Proyecto: Análisis de clusters y ANOVA en hogares colombianos (2016 - 2020)
// Autor: César Andrés Vargas Nieto (Abril 2025)
// Basado en ejercicios de clase (Universidad de los Andes)

clear all

// Cargamos la base de datos sobre educación financiera de hogares
use "iefic_2016_s13"


// Reducimos la muestra al 10% para que no colapse el análisis
set seed 123456789
sample 10

// Empezamos con el método de clusters: single linkage
cluster singlelinkage p2962, name(cluster_sl)

// Ahora con complete linkage
cluster completelinkage p2962, name(cluster_cl)

// Graficamos los dendrogramas de ambos métodos (4 ramas principales)
cluster dendrogram cluster_sl, cutnumber(4) labels(p2962) xlabel(,angle(45)) showcount name(dendro_sl, replace)
cluster dendrogram cluster_cl, cutnumber(4) labels(p2962) xlabel(,angle(45)) showcount name(dendro_cl, replace)

// Ponemos los dos gráficos juntos
graph combine dendro_sl dendro_cl, ysize(12) xsize(6) ycommon

// Ahora asignamos los grupos (clusters) a cada observación
cluster generate cluster_sl_g4 = groups(4), name(cluster_sl)
cluster generate cluster_cl_g4 = groups(4), name(cluster_cl)

// Estadísticas básicas por cluster: media, desviación estándar y conteo
table cluster_sl_g4, stat(mean p2962) stat(sd p2962) stat(count p2962) nformat(%4.2f)
table cluster_cl_g4, stat(mean p2962) stat(sd p2962) stat(count p2962) nformat(%4.2f)


// ----------------------------------------------------------------------
// Punto 2: Ahora pasamos a la base de pobreza monetaria de 2020
clear all
use "pmd_2020.dta"

// Reducimos aún más la muestra (0.1%) porque con 1% el comando se caía
set seed 123456789
sample 0.1

// Clustering con average linkage sobre ingreso total
cluster averagelinkage ingtot, name(cluster_al)

// Dendrograma con 5 ramas principales
cluster dendrogram cluster_al, cutnumber(5) labels(ingtot) xlabel(,angle(45)) showcount name(dendro_al, replace)

// Asignamos los clusters
cluster generate cluster_al_g5 = groups(5), name(cluster_al)

// Sacamos estadísticas de cada grupo
table cluster_al_g5, stat(mean ingtot) stat(sd ingtot) stat(min ingtot) stat(max ingtot) stat(count ingtot) nformat(%4.2f)

// Hacemos una gráfica para ver si la distribución es de cola larga
histogram ingtot, bin(30) percent normal title("Distribución del Ingreso Total") xlabel(, angle(45))


// ----------------------------------------------------------------------
// Punto 3: ANOVA con género y hábito de ahorro
clear all
use "iefic_2016_s13.dta"

// Revisamos las variables que vamos a usar
describe p35 p2480

// Ejecutamos el ANOVA: ingreso según género, hábito de ahorro y su interacción
anova ingreso i.p35 i.p2480 i.p35#i.p2480

// Sacamos promedios marginales
margins p35 p2480 p35#p2480
margins i.p2480, pwcompare
margins i.p35, pwcompare

// Graficamos los resultados
marginsplot


// ----------------------------------------------------------------------
// Punto 4: ANOVA con género y ocupación
clear all
use "pmd_2020.dta"

// Ingreso según género, ocupación y su interacción
anova ingtot i.p6020 i.oc i.p6020#i.oc

// Sacamos promedios marginales por grupo
margins i.p6020 i.oc i.p6020#i.oc
margins i.p6020, pwcompare
margins i.oc, pwcompare
margins i.p6020#i.oc, pwcompare
