import { BrowserRouter, Routes, Route, Navigate, useParams } from 'react-router-dom'
import Home from './pages/Home'
import Register from './pages/Register'
import Questionnaire from './pages/Questionnaire'
import Reveal from './pages/Reveal'
import Feedback from './pages/Feedback'
import AdminHome from './pages/AdminHome'
import AdminEvent from './pages/AdminEvent'
import ThemeToggle from './components/ThemeToggle'
import { getSession } from './lib/session'

function RequireSession({ children }: { children: React.ReactNode }) {
  const session = getSession()
  const { code } = useParams<{ code: string }>()
  if (!session) return <Navigate to={code ? `/e/${code}` : '/'} replace />
  return <>{children}</>
}

export default function App() {
  return (
    <BrowserRouter>
      <ThemeToggle />
      <Routes>
        <Route path="/" element={<Home />} />
        <Route path="/e/:code" element={<Register />} />
        <Route
          path="/e/:code/q"
          element={
            <RequireSession>
              <Questionnaire />
            </RequireSession>
          }
        />
        <Route
          path="/e/:code/reveal"
          element={
            <RequireSession>
              <Reveal />
            </RequireSession>
          }
        />
        <Route path="/e/:code/feedback" element={<Feedback />} />
        <Route path="/admin" element={<AdminHome />} />
        <Route path="/admin/:eventId" element={<AdminEvent />} />
      </Routes>
    </BrowserRouter>
  )
}
