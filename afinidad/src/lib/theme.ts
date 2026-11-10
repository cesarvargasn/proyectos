export type Theme = 'light' | 'dark'

const KEY = 'matchnight_theme'
const DEFAULT: Theme = 'dark' // dark is the default; light stays available via the toggle

export function getTheme(): Theme {
  const saved = localStorage.getItem(KEY)
  return saved === 'dark' || saved === 'light' ? saved : DEFAULT
}

export function applyTheme(theme: Theme): void {
  document.documentElement.dataset.theme = theme
}

export function setTheme(theme: Theme): void {
  localStorage.setItem(KEY, theme)
  applyTheme(theme)
}

export function toggleTheme(): Theme {
  const next: Theme = getTheme() === 'dark' ? 'light' : 'dark'
  setTheme(next)
  return next
}
