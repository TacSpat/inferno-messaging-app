// LiveKit TrackProcessor wrapping RNNoise for AI-powered noise suppression.
// Plugs into LocalAudioTrack.setProcessor() — routes mic audio through
// an RNNoise AudioWorklet and exposes the cleaned output as processedTrack.
export class RnnoiseProcessor {
  name = 'rnnoise-noise-filter'
  processedTrack = undefined

  async init({ track, audioContext }) {
    await audioContext.audioWorklet.addModule('/audio/rnnoiseWorklet.js')

    const { RnnoiseWorkletNode, loadRnnoise } = await import('@sapphi-red/web-noise-suppressor')
    const wasmBinary = await loadRnnoise({
      url: '/audio/rnnoise.wasm',
      simdUrl: '/audio/rnnoise-simd.wasm'
    })

    this._source = audioContext.createMediaStreamSource(new MediaStream([track]))
    this._rnnoise = new RnnoiseWorkletNode(audioContext, { wasmBinary, maxChannels: 1 })
    this._dest = audioContext.createMediaStreamDestination()

    this._source.connect(this._rnnoise)
    this._rnnoise.connect(this._dest)

    this.processedTrack = this._dest.stream.getAudioTracks()[0]
  }

  async restart({ track, audioContext }) {
    await this.destroy()
    await this.init({ track, audioContext })
  }

  async destroy() {
    this._source?.disconnect()
    this._rnnoise?.disconnect()
    this._rnnoise?.destroy?.()
    this.processedTrack = undefined
  }
}
