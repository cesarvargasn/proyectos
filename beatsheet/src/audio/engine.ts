import * as Tone from 'tone'
import type { DrumVoice, Velocity } from '../types'

/**
 * Motor de audio único de la app. Ningún componente habla con Tone.js directo.
 *
 * Reglas:
 *  - `ensureStarted()` antes de cualquier sonido (arranca el AudioContext).
 *  - Un solo Tone.Transport: solo un módulo reproduce a la vez. Arrancar algo
 *    nuevo detiene lo anterior y notifica al dueño anterior vía subscribeOwner.
 */

// ------------------------------------------------------------- utilidades

const VELOCITY_GAIN: Record<Velocity, number> = { 0: 0, 1: 0.32, 2: 0.62, 3: 1 }

export function midiToFreq(midi: number): number {
  return 440 * Math.pow(2, (midi - 69) / 12)
}

type OwnerListener = (owner: string | null) => void

// ------------------------------------------------------------- engine

class AudioEngine {
  private started = false
  private nodesReady = false

  private master!: Tone.Gain
  private limiter!: Tone.Limiter

  private poly!: Tone.PolySynth<Tone.Synth>
  private kick!: Tone.MembraneSynth
  private sub!: Tone.MembraneSynth
  private snareNoise!: Tone.NoiseSynth
  private snareBody!: Tone.Synth
  private clap!: Tone.NoiseSynth
  private hat!: Tone.NoiseSynth

  private loop: Tone.Loop | null = null
  private owner: string | null = null
  private listeners = new Set<OwnerListener>()

  // ---------------------------------------------------------- arranque

  private buildNodes() {
    if (this.nodesReady) return

    this.limiter = new Tone.Limiter(-1).toDestination()
    this.master = new Tone.Gain(0.85).connect(this.limiter)

    // Armonía / melodía: triangle suave, release corto, sin clicks.
    this.poly = new Tone.PolySynth(Tone.Synth, {
      oscillator: { type: 'triangle' },
      envelope: { attack: 0.012, decay: 0.22, sustain: 0.45, release: 0.5 },
    })
    this.poly.volume.value = -12
    this.poly.connect(this.master)

    this.kick = new Tone.MembraneSynth({
      pitchDecay: 0.035,
      octaves: 6,
      oscillator: { type: 'sine' },
      envelope: { attack: 0.001, decay: 0.32, sustain: 0, release: 0.2 },
    })
    this.kick.volume.value = -5
    this.kick.connect(this.master)

    // 808: mismo principio pero con cola larga y pitch afinable.
    this.sub = new Tone.MembraneSynth({
      pitchDecay: 0.14,
      octaves: 3,
      oscillator: { type: 'sine' },
      envelope: { attack: 0.004, decay: 0.9, sustain: 0.02, release: 0.5 },
    })
    this.sub.volume.value = -6
    this.sub.connect(this.master)

    const snareFilter = new Tone.Filter(1800, 'highpass').connect(this.master)
    this.snareNoise = new Tone.NoiseSynth({
      noise: { type: 'white' },
      envelope: { attack: 0.001, decay: 0.16, sustain: 0 },
    })
    this.snareNoise.volume.value = -12
    this.snareNoise.connect(snareFilter)

    this.snareBody = new Tone.Synth({
      oscillator: { type: 'triangle' },
      envelope: { attack: 0.001, decay: 0.11, sustain: 0, release: 0.05 },
    })
    this.snareBody.volume.value = -18
    this.snareBody.connect(this.master)

    const clapFilter = new Tone.Filter(1200, 'bandpass').connect(this.master)
    clapFilter.Q.value = 1.4
    this.clap = new Tone.NoiseSynth({
      noise: { type: 'pink' },
      envelope: { attack: 0.001, decay: 0.14, sustain: 0 },
    })
    this.clap.volume.value = -10
    this.clap.connect(clapFilter)

    const hatFilter = new Tone.Filter(8500, 'highpass').connect(this.master)
    this.hat = new Tone.NoiseSynth({
      noise: { type: 'white' },
      envelope: { attack: 0.001, decay: 0.04, sustain: 0 },
    })
    this.hat.volume.value = -20
    this.hat.connect(hatFilter)

    this.nodesReady = true
  }

  /** Arranca el AudioContext. Debe llamarse desde un gesto del usuario. */
  async ensureStarted(): Promise<void> {
    if (!this.started) {
      await Tone.start()
      this.started = true
    }
    this.buildNodes()
  }

  get isStarted(): boolean {
    return this.started
  }

  // ---------------------------------------------------------- transport

  setBpm(bpm: number) {
    Tone.getTransport().bpm.value = bpm
  }

  getBpm(): number {
    return Tone.getTransport().bpm.value
  }

  subscribeOwner(fn: OwnerListener): () => void {
    this.listeners.add(fn)
    return () => this.listeners.delete(fn)
  }

  private setOwner(owner: string | null) {
    this.owner = owner
    this.listeners.forEach((l) => l(owner))
  }

  get currentOwner(): string | null {
    return this.owner
  }

  /** Detiene el transport y libera el loop actual. */
  stopAll() {
    const transport = Tone.getTransport()
    transport.stop()
    transport.cancel(0)
    if (this.loop) {
      this.loop.stop(0)
      this.loop.dispose()
      this.loop = null
    }
    if (this.nodesReady) this.poly.releaseAll()
    if (this.owner !== null) this.setOwner(null)
  }

