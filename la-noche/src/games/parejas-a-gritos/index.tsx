import type { GameCtx, GameDefinition, GameState } from '../../engine/types'
import { Button } from '../../ui/Button'
import { Card } from '../../ui/Card'

/**
 * Parejas a Gritos (027, rediseño con feedback de César): el juego de César,
 * ahora puro repartidor de palabras.
 *
 * Dos correcciones suyas sobre la v1:
 *  1. NO son pistas — se GRITA la palabra tal cual. Ese es el juego: dos
 *     personas tienen la misma palabra y se encuentran porque la oyen.
 *     ("tiene que lit decir la palabra, por eso se la pusimos")
 *  2. Se cayó la fase de elegir quién tenía tu palabra, y con ella los
 *     puntos y el podio. Se encuentran en vivo; la app solo pasa a la
 *     siguiente palabra.
 *
 * Además el host da la señal ("grítala cuando te diga"): reparto → el host
 * grita ¡YA! → gritos → siguiente palabra.
 */
interface PjState extends GameState {
  round_idx?: number
  rounds_total?: number
}

function PjHeader({ st }: { st: PjState }) {
  return (
    <p style={{ color: 'var(--muted)', fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase' }}>
      Palabra {(st.round_idx ?? 0) + 1} de {st.rounds_total ?? 3}
    </p>
  )
}

function WordCard({ word }: { word: string }) {
  return (
    <Card accent="#7ED957">
      <p style={{ fontWeight: 700, fontSize: '0.8rem', textTransform: 'uppercase', color: 'var(--muted)' }}>
        Tu palabra (alguien más tiene la misma 👀)
      </p>
      <p style={{ fontFamily: 'var(--font-display)', fontSize: '2rem', lineHeight: 1.1 }}>{word}</p>
    </Card>
  )
}

function ParejasView({ ctx }: { ctx: GameCtx<PjState> }) {
  const { state: st, secret } = ctx
  const word = String(secret?.word ?? '…')

  if (st.phase === 'reparto') {
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <PjHeader st={st} />
        <WordCard word={word} />
        <Card>
          <p style={{ fontWeight: 700, textAlign: 'center' }}>
            🤫 Apréndetela y no la digas todavía. Espera la señal.
          </p>
        </Card>
      </div>
    )
  }

  if (st.phase === 'gritos') {
    return (
      <div style={{ display: 'grid', gap: 14 }}>
        <PjHeader st={st} />
        <WordCard word={word} />
        <Card accent="var(--coral)">
          <p style={{ fontFamily: 'var(--font-display)', fontSize: '1.3rem', textAlign: 'center' }}>
            📣 ¡GRITA TU PALABRA!
          </p>
          <p style={{ fontWeight: 700, textAlign: 'center', color: 'var(--muted)' }}>
            Tal cual, sin pistas. Encuentra al que grita la misma.
          </p>
        </Card>
      </div>
    )
  }

  return null
}

function ParejasHost({ ctx }: { ctx: GameCtx<PjState> }) {
  const { state: st, advance } = ctx
  const last = (st.round_idx ?? 0) + 1 >= (st.rounds_total ?? 3)

  if (st.phase === 'reparto') {
    return <Button big onClick={() => void advance(true)}>¡YA! 📣</Button>
  }
  if (st.phase === 'gritos') {
    return (
      <Button big onClick={() => void advance(true)}>
        {last ? 'Terminar juego 🏁' : 'Siguiente palabra →'}
      </Button>
    )
  }
  return null
}

const PHASE_TITLE: Record<string, string> = {
  reparto: 'Tu palabra',
  gritos: '¡A gritar!',
}

export const parejasGame: GameDefinition<PjState> = {
  id: 'parejas-a-gritos',
  nameEs: 'Parejas a Gritos',
  phaseTitle: (st) => PHASE_TITLE[st.phase] ?? st.phase,
  needsSecret: () => true,
  PlayerView: ParejasView,
  HostView: ParejasHost,
}
