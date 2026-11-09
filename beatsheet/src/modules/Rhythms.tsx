import { useEffect, useRef, useState } from 'react'
import { engine } from '../audio/engine'
import { NotesPanel } from '../components/NotesPanel'
import { TipList } from '../components/TipList'
import { RHYTHMS, VOICE_LABEL, VOICE_ORDER } from '../data/rhythms'
import { parseNote } from '../lib/theory'
import { useLocalStorage } from '../lib/useLocalStorage'
import { useIsPlaying, useStopOnUnmount } from '../lib/useTransport'
import { useMusic } from '../state/MusicContext'
import type { DrumVoice, RhythmPattern, StepCount, Velocity } from '../types'

const OWNER = 'rhythms'

type Tracks = Record<DrumVoice, Velocity[]>

const VEL_CLASS: Record<Velocity, string> = {
  0: 'bg-[#26262B] hover:bg-[#33333A]',
  1: 'bg-lime/25 hover:bg-lime/35',
  2: 'bg-lime/60 hover:bg-lime/70',
  3: 'bg-lime hover:brightness-110',
}

const VEL_NAME: Record<Velocity, string> = {
  0: 'off',
  1: 'suave',
  2: 'medio',
  3: 'fuerte',
}

function cloneTracks(p: RhythmPattern): Tracks {
  const out = {} as Tracks
  for (const v of VOICE_ORDER) out[v] = [...p.tracks[v]]
  return out
}

