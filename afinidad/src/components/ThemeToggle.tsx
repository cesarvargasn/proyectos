import { useState } from 'react'
import { getTheme, toggleTheme, type Theme } from '../lib/theme'

export default function ThemeToggle() {
  const [theme, setThemeState] = useState<Theme>(getTheme)

  function handleToggle() {
    setThemeState(toggleTheme())
  }

  return (
    <button
      className="theme-toggle"
      onClick={handleToggle}
      aria-label={theme === 'dark' ? 'Cambiar a modo claro' : 'Cambiar a modo oscuro'}
      title={theme === 'dark' ? 'Modo claro' : 'Modo oscuro'}
    >
      {theme === 'dark' ? '☀' : '☾'}
    </button>
  )
}
