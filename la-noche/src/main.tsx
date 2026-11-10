import React from 'react'
import ReactDOM from 'react-dom/client'
import '@fontsource/archivo-black'
import '@fontsource/space-grotesk/400.css'
import '@fontsource/space-grotesk/700.css'
import './styles/global.css'
import { App } from './App'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
)