export default function Rhythms() {
  const { root, bpm, setBpm } = useMusic()
  const [patternId, setPatternId] = useLocalStorage('rhythmId', RHYTHMS[0].id)
  const preset = RHYTHMS.find((r) => r.id === patternId) ?? RHYTHMS[0]

  const [tracks, setTracks] = useLocalStorage<Tracks>(
    `rhythmTracks:${preset.id}`,
    cloneTracks(preset),
  )
  const [steps, setSteps] = useState<StepCount>(preset.steps)
  const [playhead, setPlayhead] = useState<number | null>(null)
  const playing = useIsPlaying(OWNER)
  useStopOnUnmount(OWNER)

  // Refs para que el loop del transport lea siempre el patrón actual:
  // así puedes editar velocities sin parar la reproducción.
  const tracksRef = useRef(tracks)
  tracksRef.current = tracks
  const stepsRef = useRef<number>(steps)
  stepsRef.current = steps
  const subRef = useRef(24 + parseNote(root))
  subRef.current = 24 + parseNote(root)

  useEffect(() => {
    if (!playing) setPlayhead(null)
  }, [playing])

  const loadPreset = (p: RhythmPattern) => {
    setPatternId(p.id)
    setTracks(cloneTracks(p))
    setSteps(p.steps)
    setBpm(p.bpm)
  }

  const resetPreset = () => {
    setTracks(cloneTracks(preset))
    setSteps(preset.steps)
  }

  const cycle = (voice: DrumVoice, step: number) => {
    const next = [...tracks[voice]]
    const v = (((next[step] ?? 0) + 1) % 4) as Velocity
    next[step] = v
    setTracks({ ...tracks, [voice]: next })
    if (v > 0) void engine.previewHit(voice, v, subRef.current)
  }

  const randomizeHats = () => {
    const rand = (arr: Velocity[]): Velocity[] =>
      arr.map((v) => (v === 0 ? 0 : (((Math.floor(Math.random() * 3) + 1) as Velocity))))
    setTracks({
      ...tracks,
      hatClosed: rand(tracks.hatClosed),
      hatOpen: rand(tracks.hatOpen),
    })
  }

  const fillHats = () => {
    const pattern: Velocity[] = Array.from({ length: steps }, (_, i) =>
      i % 4 === 0 ? 3 : i % 2 === 0 ? 2 : 1,
    )
    setTracks({ ...tracks, hatClosed: pattern })
  }

  const toggleTransport = () => {
    if (playing) {
      engine.stopAll()
      return
    }
    void engine.startSequencer({
      owner: OWNER,
      getSteps: () => stepsRef.current,
      getTracks: () => tracksRef.current,
      get808Midi: () => subRef.current,
      onStep: setPlayhead,
    })
  }

  const stepWidth = steps === 32 ? 26 : 40

  return (
    <div className="grid gap-4">
      {/* ------------------------------------------------ presets */}
      <section className="panel p-4">
        <h2 className="label mb-2">Presets</h2>
        <div className="flex flex-wrap gap-2">
          {RHYTHMS.map((r) => (
            <button
              key={r.id}
              type="button"
              onClick={() => loadPreset(r)}
              className={`btn ${r.id === preset.id ? 'btn-active' : ''}`}
            >
              {r.name}
              <span className="text-muted text-[11px] ml-1.5 font-mono">{r.bpm}</span>
            </button>
          ))}
        </div>
        <div className="mt-3 border-l-2 border-orange/70 pl-3">
          <p className="text-sm text-ink/90">{preset.note}</p>
          <p className="text-[11px] text-muted mt-1 font-mono">
            {preset.genre} · {preset.bpmRange[0]}–{preset.bpmRange[1]} BPM · {preset.steps} steps
          </p>
          <p className="text-[11px] text-muted mt-0.5">{preset.source}</p>
        </div>
      </section>

      {/* ------------------------------------------------ transport */}
      <section className="panel p-4 flex items-center gap-3 flex-wrap">
        <button
          type="button"
          className={`btn ${playing ? 'btn-orange' : 'btn-active'} px-5`}
          onClick={toggleTransport}
        >
          {playing ? '■ Stop' : '▶ Play'}
        </button>
        <div className="flex items-center gap-1.5">
          <span className="label">BPM</span>
          <input
            type="range"
            min={60}
            max={180}
            value={bpm}
            onChange={(e) => setBpm(Number(e.target.value))}
            className="w-40 accent-lime"
          />
          <span className="font-mono text-lime w-10 text-right">{bpm}</span>
          <button type="button" className="btn text-xs" onClick={() => setBpm(preset.bpm)}>
            {preset.bpm}
          </button>
        </div>
        <div className="flex-1" />
        <button type="button" className="btn" onClick={randomizeHats}>
          🎲 Aleatorizar velocities de hats
        </button>
        <button type="button" className="btn" onClick={fillHats}>
          Hats 1/16 alternados
        </button>
        <button type="button" className="btn" onClick={resetPreset}>
          ↺ Volver al preset
        </button>
      </section>

      {/* ------------------------------------------------ sequencer */}
      <section className="panel p-4 overflow-x-auto">
        <div className="flex items-baseline justify-between mb-3 gap-3">
          <h2 className="label">Step sequencer — 1/16</h2>
          <p className="text-[11px] text-muted">
            Click cicla el step: off → suave → medio → fuerte. Puedes editar con el loop sonando.
          </p>
        </div>

        <div style={{ minWidth: 110 + steps * stepWidth }}>
          {/* numeración */}
          <div className="flex mb-1">
            <div style={{ width: 110 }} />
            {Array.from({ length: steps }, (_, i) => (
              <div
                key={i}
                className={`text-center font-mono text-[10px] ${
                  playhead === i ? 'text-orange' : i % 4 === 0 ? 'text-ink/70' : 'text-muted/50'
                }`}
                style={{ width: stepWidth }}
              >
                {i % 4 === 0 ? i / 4 + 1 : '·'}
              </div>
            ))}
          </div>

          {VOICE_ORDER.map((voice) => (
            <div key={voice} className="flex items-center mb-1">
              <button
                type="button"
                onClick={() => void engine.previewHit(voice, 3, subRef.current)}
                className="text-left font-mono text-xs text-muted hover:text-lime pr-2 shrink-0"
                style={{ width: 110 }}
                title="Oír esta voz"
              >
                {VOICE_LABEL[voice]}
              </button>
              <div className="flex">
                {Array.from({ length: steps }, (_, i) => {
                  const v = (tracks[voice]?.[i] ?? 0) as Velocity
                  const beatStart = i % 4 === 0
                  return (
                    <button
                      key={i}
                      type="button"
                      onClick={() => cycle(voice, i)}
                      title={`${VOICE_LABEL[voice]} · step ${i + 1} · ${VEL_NAME[v]}`}
                      className={`h-8 rounded-[3px] border transition-colors ${VEL_CLASS[v]} ${
                        playhead === i ? 'border-orange' : beatStart ? 'border-grid' : 'border-grid/40'
                      }`}
                      style={{ width: stepWidth - 3, marginRight: 3 }}
                    />
                  )
                })}
              </div>
            </div>
          ))}
        </div>

        <p className="text-[11px] text-muted mt-3">
          El 808 está afinado a la tonalidad global (
          <span className="font-mono text-orange">{root}</span>). Cámbiala en el círculo de quintas y
          el 808 la sigue.
        </p>
      </section>

      <TipList module="rhythms" title="Trucos de hats y batería" />
      <NotesPanel moduleId="rhythms" />
    </div>
  )
}
