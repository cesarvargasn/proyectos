// Rondas embudo: nombres y colores de grupo por ronda (compartido admin + reveal).

export const FUNNEL_ROUNDS = 3 // + duplas finales = 4 etapas

const NAMES: Record<number, string[]> = {
  1: ['Sol', 'Luna'],
  2: ['Fuego', 'Agua', 'Tierra', 'Aire'],
  3: ['Lobos', 'Zorros', 'Búhos', 'Osos', 'Linces', 'Halcones', 'Cuervos', 'Pumas',
      'Ciervos', 'Jaguares', 'Delfines', 'Tigres', 'Cóndores', 'Nutrias', 'Panteras', 'Águilas'],
}

const COLORS = ['#C8400A', '#2F6FB5', '#3E8E41', '#B58A00', '#7A3FA0', '#B5305E', '#2A8C8C', '#8C5A2A']

export function groupName(round: number, idx: number): string {
  const list = NAMES[round] ?? []
  return list[idx] ?? `Grupo ${idx + 1}`
}

export function groupColor(idx: number): string {
  return COLORS[idx % COLORS.length]
}

export function roundLabel(round: number): string {
  if (round === 1) return 'Ronda 1 · 2 grupos'
  if (round === 2) return 'Ronda 2 · 4 grupos'
  if (round === 3) return 'Ronda 3 · grupos chicos'
  return 'Duplas'
}
