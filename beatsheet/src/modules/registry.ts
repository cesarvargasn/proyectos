import { lazy } from 'react'
import type { LazyExoticComponent, ComponentType } from 'react'

/**
 * Registro de módulos = la navegación por tabs.
 *
 * Para sumar un módulo de la Fase 2:
 *   1. crea src/modules/MiModulo.tsx con `export default function MiModulo()`
 *   2. agrega una entrada aquí
 * No hay que tocar App.tsx ni ningún módulo existente.
 */
export interface ModuleDef {
  id: string
  label: string
  /** subtítulo corto que se ve en el tab */
  hint: string
  Component: LazyExoticComponent<ComponentType>
}

export const MODULES: ModuleDef[] = [
  {
    id: 'circle',
    label: 'Tonalidad y acordes',
    hint: 'círculo, grados, extensiones',
    Component: lazy(() => import('./CircleOfFifths')),
  },
  {
    id: 'rhythms',
    label: 'Ritmos',
    hint: 'step sequencer',
    Component: lazy(() => import('./Rhythms')),
  },
  {
    id: 'progressions',
    label: 'Progresiones',
    hint: 'loops de acordes',
    Component: lazy(() => import('./Progressions')),
  },
]
