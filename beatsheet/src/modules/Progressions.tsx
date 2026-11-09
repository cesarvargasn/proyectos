import { useEffect, useMemo, useRef, useState } from 'react'
import { engine } from '../audio/engine'
import { NotesPanel } from '../components/NotesPanel'
import { PianoRoll } from '../components/PianoRoll'
import type { RollNote } from '../components/PianoRoll'
import { TipList } from '../components/TipList'
import { PROGRESSIONS } from '../data/progressions'
import { buildChord, diatonicDegrees, keyLabel, keyNeighbors, romanToIndex } from '../lib/theory'
import { useLocalStorage } from '../lib/useLocalStorage'
import { useIsPlaying, useStopOnUnmount } from '../lib/useTransport'
import { smoothVoicings } from '../lib/voicing'
import { useMusic } from '../state/MusicContext'
import type { DiatonicDegree, Progression } from '../types'

const OWNER = 'progressions'
const STEPS_PER_BAR = 4

/**
 * Resuelve un grado romano contra la tonalidad.
 * Si el romano viene en mayúscula pero el grado natural es menor (el caso del
 * V en tonalidad menor), usa la versión de menor armónica. Así 'i-VII-VI-V'
 * mantiene el VII natural y convierte solo el V.
 */
function resolveDegree(
  roman: string,
  natural: DiatonicDegree[],
  harmonic: DiatonicDegree[],
): DiatonicDegree {
  const idx = romanToIndex(roman)
  const core = roman.replace(/[^ivxIVX]/g, '')
  const wantsMajor = core === core.toUpperCase()
  const nat = natural[idx]
  const natIsMajor = nat.quality === 'major' || nat.quality === 'aug'
  if (wantsMajor !== natIsMajor) return harmonic[idx]
  return nat
}

