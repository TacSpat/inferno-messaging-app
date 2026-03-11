// LiveKit TrackProcessor wrapping RNNoise for AI-powered noise suppression.
// Plugs into LocalAudioTrack.setProcessor() — routes mic audio through
// a multi-stage audio pipeline and exposes the cleaned output as processedTrack.
//
// Pipeline: source → highpass → RNNoise → gate (expander) → destination
//
// The high-pass filter removes low-frequency rumble (AC hum, fans, traffic)
// before RNNoise processes the signal. The noise gate after RNNoise squelches
// residual artifacts during silence.
//
// Suppression levels:
//   "low"        — gentle HP (80Hz), no gate, minimal processing
//   "moderate"   — standard HP (120Hz) + mild gate
//   "aggressive" — steep HP (200Hz) + tight gate, cuts most background noise

const PRESETS = {
  low: {
    highpassFreq: 80,
    highpassQ: 0.5,
    gateThreshold: -80,   // effectively off
    gateRatio: 1,
    gateAttack: 0.01,
    gateRelease: 0.1
  },
  moderate: {
    highpassFreq: 120,
    highpassQ: 0.707,
    gateThreshold: -50,
    gateRatio: 4,
    gateAttack: 0.005,
    gateRelease: 0.15
  },
  aggressive: {
    highpassFreq: 200,
    highpassQ: 1.0,
    gateThreshold: -40,
    gateRatio: 12,
    gateAttack: 0.003,
    gateRelease: 0.2
  }
}

export class RnnoiseProcessor {
  name = 'rnnoise-noise-filter'
  processedTrack = undefined

  constructor(level = 'moderate') {
    this._level = PRESETS[level] ? level : 'moderate'
  }

  async init({ track, audioContext }) {
    await audioContext.audioWorklet.addModule('/audio/rnnoiseWorklet.js')

    const { RnnoiseWorkletNode, loadRnnoise } = await import('@sapphi-red/web-noise-suppressor')
    const wasmBinary = await loadRnnoise({
      url: '/audio/rnnoise.wasm',
      simdUrl: '/audio/rnnoise-simd.wasm'
    })

    const preset = PRESETS[this._level]

    // Source
    this._source = audioContext.createMediaStreamSource(new MediaStream([track]))

    // Stage 1: High-pass filter — cuts low-frequency rumble
    this._highpass = audioContext.createBiquadFilter()
    this._highpass.type = 'highpass'
    this._highpass.frequency.value = preset.highpassFreq
    this._highpass.Q.value = preset.highpassQ

    // Stage 2: RNNoise ML denoiser
    this._rnnoise = new RnnoiseWorkletNode(audioContext, { wasmBinary, maxChannels: 1 })

    // Stage 3: Noise gate (using DynamicsCompressor as expander)
    // A compressor with high threshold acts as a noise gate — signals below
    // the threshold get pushed down by the ratio, silencing residual noise.
    this._gate = audioContext.createDynamicsCompressor()
    this._gate.threshold.value = preset.gateThreshold
    this._gate.ratio.value = preset.gateRatio
    this._gate.attack.value = preset.gateAttack
    this._gate.release.value = preset.gateRelease
    this._gate.knee.value = 6

    // Destination
    this._dest = audioContext.createMediaStreamDestination()

    // Wire up: source → highpass → rnnoise → gate → dest
    this._source.connect(this._highpass)
    this._highpass.connect(this._rnnoise)
    this._rnnoise.connect(this._gate)
    this._gate.connect(this._dest)

    this.processedTrack = this._dest.stream.getAudioTracks()[0]
  }

  async restart({ track, audioContext }) {
    await this.destroy()
    await this.init({ track, audioContext })
  }

  async destroy() {
    this._source?.disconnect()
    this._highpass?.disconnect()
    this._rnnoise?.disconnect()
    this._rnnoise?.destroy?.()
    this._gate?.disconnect()
    this.processedTrack = undefined
  }
}
