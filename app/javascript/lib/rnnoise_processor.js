// LiveKit TrackProcessor wrapping RNNoise for AI-powered noise suppression.
// Plugs into LocalAudioTrack.setProcessor() — routes mic audio through
// a multi-stage audio pipeline and exposes the cleaned output as processedTrack.
//
// Pipeline: source → highpass → RNNoise → noise gate → destination
//
// Suppression levels:
//   "low"        — gentle HP (80Hz), open gate
//   "moderate"   — standard HP (120Hz) + balanced gate
//   "aggressive" — steep HP (200Hz) + tight gate

const PRESETS = {
  low: {
    highpassFreq: 80,
    highpassQ: 0.5,
    gateThresholdDb: -60,
    gateAttack: 0.01,
    gateRelease: 0.15,
    gateFloor: 0.1
  },
  moderate: {
    highpassFreq: 120,
    highpassQ: 0.707,
    gateThresholdDb: -45,
    gateAttack: 0.005,
    gateRelease: 0.2,
    gateFloor: 0.02
  },
  aggressive: {
    highpassFreq: 200,
    highpassQ: 1.0,
    gateThresholdDb: -38,
    gateAttack: 0.003,
    gateRelease: 0.25,
    gateFloor: 0.0
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

    // Stage 3: Noise gate — squelches residual noise during silence
    this._gateAnalyser = audioContext.createAnalyser()
    this._gateAnalyser.fftSize = 256
    this._gateAnalyser.smoothingTimeConstant = 0.5

    this._gateGain = audioContext.createGain()
    this._gateGain.gain.value = 1.0

    const thresholdLinear = Math.pow(10, preset.gateThresholdDb / 20)
    const floor = preset.gateFloor
    const attackTime = preset.gateAttack
    const releaseTime = preset.gateRelease
    let gateOpen = false

    const postData = new Float32Array(this._gateAnalyser.fftSize)
    this._gateInterval = setInterval(() => {
      this._gateAnalyser.getFloatTimeDomainData(postData)
      let sum = 0
      for (let i = 0; i < postData.length; i++) sum += postData[i] * postData[i]
      const rms = Math.sqrt(sum / postData.length)

      const now = audioContext.currentTime
      if (rms > thresholdLinear) {
        if (!gateOpen) {
          this._gateGain.gain.cancelScheduledValues(now)
          this._gateGain.gain.setTargetAtTime(1.0, now, attackTime)
          gateOpen = true
        }
      } else {
        if (gateOpen) {
          this._gateGain.gain.cancelScheduledValues(now)
          this._gateGain.gain.setTargetAtTime(floor, now, releaseTime)
          gateOpen = false
        }
      }
    }, 10)

    // Destination
    this._dest = audioContext.createMediaStreamDestination()

    // Wire up: source → highpass → rnnoise → analyser → gateGain → dest
    this._source.connect(this._highpass)
    this._highpass.connect(this._rnnoise)
    this._rnnoise.connect(this._gateAnalyser)
    this._gateAnalyser.connect(this._gateGain)
    this._gateGain.connect(this._dest)

    this.processedTrack = this._dest.stream.getAudioTracks()[0]

    console.log(`[RNNoise] Initialized: level=${this._level}, sampleRate=${audioContext.sampleRate}`)
  }

  async restart({ track, audioContext }) {
    await this.destroy()
    await this.init({ track, audioContext })
  }

  async destroy() {
    if (this._gateInterval) clearInterval(this._gateInterval)
    this._source?.disconnect()
    this._highpass?.disconnect()
    this._rnnoise?.disconnect()
    this._rnnoise?.destroy?.()
    this._gateAnalyser?.disconnect()
    this._gateGain?.disconnect()
    this.processedTrack = undefined
  }
}
