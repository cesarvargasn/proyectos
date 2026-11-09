import { useEffect, useState } from 'react'
import { engine } from '../audio/engine'
import { useMusic } from '../state/MusicContext'

export function Header() {
  const { label, bpm, setBpm, root, mode } = useMusic()
  const [audioOn, setAudioOn] = useState(engine.isStarted)
  const [playingOwner, setPlayingOwner] = useState<string | null>(engine.currentOwner)

  useEffect(() => engine.subscribeOwner(setPlayingOwner), [])

  const enableAudio = async () => {
    await engine.ensureStarted()
    engine.setBpm(bpm)
    setAudioOn(true)
  }

  return (
    <header className="border-b border-grid bg-panel/60 backdrop-blur sticky top-0 z-30">
      <div className="max-w-[1400px] mx-auto px-4 py-2.5 flex items-center gap-4 flex-wrap">
        <div className="flex items-baseline gap-2">
          <span className="font-mono font-bold tracking-tight text-lime text-lg">BEATSHEET</span>
          <span className="text-[11px] text-muted hidden sm:inline">chuleta de producción</span>
        </div>

        <div className="flex-1" />

        {/* tonalidad global */}
        <div className="flex items-center gap-2">
          <span className="label hidden sm:inline">Tonalidad</span>
          <span
            className="font-mono text-lg text-orange px-2 py-0.5 rounded border border-orange/40 bg-orange/10"
            title={`${root} ${mode === 'minor' ? 'menor' : 'mayor'}`}
          >
            {label}
          </span>
        </div>

        {/* BPM */}
        <div className="flex items-center gap-1.5">
          <span className="label hidden sm:inline">BPM</span>
          <button type="button" className="btn px-2 py-0.5" onClick={() => setBpm(bpm - 1)}>
            −
          </button>
          <input
            type="number"
            value={bpm}
            onChange={(e) => setBpm(Number(e.target.value))}
            className="w-16 bg-bg border border-grid rounded-md px-2 py-1 font-mono text-center
                       text-ink focus:outline-none focus:border-lime/60"
          />
          <button type="button" className="btn px-2 py-0.5" onClick={() => setBpm(bpm + 1)}>
            +
          </button>
        </div>

        {/* transport global */}
        {audioOn ? (
          <button
            type="button"
            className={`btn ${playingOwner ? 'btn-orange' : ''}`}
            onClick={() => engine.stopAll()}
            disabled={!playingOwner}
            title="Detener lo que esté sonando"
          >
            ■ Stop
          </button>
        ) : (
          <button
            type="button"
            className="btn text-xs"
            onClick={enableAudio}
            title="El navegador exige un click antes de dejar sonar nada"
          >
            ♪ activar audio
          </button>
        )}
      </div>
    </header>
  )
}
