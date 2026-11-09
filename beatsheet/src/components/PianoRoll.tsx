import { useMemo } from 'react'
import { isBlackKey, midiToName } from '../lib/theory'

export interface RollNote {
  midi: number
  /** step de inicio (0-indexado) */
  start: number
  /** duración en steps */
  length: number
  /** texto dentro del bloque (grado, intervalo, cifrado) */
  label?: string
  /** true = bloque naranja (seleccionado / destacado) */
  accent?: boolean
  /** true = bloque encendido (sonando ahora) */
  active?: boolean
}

interface Props {
  notes: RollNote[]
  /** ancho total de la grid en steps */
  steps: number
  /** cuántos steps forman una negra (4 = 1/16, 2 = 1/8) */
  stepsPerBeat?: number
  stepWidth?: number
  rowHeight?: number
  /** step actual del playhead, o null */
  playhead?: number | null
  /** margen de filas vacías arriba y abajo */
  pad?: number
  showKeys?: boolean
  onNoteClick?: (note: RollNote) => void
  className?: string
}

/**
 * Piano roll estilo FL Studio: bloques verde lima sobre grid oscura,
 * filas de teclas negras más oscuras. Es lo que el usuario replica en el DAW.
 */
export function PianoRoll({
  notes,
  steps,
  stepsPerBeat = 4,
  stepWidth = 26,
  rowHeight = 16,
  playhead = null,
  pad = 1,
  showKeys = true,
  onNoteClick,
  className = '',
}: Props) {
  const rows = useMemo(() => {
    if (notes.length === 0) return [] as number[]
    const min = Math.min(...notes.map((n) => n.midi)) - pad
    const max = Math.max(...notes.map((n) => n.midi)) + pad
    const out: number[] = []
    for (let m = max; m >= min; m--) out.push(m)
    return out
  }, [notes, pad])

  if (rows.length === 0) {
    return (
      <div className={`panel p-6 text-center text-muted text-sm ${className}`}>
        Nada que dibujar todavía.
      </div>
    )
  }

  const gridWidth = steps * stepWidth
  const height = rows.length * rowHeight
  const keyColWidth = showKeys ? 52 : 0

  return (
    <div className={`panel overflow-x-auto ${className}`}>
      <div className="flex" style={{ minWidth: keyColWidth + gridWidth }}>
        {/* columna de teclas */}
        {showKeys && (
          <div className="shrink-0 border-r border-grid" style={{ width: keyColWidth }}>
            {rows.map((m) => (
              <div
                key={m}
                className={`flex items-center justify-end pr-1.5 font-mono text-[10px] border-b border-grid/40 ${
                  isBlackKey(m) ? 'bg-[#141417] text-muted' : 'bg-[#2E2E34] text-ink/80'
                }`}
                style={{ height: rowHeight }}
              >
                {midiToName(m)}
              </div>
            ))}
          </div>
        )}

        {/* grid + notas */}
        <div className="relative" style={{ width: gridWidth, height }}>
          {/* filas */}
          {rows.map((m, i) => (
            <div
              key={m}
              className={`absolute left-0 right-0 border-b border-grid/30 ${
                isBlackKey(m) ? 'bg-[#202024]' : 'bg-[#26262B]'
              }`}
              style={{ top: i * rowHeight, height: rowHeight }}
            />
          ))}

          {/* líneas verticales: cada step y acento en cada negra */}
          {Array.from({ length: steps + 1 }, (_, s) => (
            <div
              key={s}
              className="absolute top-0 bottom-0"
              style={{
                left: s * stepWidth,
                width: 1,
                background: s % stepsPerBeat === 0 ? '#3A3A40' : '#3A3A4055',
              }}
            />
          ))}

          {/* playhead */}
          {playhead !== null && (
            <div
              className="absolute top-0 bottom-0 bg-orange/80 pointer-events-none"
              style={{ left: playhead * stepWidth, width: 2 }}
            />
          )}

          {/* notas */}
          {notes.map((n, i) => {
            const rowIdx = rows.indexOf(n.midi)
            if (rowIdx < 0) return null
            const color = n.accent
              ? 'bg-orange border-orange text-[#1B1B1F]'
              : n.active
                ? 'bg-lime border-white/70 text-[#1B1B1F]'
                : 'bg-lime/85 border-lime text-[#1B1B1F]'
            return (
              <button
                key={`${n.midi}-${n.start}-${i}`}
                type="button"
                onClick={onNoteClick ? () => onNoteClick(n) : undefined}
                disabled={!onNoteClick}
                title={midiToName(n.midi)}
                className={`absolute rounded-[3px] border font-mono text-[9px] leading-none flex items-center px-1 overflow-hidden ${color} ${
                  onNoteClick ? 'cursor-pointer hover:brightness-110' : 'cursor-default'
                }`}
                style={{
                  left: n.start * stepWidth + 1,
                  top: rowIdx * rowHeight + 1,
                  width: Math.max(6, n.length * stepWidth - 2),
                  height: rowHeight - 2,
                }}
              >
                {n.label}
              </button>
            )
          })}
        </div>
      </div>
    </div>
  )
}
