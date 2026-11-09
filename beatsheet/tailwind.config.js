/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        bg: '#1B1B1F',
        panel: '#26262B',
        grid: '#3A3A40',
        lime: '#A6C93B',
        orange: '#F0A030',
        ink: '#EDEDEF',
        muted: '#9A9AA3',
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', 'Segoe UI', 'sans-serif'],
        mono: ['JetBrains Mono', 'Consolas', 'ui-monospace', 'monospace'],
      },
    },
  },
  plugins: [],
}
