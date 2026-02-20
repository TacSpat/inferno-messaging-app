import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "pttSection", "keyDisplay", "pttKeyField", "pttKeyCodeField",
    "micLevelBar", "micLevelFill", "thresholdMarker", "sensitivitySlider"
  ]

  connect() {
    this._startMicPreview()
  }

  disconnect() {
    this._stopMicPreview()
    if (this._captureHandler) {
      document.removeEventListener("keydown", this._captureHandler, true)
      this._captureHandler = null
    }
  }

  // ── Input mode radio changed ──

  inputModeChanged(e) {
    if (this.hasPttSectionTarget) {
      this.pttSectionTarget.classList.toggle("hidden", e.target.value !== "push_to_talk")
    }
  }

  // ── PTT keybind capture ──

  captureKey(e) {
    e.preventDefault()
    if (!this.hasKeyDisplayTarget) return

    this.keyDisplayTarget.textContent = "Press any key..."
    this.keyDisplayTarget.classList.add("border-accent", "animate-pulse")

    // Remove previous listener if still active
    if (this._captureHandler) {
      document.removeEventListener("keydown", this._captureHandler, true)
    }

    this._captureHandler = (ev) => {
      ev.preventDefault()
      ev.stopPropagation()
      document.removeEventListener("keydown", this._captureHandler, true)
      this._captureHandler = null

      const label = ev.key === " " ? "Space" : ev.key.length === 1 ? ev.key.toUpperCase() : ev.key
      this.keyDisplayTarget.textContent = label
      this.keyDisplayTarget.classList.remove("border-accent", "animate-pulse")

      if (this.hasPttKeyFieldTarget) this.pttKeyFieldTarget.value = label
      if (this.hasPttKeyCodeFieldTarget) this.pttKeyCodeFieldTarget.value = ev.code
    }

    document.addEventListener("keydown", this._captureHandler, true)
  }

  // ── Sensitivity slider → threshold marker ──

  sensitivityChanged() {
    if (!this.hasSensitivitySliderTarget || !this.hasThresholdMarkerTarget) return
    const val = parseFloat(this.sensitivitySliderTarget.value)
    const pct = (val / 0.1) * 100
    this.thresholdMarkerTarget.style.left = `${pct}%`
  }

  // ── Live mic preview ──

  async _startMicPreview() {
    if (!this.hasMicLevelFillTarget) return

    try {
      this._micStream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch {
      return // mic unavailable, no preview
    }

    this._audioCtx = new (window.AudioContext || window.webkitAudioContext)()
    if (this._audioCtx.state === "suspended") this._audioCtx.resume()
    const source = this._audioCtx.createMediaStreamSource(this._micStream)
    this._analyser = this._audioCtx.createAnalyser()
    this._analyser.fftSize = 256
    this._analyser.smoothingTimeConstant = 0.4
    source.connect(this._analyser)
    this._analyserBuf = new Float32Array(this._analyser.fftSize)

    const tick = () => {
      if (!this._analyser) return
      this._analyser.getFloatTimeDomainData(this._analyserBuf)
      let sum = 0
      for (let i = 0; i < this._analyserBuf.length; i++) {
        sum += this._analyserBuf[i] * this._analyserBuf[i]
      }
      const rms = Math.min(Math.sqrt(sum / this._analyserBuf.length) * 4, 1)
      const pct = (rms / 0.1) * 100 // same scale as sensitivity 0–0.1
      if (this.hasMicLevelFillTarget) {
        this.micLevelFillTarget.style.width = `${Math.min(pct, 100)}%`
      }
      this._micRAF = requestAnimationFrame(tick)
    }
    this._micRAF = requestAnimationFrame(tick)
  }

  _stopMicPreview() {
    if (this._micRAF) {
      cancelAnimationFrame(this._micRAF)
      this._micRAF = null
    }
    if (this._audioCtx) {
      try { this._audioCtx.close() } catch {}
      this._audioCtx = null
      this._analyser = null
      this._analyserBuf = null
    }
    if (this._micStream) {
      this._micStream.getTracks().forEach(t => t.stop())
      this._micStream = null
    }
  }
}