export default function Progressions() {
  const { root, mode, setKey, label } = useMusic()
  const [progId, setProgId] = useLocalStorage('progId', PROGRESSIONS[0].id)
  const prog: Progression = PROGRESSIONS.find((p) => p.id === progId) ?? PROGRESSIONS[0]

  const [jazzify, setJazzify] = useState(!!prog.sevenths)
  const [smooth, setSmooth] = useLocalStorage('progSmooth', true)
  const [bar, setBar] = useState<number | null>(null)
  const playing = useIsPlaying(OWNER)
  useStopOnUnmount(OWNER)

  // Las progresiones se leen sobre su propio modo, con la tónica global.
  const natural = useMemo(() => diatonicDegrees(root, prog.mode, false), [root, prog.mode])
  const harmonic = useMemo(() => diatonicDegrees(root, prog.mode, true), [root, prog.mode])

  const degrees = useMemo(
    () => prog.degrees.map((r) => resolveDegree(r, natural, harmonic)),
    [prog.degrees, natural, harmonic],
  )

  const chords = useMemo(() => {
    const raw = degrees.map((d) =>
      buildChord(d.root, jazzify ? d.seventhIntervals : d.intervals, 4),
    )
    return smooth ? smoothVoicings(raw) : raw
  }, [degrees, jazzify, smooth])

  const chordsRef = useRef(chords)
  chordsRef.current = chords

  useEffect(() => {
    if (!playing) setBar(null)
  }, [playing])

  // Cambiar de progresión respeta si esa progresión pide séptimas por defecto.
  const loadProgression = (p: Progression) => {
    setProgId(p.id)
    setJazzify(!!p.sevenths)
  }

  const toggleTransport = () => {
    if (playing) {
      engine.stopAll()
      return
    }
    void engine.startChordLoop({
      owner: OWNER,
      getChords: () => chordsRef.current,
      onBar: setBar,
    })
  }

  const rollNotes: RollNote[] = chords.flatMap((chord, i) =>
    chord.map((m) => ({
      midi: m,
      start: i * STEPS_PER_BAR,
      length: STEPS_PER_BAR,
      active: bar === i,
    })),
  )

  const modeMismatch = prog.mode !== mode
  const relative = keyNeighbors(root, mode).relative

  return (
    <div className="grid gap-4">
      {/* ------------------------------------------------ presets */}
      <section className="panel p-4">
        <h2 className="label mb-2">Progresiones</h2>
        <div className="flex flex-wrap gap-2">
          {PROGRESSIONS.map((p) => (
            <button
              key={p.id}
              type="button"
              onClick={() => loadProgression(p)}
              className={`btn ${p.id === prog.id ? 'btn-active' : ''}`}
            >
              <span className="font-mono">{p.name}</span>
            </button>
          ))}
        </div>
        <div className="mt-3 border-l-2 border-orange/70 pl-3">
          <p className="text-sm text-ink/90">{prog.note}</p>
          <p className="text-[11px] text-muted mt-1 font-mono">{prog.genres.join(' · ')}</p>
        </div>
      </section>

      {/* ------------------------------------------------ transport */}
      <section className="panel p-4 flex items-center gap-3 flex-wrap">
        <button
          type="button"
          className={`btn ${jazzify ? 'btn-orange' : ''}`}
          onClick={() => setJazzify(!jazzify)}
          title="Añade la séptima diatónica a cada acorde"
        >
          Jazzificar (séptimas)
        </button>
        <button
          type="button"
          className={`btn ${smooth ? 'btn-active' : ''}`}
          onClick={() => setSmooth(!smooth)}
          title="Elige inversiones para que los acordes no salten"
        >
          Enlazar voicings
        </button>
        <button
          type="button"
          className={`btn text-xs ${playing ? 'btn-orange' : ''}`}
          onClick={toggleTransport}
          title="Comprobación rápida de oído"
        >
          {playing ? '■ stop' : '▶ oír en loop'}
        </button>
        <div className="flex-1" />
        <span className="font-mono text-sm text-muted">
          tonalidad <span className="text-orange">{keyLabel(root, prog.mode)}</span> · 1 acorde por
          compás
        </span>
      </section>

      {modeMismatch && (
        <p className="text-sm text-orange/90 border-l-2 border-orange pl-3">
          Esta progresión está pensada en {prog.mode === 'minor' ? 'menor' : 'mayor'} y tu tonalidad
          global es {label}. Se está tocando sobre {keyLabel(root, prog.mode)}.{' '}
          <button
            type="button"
            className="underline hover:text-orange"
            onClick={() => setKey(relative.tonic, relative.mode)}
          >
            Cambiar a la relativa ({keyLabel(relative.tonic, relative.mode)})
          </button>
          .
        </p>
      )}

      {/* ------------------------------------------------ acordes */}
      <section className="panel p-4">
        <h3 className="label mb-3">Acordes</h3>
        <div className="flex flex-wrap gap-2">
          {degrees.map((d, i) => (
            <button
              key={`${d.roman}-${i}`}
              type="button"
              onClick={() => void engine.playChord(chords[i], '2n')}
              className={`panel px-4 py-3 min-w-[110px] text-center transition-colors ${
                bar === i ? 'border-lime bg-lime/10' : 'hover:border-lime/60'
              }`}
            >
              <div className="font-mono text-orange text-sm">{prog.degrees[i]}</div>
              <div className={`font-mono text-2xl ${bar === i ? 'text-lime' : 'text-ink'}`}>
                {jazzify ? d.seventhSymbol : d.symbol}
              </div>
              <div className="text-[10px] text-muted mt-0.5">compás {i + 1}</div>
            </button>
          ))}
        </div>
      </section>

      {/* ------------------------------------------------ piano roll */}
      <section>
        <h3 className="label mb-2">Piano roll — un acorde por compás</h3>
        <PianoRoll
          notes={rollNotes}
          steps={chords.length * STEPS_PER_BAR}
          stepsPerBeat={STEPS_PER_BAR}
          stepWidth={30}
          rowHeight={16}
          playhead={bar === null ? null : bar * STEPS_PER_BAR}
        />
        <p className="text-[11px] text-muted mt-1.5">
          Cada bloque dura un compás entero. En FL: pega los bloques con snap a 1 compás y luego
          juega con la duración para cambiar el groove.
        </p>
      </section>

      <TipList module="progressions" title="Trucos de progresiones" />
      <NotesPanel moduleId="progressions" />
    </div>
  )
}
