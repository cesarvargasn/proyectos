import { useMemo, useState } from 'react'
import { engine } from '../audio/engine'
import { NotesPanel } from '../components/NotesPanel'
import { PianoRoll } from '../components/PianoRoll'
import type { RollNote } from '../components/PianoRoll'
import { TipList } from '../components/TipList'
import { CHORD_QUALITIES } from '../data/chords'
import { buildDegreeChord, DEFAULT_OPTIONS, intervalLabel } from '../lib/chordSpec'
import type { ChordOptions } from '../lib/chordSpec'
import { useLocalStorage } from '../lib/useLocalStorage'
import { useMusic } from '../state/MusicContext'
import {
  CIRCLE,
  circleIndexOf,
  diatonicDegrees,
  keyLabel,
  keyNeighbors,
  keySignature,
  parseNote,
  spellScale,
} from '../lib/theory'
import type { Mode } from '../types'

// ---------------------------------------------------------------- geometría

const SIZE = 420
const C = SIZE / 2
const R_OUT = 202
const R_MID = 146
const R_IN = 88

function polar(r: number, deg: number): [number, number] {
  const a = ((deg - 90) * Math.PI) / 180
  return [C + r * Math.cos(a), C + r * Math.sin(a)]
}

function arcPath(rO: number, rI: number, a0: number, a1: number): string {
  const [x0, y0] = polar(rO, a0)
  const [x1, y1] = polar(rO, a1)
  const [x2, y2] = polar(rI, a1)
  const [x3, y3] = polar(rI, a0)
  const large = a1 - a0 > 180 ? 1 : 0
  return `M${x0} ${y0} A${rO} ${rO} 0 ${large} 1 ${x1} ${y1} L${x2} ${y2} A${rI} ${rI} 0 ${large} 0 ${x3} ${y3} Z`
}

// ---------------------------------------------------------------- toggles

function Toggle({
  on,
  onClick,
  children,
  flavor,
  accent = false,
  disabled = false,
}: {
  on: boolean
  onClick: () => void
  children: React.ReactNode
  flavor?: string
  accent?: boolean
  disabled?: boolean
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className={`text-left panel px-3 py-2 transition-colors disabled:opacity-40 ${
        on
          ? accent
            ? 'border-orange bg-orange/15'
            : 'border-lime bg-lime/15'
          : 'hover:border-grid/80'
      }`}
    >
      <span
        className={`font-mono text-sm ${on ? (accent ? 'text-orange' : 'text-lime') : 'text-ink'}`}
      >
        {children}
      </span>
      {flavor && <span className="block text-[11px] text-muted leading-tight mt-0.5">{flavor}</span>}
    </button>
  )
}

/** Botón de audio discreto. El sonido es una comprobación rápida, no el producto. */
function Listen({ onClick, title }: { onClick: () => void; title: string }) {
  return (
    <button
      type="button"
      onClick={onClick}
      title={title}
      className="shrink-0 w-7 h-7 rounded border border-grid text-muted text-xs
                 hover:border-lime/60 hover:text-lime transition-colors"
    >
      ▶
    </button>
  )
}

// ---------------------------------------------------------------- módulo

