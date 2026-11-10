import { BrowserRouter, Routes, Route } from 'react-router-dom'
import { Home } from './pages/Home'
import { Join } from './pages/Join'
import { Lobby } from './pages/Lobby'
import { Game } from './pages/Game'
import { DesignDemo } from './pages/DesignDemo'
import { Cartas } from './pages/Cartas'

export function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Home />} />
        <Route path="/crear" element={<Join mode="create" />} />
        <Route path="/j/:code" element={<Join mode="join" />} />
        <Route path="/sala" element={<Lobby />} />
        <Route path="/juego" element={<Game />} />
        <Route path="/demo" element={<DesignDemo />} />
        <Route path="/cartas" element={<Cartas />} />
      </Routes>
    </BrowserRouter>
  )
}