  private async startLoop(
    owner: string,
    interval: Tone.Unit.Time,
    cb: (time: number, tick: number) => void,
  ) {
    await this.ensureStarted()
    this.stopAll()
    let tick = 0
    this.loop = new Tone.Loop((time) => {
      cb(time, tick)
      tick += 1
    }, interval).start(0)
    this.setOwner(owner)
    Tone.getTransport().start('+0.05')
  }

  // ---------------------------------------------------------- one-shots

  /** Acorde en bloque. `midi` en notas MIDI absolutas. */
  async playChord(midi: number[], duration: Tone.Unit.Time = '2n', velocity = 0.8) {
    await this.ensureStarted()
    const freqs = midi.map(midiToFreq)
    this.poly.triggerAttackRelease(freqs, duration, undefined, velocity)
  }

  /** Arpegio ascendente. */
  async playArpeggio(midi: number[], noteDur = 0.16, velocity = 0.8) {
    await this.ensureStarted()
    const now = Tone.now()
    midi.forEach((m, i) => {
      this.poly.triggerAttackRelease(midiToFreq(m), noteDur * 1.6, now + i * noteDur, velocity)
    })
  }

  async playNote(midi: number, duration: Tone.Unit.Time = '8n', velocity = 0.8) {
    await this.ensureStarted()
    this.poly.triggerAttackRelease(midiToFreq(midi), duration, undefined, velocity)
  }

  /** Golpe de batería. `time` opcional para uso dentro del Transport. */
  hit(voice: DrumVoice, vel: Velocity, time?: number, subMidi = 33) {
    if (!this.nodesReady || vel === 0) return
    const g = VELOCITY_GAIN[vel]
    const t = time ?? Tone.now()
    switch (voice) {
      case 'kick':
        this.kick.triggerAttackRelease('C1', '8n', t, g)
        break
      case 'sub808':
        this.sub.triggerAttackRelease(midiToFreq(subMidi), '2n', t, g)
        break
      case 'snare':
        this.snareNoise.triggerAttackRelease('16n', t, g)
        this.snareBody.triggerAttackRelease(190, '32n', t, g * 0.8)
        break
      case 'clap':
        // tres micro-golpes: lo que hace que un clap suene a clap
        this.clap.triggerAttackRelease('32n', t, g * 0.55)
        this.clap.triggerAttackRelease('32n', t + 0.011, g * 0.75)
        this.clap.triggerAttackRelease('16n', t + 0.023, g)
        break
      case 'hatClosed':
        this.hat.envelope.decay = 0.035
        this.hat.triggerAttackRelease('64n', t, g)
        break
      case 'hatOpen':
        this.hat.envelope.decay = 0.3
        this.hat.triggerAttackRelease('16n', t, g * 0.9)
        break
    }
  }

  /** Golpe suelto disparado desde la UI (audiciona una fila del sequencer). */
  async previewHit(voice: DrumVoice, vel: Velocity, subMidi = 33) {
    await this.ensureStarted()
    this.hit(voice, vel, undefined, subMidi)
  }

  // ---------------------------------------------------------- secuencias

  /**
   * Step sequencer de batería. Lee el patrón con getters en cada step, así
   * puedes editar velocities en vivo sin parar el loop.
   */
  async startSequencer(opts: {
    owner: string
    getSteps: () => number
    getTracks: () => Record<DrumVoice, Velocity[]>
    get808Midi: () => number
    onStep: (step: number) => void
  }) {
    const voices: DrumVoice[] = ['kick', 'snare', 'clap', 'hatClosed', 'hatOpen', 'sub808']
    await this.startLoop(opts.owner, '16n', (time, tick) => {
      const total = opts.getSteps()
      const step = tick % total
      const tracks = opts.getTracks()
      const subMidi = opts.get808Midi()
      for (const v of voices) {
        const vel = tracks[v]?.[step] ?? 0
        if (vel > 0) this.hit(v, vel, time, subMidi)
      }
      Tone.getDraw().schedule(() => opts.onStep(step), time)
    })
  }

  /**
   * Loop de progresión: un acorde por compás.
   * `getChords` se lee en cada compás para que "jazzificar" aplique en vivo.
   */
  async startChordLoop(opts: {
    owner: string
    getChords: () => number[][]
    onBar: (index: number) => void
  }) {
    await this.startLoop(opts.owner, '1m', (time, tick) => {
      const chords = opts.getChords()
      if (chords.length === 0) return
      const idx = tick % chords.length
      const freqs = chords[idx].map(midiToFreq)
      this.poly.triggerAttackRelease(freqs, '1m', time, 0.75)
      Tone.getDraw().schedule(() => opts.onBar(idx), time)
    })
  }

  /** Alterna dos acordes (modo A/B) para comparar de oído. */
  async startABLoop(opts: {
    owner: string
    getPair: () => [number[], number[]]
    onSide: (side: 0 | 1) => void
  }) {
    await this.startLoop(opts.owner, '2n', (time, tick) => {
      const side = (tick % 2) as 0 | 1
      const chord = opts.getPair()[side]
      if (!chord.length) return
      this.poly.triggerAttackRelease(chord.map(midiToFreq), '2n', time, 0.8)
      Tone.getDraw().schedule(() => opts.onSide(side), time)
    })
  }
}

export const engine = new AudioEngine()