export default function CircleOfFifths() {
  const { root, mode, setKey, label } = useMusic()
  const [harmonicV, setHarmonicV] = useState(true)
  const [selected, setSelected] = useLocalStorage('degree', 0)
  const [opts, setOpts] = useLocalStorage<ChordOptions>('chordOptions', DEFAULT_OPTIONS)
  const [showTable, setShowTable] = useLocalStorage('showChordTable', false)

  const set = <K extends keyof ChordOptions>(k: K, v: ChordOptions[K]) => setOpts({ ...opts, [k]: v })

  const activeIdx = circleIndexOf(root, mode)
  const sig = useMemo(() => keySignature(root, mode), [root, mode])
  const scale = useMemo(() => spellScale(root, mode), [root, mode])
  const degrees = useMemo(() => diatonicDegrees(root, mode, harmonicV), [root, mode, harmonicV])
  const neighbors = useMemo(() => keyNeighbors(root, mode), [root, mode])

  const degree = degrees[Math.min(selected, degrees.length - 1)]
  // La armadura decide si los bajos de las inversiones se escriben con
  // bemoles o con sostenidos.
  const chord = useMemo(
    () => buildDegreeChord(degree, { ...opts, preferFlats: sig.kind === 'b' }),
    [degree, opts, sig.kind],
  )

  const outsideNotes = useMemo(() => {
    const inKey = new Set(scale.map(parseNote))
    const chromatic = ['C', 'C#/Db', 'D', 'D#/Eb', 'E', 'F', 'F#/Gb', 'G', 'G#/Ab', 'A', 'A#/Bb', 'B']
    return chromatic.filter((_, pc) => !inKey.has(pc))
  }, [scale])

  const rollNotes: RollNote[] = chord.notes.map((n) => ({
    midi: n.midi,
    start: 0,
    length: 16,
    label: intervalLabel(n.interval),
    accent: n.interval === 0,
  }))

  const playScale = () => {
    // Una escala de 7 notas abarca menos de una octava: el módulo 12 sobre la
    // tónica ya deja los grados en orden ascendente.
    const pcs = scale.map(parseNote)
    const start = 12 * (4 + 1) + pcs[0]
    const midi = pcs.map((pc) => start + ((pc - pcs[0] + 12) % 12))
    void engine.playArpeggio([...midi, start + 12], 0.14)
  }

  const goTo = (t: { tonic: string; mode: Mode }) => setKey(t.tonic, t.mode)

  return (
    <div className="grid gap-4">
      {/* ---------------------------------------------------- rueda + datos */}
      <div className="grid gap-4 lg:grid-cols-[440px_1fr] items-start">
        <section className="panel p-4">
          <h2 className="label mb-1">Círculo de quintas</h2>
          <p className="text-sm text-muted mb-3">
            Anillo exterior: mayores. Anillo interior: su relativa menor. Click = tonalidad global.
          </p>
          <svg viewBox={`0 0 ${SIZE} ${SIZE}`} className="w-full max-w-[420px] mx-auto block">
            {CIRCLE.map((k, i) => {
              const a0 = i * 30 - 15
              const a1 = i * 30 + 15
              const majorOn = mode === 'major' && i === activeIdx
              const minorOn = mode === 'minor' && i === activeIdx
              const [mx, my] = polar((R_OUT + R_MID) / 2, i * 30)
              const [nx, ny] = polar((R_MID + R_IN) / 2, i * 30)
              return (
                <g key={i}>
                  <path
                    d={arcPath(R_OUT, R_MID, a0, a1)}
                    className="cursor-pointer transition-colors"
                    fill={majorOn ? '#A6C93B' : '#26262B'}
                    stroke="#3A3A40"
                    onClick={() => setKey(k.major, 'major')}
                  />
                  <text
                    x={mx}
                    y={my}
                    textAnchor="middle"
                    dominantBaseline="central"
                    className="pointer-events-none font-mono"
                    fontSize={majorOn ? 20 : 17}
                    fontWeight={majorOn ? 700 : 500}
                    fill={majorOn ? '#1B1B1F' : '#EDEDEF'}
                  >
                    {k.majorAlt ? `${k.major}/${k.majorAlt}` : k.major}
                  </text>

                  <path
                    d={arcPath(R_MID, R_IN, a0, a1)}
                    className="cursor-pointer transition-colors"
                    fill={minorOn ? '#F0A030' : '#202024'}
                    stroke="#3A3A40"
                    onClick={() => setKey(k.minor, 'minor')}
                  />
                  <text
                    x={nx}
                    y={ny}
                    textAnchor="middle"
                    dominantBaseline="central"
                    className="pointer-events-none font-mono"
                    fontSize={minorOn ? 17 : 14}
                    fontWeight={minorOn ? 700 : 500}
                    fill={minorOn ? '#1B1B1F' : '#9A9AA3'}
                  >
                    {k.minor}m
                  </text>
                </g>
              )
            })}

            <circle cx={C} cy={C} r={R_IN - 4} fill="#1B1B1F" stroke="#3A3A40" />
            <text
              x={C}
              y={C - 10}
              textAnchor="middle"
              className="font-mono"
              fontSize={34}
              fontWeight={700}
              fill="#A6C93B"
            >
              {label}
            </text>
            <text
              x={C}
              y={C + 18}
              textAnchor="middle"
              className="font-mono"
              fontSize={12}
              fill="#9A9AA3"
            >
              {sig.count === 0 ? 'sin alteraciones' : `${sig.count}${sig.kind}`}
            </text>
          </svg>
        </section>

        <section className="panel p-4 grid gap-4 md:grid-cols-2">
          <div>
            <h3 className="label mb-1">Armadura</h3>
            <p className="font-mono text-lime text-sm">{sig.text}</p>
            <p className="text-sm text-muted mt-2">
              Notas de la escala: <span className="font-mono text-ink">{scale.join(' ')}</span>
            </p>
            <p className="text-sm text-muted mt-1">
              Fuera de la escala (úsalas solo de paso):{' '}
              <span className="font-mono text-orange">{outsideNotes.join(' ')}</span>
            </p>
            <div className="mt-3 flex items-center gap-2">
              <Listen onClick={playScale} title="Oír la escala" />
              <span className="text-[11px] text-muted">oír la escala</span>
            </div>
          </div>

          <div>
            <h3 className="label mb-1">Modula fácil a</h3>
            <p className="text-sm text-muted mb-2">
              Comparten casi todas las notas con {label}: el salto no se oye forzado.
            </p>
            <div className="flex flex-wrap gap-2">
              <button type="button" className="btn" onClick={() => goTo(neighbors.relative)}>
                {keyLabel(neighbors.relative.tonic, neighbors.relative.mode)}
                <span className="text-muted text-xs ml-1">relativa</span>
              </button>
              <button type="button" className="btn" onClick={() => goTo(neighbors.fifthUp)}>
                {keyLabel(neighbors.fifthUp.tonic, neighbors.fifthUp.mode)}
                <span className="text-muted text-xs ml-1">5ª arriba</span>
              </button>
              <button type="button" className="btn" onClick={() => goTo(neighbors.fifthDown)}>
                {keyLabel(neighbors.fifthDown.tonic, neighbors.fifthDown.mode)}
                <span className="text-muted text-xs ml-1">5ª abajo</span>
              </button>
            </div>
          </div>
        </section>
      </div>

      {/* ---------------------------------------------------- grados */}
      <section className="panel p-4">
        <div className="flex items-center justify-between gap-3 flex-wrap mb-2">
          <h3 className="label">Grados diatónicos de {label}</h3>
          {mode === 'minor' && (
            <button
              type="button"
              className={`btn ${harmonicV ? 'btn-active' : ''}`}
              onClick={() => setHarmonicV(!harmonicV)}
            >
              V mayor (menor armónica)
            </button>
          )}
        </div>

        <p className="text-sm text-muted mb-3">
          Click en un grado para verlo abajo en el piano roll.{' '}
          {mode === 'minor'
            ? harmonicV
              ? 'Con la sensible subida el v se vuelve V mayor y resuelve mucho más fuerte al i. Es lo estándar; de paso convierte el VII en vii°.'
              : 'Menor natural pura: el v es menor y resuelve flojo. Prueba el toggle de arriba.'
            : 'Estos siete acordes son todo lo que "suena bien" en la tonalidad.'}
        </p>

        <div className="grid grid-cols-2 sm:grid-cols-4 lg:grid-cols-7 gap-2">
          {degrees.map((d) => {
            const on = d.index === selected
            return (
              <button
                key={d.index}
                type="button"
                onClick={() => setSelected(d.index)}
                className={`panel px-2 py-3 text-center transition-colors ${
                  on ? 'border-lime bg-lime/10' : 'hover:border-lime/60'
                }`}
              >
                <div className="font-mono text-orange text-sm">{d.roman}</div>
                <div className={`font-mono text-lg ${on ? 'text-lime' : 'text-ink'}`}>
                  {opts.seventh || opts.shell ? d.seventhSymbol : d.symbol}
                </div>
                <div className="text-[10px] text-muted mt-0.5">grado {d.index + 1}</div>
              </button>
            )
          })}
        </div>
      </section>

      {/* ---------------------------------------------------- acorde seleccionado */}
      <section className="grid gap-4 xl:grid-cols-[320px_1fr] items-start">
        <div className="panel p-4 grid gap-4">
          <div>
            <div className="flex items-center gap-2">
              <span className="font-mono text-orange text-sm">{degree.roman}</span>
              <Listen
                onClick={() => void engine.playChord(chord.midi, '1n')}
                title="Oír el acorde"
              />
            </div>
            <p className="font-mono text-4xl text-lime leading-tight mt-1">{chord.symbol}</p>
            <p className="font-mono text-xs text-muted mt-1">
              {chord.intervals.map(intervalLabel).join(' · ')} ({chord.intervals.join('-')} semitonos)
            </p>
          </div>

          <div>
            <h4 className="label mb-2">Extensiones</h4>
            <p className="text-[11px] text-muted mb-2 leading-tight">
              La séptima y la novena que se añaden son las de la tonalidad: no hay que elegir entre
              maj7 y m7, el grado ya decide.
            </p>
            <div className="grid gap-2">
              <Toggle
                on={opts.seventh}
                onClick={() => setOpts({ ...opts, seventh: !opts.seventh })}
                flavor={`séptima diatónica → ${degree.seventhSymbol}`}
              >
                7
              </Toggle>
              <Toggle
                on={opts.ninth}
                onClick={() => setOpts({ ...opts, ninth: !opts.ninth })}
                flavor={
                  opts.seventh
                    ? '9 sobre la séptima: R&B, lo-fi, funk según el grado.'
                    : 'sin séptima esto es un add9: brillo limpio, sin jazz.'
                }
              >
                9
              </Toggle>
              <Toggle
                on={opts.sixth}
                onClick={() => setOpts({ ...opts, sixth: !opts.sixth })}
                disabled={opts.seventh || opts.shell}
                flavor={
                  opts.seventh || opts.shell
                    ? 'la 6 y la 7 se pelean: quita la séptima.'
                    : '6: vintage. En menor huele a bossa.'
                }
              >
                6
              </Toggle>
              <div className="grid grid-cols-2 gap-2">
                <Toggle
                  on={opts.sus === 'sus2'}
                  onClick={() => set('sus', opts.sus === 'sus2' ? 'none' : 'sus2')}
                  flavor="abierto, ni mayor ni menor."
                >
                  sus2
                </Toggle>
                <Toggle
                  on={opts.sus === 'sus4'}
                  onClick={() => set('sus', opts.sus === 'sus4' ? 'none' : 'sus4')}
                  flavor="tensión que pide resolver."
                >
                  sus4
                </Toggle>
              </div>
              <Toggle
                on={opts.shell}
                accent
                onClick={() => setOpts({ ...opts, shell: !opts.shell })}
                flavor="1-3-7: solo lo esencial. Deja sitio al 808 y a la voz."
              >
                shell voicing
              </Toggle>
            </div>
          </div>

          <div>
            <h4 className="label mb-2">Inversión</h4>
            <div className="grid grid-cols-3 gap-2">
              {([0, 1, 2] as const).map((inv) => (
                <Toggle key={inv} on={opts.inversion === inv} onClick={() => set('inversion', inv)}>
                  {inv === 0 ? 'fund.' : `${inv}ª`}
                </Toggle>
              ))}
            </div>
            <p className="text-[11px] text-muted mt-1.5">
              {opts.inversion === 0
                ? 'fundamental abajo: sonido de bloque.'
                : opts.inversion === 1
                  ? 'tercera abajo: menos peso, más movimiento.'
                  : 'quinta abajo: flotante, buena para enlazar.'}
            </p>
          </div>

          <button
            type="button"
            className="btn"
            onClick={() => setOpts(DEFAULT_OPTIONS)}
            disabled={JSON.stringify(opts) === JSON.stringify(DEFAULT_OPTIONS)}
          >
            ↺ Triada limpia
          </button>
        </div>

        <div className="grid gap-2">
          <h4 className="label">Piano roll — cópialo tal cual a FL</h4>
          <PianoRoll
            notes={rollNotes}
            steps={16}
            stepsPerBeat={4}
            stepWidth={30}
            rowHeight={20}
            pad={2}
          />
          <p className="text-[11px] text-muted">
            Un compás. Las etiquetas de los bloques son el intervalo desde la fundamental, así
            reconoces la forma aunque cambies de tonalidad. El bloque naranja es la fundamental.
          </p>
        </div>
      </section>

      {/* ---------------------------------------------------- referencia */}
      <section className="panel">
        <button
          type="button"
          onClick={() => setShowTable(!showTable)}
          className="w-full flex items-center justify-between px-4 py-2.5 text-left"
        >
          <span className="label">Tabla de intervalos — todas las calidades</span>
          <span className="font-mono text-muted text-xs">{showTable ? '−' : '+'}</span>
        </button>
        {showTable && (
          <div className="px-4 pb-4 overflow-x-auto">
            <p className="text-sm text-muted mb-3">
              Semitonos desde la fundamental. Fuente de verdad en{' '}
              <span className="font-mono text-ink/70">src/data/chords.ts</span>. Cifrados mostrados
              sobre <span className="font-mono text-orange">{degree.root}</span>.
            </p>
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-muted border-b border-grid">
                  <th className="py-1.5 pr-3 font-normal">Cifrado</th>
                  <th className="py-1.5 pr-3 font-normal">Nombre</th>
                  <th className="py-1.5 pr-3 font-normal">Semitonos</th>
                  <th className="py-1.5 font-normal">Sabor</th>
                </tr>
              </thead>
              <tbody>
                {CHORD_QUALITIES.map((c) => (
                  <tr key={c.id} className="border-b border-grid/50">
                    <td className="py-1.5 pr-3 font-mono text-lime whitespace-nowrap">
                      {degree.root}
                      {c.symbol}
                    </td>
                    <td className="py-1.5 pr-3 text-ink/85 whitespace-nowrap">{c.name}</td>
                    <td className="py-1.5 pr-3 font-mono text-muted whitespace-nowrap">
                      {c.intervals.join('-')}
                    </td>
                    <td className="py-1.5 text-muted">{c.flavor}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <TipList module="circle" title="Sobre tonalidad" />
      <TipList module="chords" title="Trucos de voicing" />
      <NotesPanel moduleId="circle" />
    </div>
  )
}
