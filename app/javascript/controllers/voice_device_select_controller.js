import { Controller } from "@hotwired/stimulus"

// Manages audio device enumeration, selection, mic testing,
// input sensitivity, and output volume on the Voice & Video settings page.
export default class extends Controller {
  static targets = [
    "inputDevice", "outputDevice", "micTestBtn", "micLevel",
    "outputVolume", "outputVolumeLabel",
    "sensitivityAuto", "sensitivitySliderWrap", "sensitivitySlider",
    "sensitivityMarker", "sensitivityLevel", "sensitivityModeLabel"
  ]

  connect() {
    this._stream = null
    this._analyser = null
    this._animFrame = null
    this._testing = false
    this._enumerateDevices()
    this._loadOutputVolume()
    this._loadSensitivity()
    navigator.mediaDevices?.addEventListener("devicechange", this._onDeviceChange)
  }

  disconnect() {
    this._stopMicTest()
    navigator.mediaDevices?.removeEventListener("devicechange", this._onDeviceChange)
  }

  // ── Device enumeration ──

  async _enumerateDevices() {
    try {
      // Need permission to see device labels
      const devices = await navigator.mediaDevices.enumerateDevices()
      const hasLabels = devices.some(d => d.label)
      if (!hasLabels) {
        // Request a quick stream to get labels, then stop it
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
        stream.getTracks().forEach(t => t.stop())
        return this._enumerateDevices()
      }
      this._populateDevices(devices)
    } catch (e) {
      console.warn("Could not enumerate devices:", e)
    }
  }

  _populateDevices(devices) {
    const savedInput = localStorage.getItem("voice-input-device") || "default"
    const savedOutput = localStorage.getItem("voice-output-device") || "default"

    if (this.hasInputDeviceTarget) {
      const select = this.inputDeviceTarget
      select.innerHTML = '<option value="default">Default</option>'
      devices.filter(d => d.kind === "audioinput" && d.deviceId !== "default").forEach(d => {
        const opt = document.createElement("option")
        opt.value = d.deviceId
        opt.textContent = d.label || `Microphone ${d.deviceId.slice(0, 8)}`
        if (d.deviceId === savedInput) opt.selected = true
        select.appendChild(opt)
      })
      select.addEventListener("change", () => {
        localStorage.setItem("voice-input-device", select.value)
        window.dispatchEvent(new CustomEvent("voice:input-device-changed", { detail: { deviceId: select.value } }))
        if (this._testing) { this._stopMicTest(); this._startMicTest() }
      })
    }

    if (this.hasOutputDeviceTarget) {
      const select = this.outputDeviceTarget
      select.innerHTML = '<option value="default">Default</option>'
      devices.filter(d => d.kind === "audiooutput" && d.deviceId !== "default").forEach(d => {
        const opt = document.createElement("option")
        opt.value = d.deviceId
        opt.textContent = d.label || `Speaker ${d.deviceId.slice(0, 8)}`
        if (d.deviceId === savedOutput) opt.selected = true
        select.appendChild(opt)
      })
      select.addEventListener("change", () => {
        localStorage.setItem("voice-output-device", select.value)
        window.dispatchEvent(new CustomEvent("voice:output-device-changed", { detail: { deviceId: select.value } }))
      })
    }
  }

  _onDeviceChange = () => { this._enumerateDevices() }

  // ── Mic test ──

  toggleMicTest() {
    if (this._testing) {
      this._stopMicTest()
    } else {
      this._startMicTest()
    }
  }

  async _startMicTest() {
    try {
      const deviceId = this.hasInputDeviceTarget ? this.inputDeviceTarget.value : "default"
      const constraints = { audio: deviceId === "default" ? true : { deviceId: { exact: deviceId } } }
      this._stream = await navigator.mediaDevices.getUserMedia(constraints)

      const ctx = new AudioContext()
      const source = ctx.createMediaStreamSource(this._stream)
      this._analyser = ctx.createAnalyser()
      this._analyser.fftSize = 256
      source.connect(this._analyser)
      this._audioCtx = ctx

      this._testing = true
      if (this.hasMicTestBtnTarget) {
        this.micTestBtnTarget.textContent = "Stop Test"
        this.micTestBtnTarget.classList.add("bg-danger/60")
        this.micTestBtnTarget.classList.remove("bg-gray-700")
      }
      this._drawLevel()
    } catch (e) {
      console.warn("Mic test failed:", e)
    }
  }

  _stopMicTest() {
    this._testing = false
    if (this._animFrame) cancelAnimationFrame(this._animFrame)
    if (this._stream) { this._stream.getTracks().forEach(t => t.stop()); this._stream = null }
    if (this._audioCtx) { this._audioCtx.close(); this._audioCtx = null }
    this._analyser = null

    if (this.hasMicTestBtnTarget) {
      this.micTestBtnTarget.textContent = "Test Mic"
      this.micTestBtnTarget.classList.remove("bg-danger/60")
      this.micTestBtnTarget.classList.add("bg-gray-700")
    }
    if (this.hasMicLevelTarget) this.micLevelTarget.style.width = "0%"
    if (this.hasSensitivityLevelTarget) this.sensitivityLevelTarget.style.width = "0%"
  }

  _drawLevel() {
    if (!this._testing || !this._analyser) return
    const data = new Uint8Array(this._analyser.frequencyBinCount)
    this._analyser.getByteFrequencyData(data)
    const avg = data.reduce((a, b) => a + b, 0) / data.length
    const pct = Math.min(100, (avg / 128) * 100)
    if (this.hasMicLevelTarget) this.micLevelTarget.style.width = `${pct}%`

    // Also drive the sensitivity level bar (maps dB-ish to the -100..0 range)
    if (this.hasSensitivityLevelTarget) {
      this.sensitivityLevelTarget.style.width = `${pct}%`
      // Color the bar: green if above threshold, gray if below
      const isAuto = this._sensitivityAuto
      if (!isAuto && this.hasSensitivitySliderTarget) {
        const threshold = parseInt(this.sensitivitySliderTarget.value, 10)
        const dbApprox = pct > 0 ? -100 + pct : -100
        if (dbApprox >= threshold) {
          this.sensitivityLevelTarget.classList.remove("bg-gray-500/40")
          this.sensitivityLevelTarget.classList.add("bg-green-500/40")
        } else {
          this.sensitivityLevelTarget.classList.remove("bg-green-500/40")
          this.sensitivityLevelTarget.classList.add("bg-gray-500/40")
        }
      } else {
        this.sensitivityLevelTarget.classList.remove("bg-gray-500/40")
        this.sensitivityLevelTarget.classList.add("bg-green-500/40")
      }
    }

    this._animFrame = requestAnimationFrame(() => this._drawLevel())
  }

  // ── Output volume ──

  _loadOutputVolume() {
    const saved = parseInt(localStorage.getItem("voice-output-volume") ?? "100", 10)
    if (this.hasOutputVolumeTarget) this.outputVolumeTarget.value = saved
    if (this.hasOutputVolumeLabelTarget) this.outputVolumeLabelTarget.textContent = `${saved}%`
  }

  updateOutputVolume() {
    const value = parseInt(this.outputVolumeTarget.value, 10)
    if (this.hasOutputVolumeLabelTarget) this.outputVolumeLabelTarget.textContent = `${value}%`
    localStorage.setItem("voice-output-volume", value)
    // Broadcast to voice channel controller so it applies immediately
    window.dispatchEvent(new CustomEvent("voice:output-volume-changed", { detail: { volume: value } }))
  }

  // ── Input sensitivity ──

  _loadSensitivity() {
    this._sensitivityAuto = localStorage.getItem("voice-sensitivity-auto") !== "false"
    const savedThreshold = parseInt(localStorage.getItem("voice-sensitivity-threshold") ?? "-50", 10)

    if (this.hasSensitivityAutoTarget) {
      this.sensitivityAutoTarget.checked = this._sensitivityAuto
    }
    if (this.hasSensitivitySliderTarget) {
      this.sensitivitySliderTarget.value = savedThreshold
    }
    if (this.hasSensitivityMarkerTarget) {
      this.sensitivityMarkerTarget.style.left = `${((savedThreshold + 100) / 100) * 100}%`
    }
    this._updateSensitivityUI()
  }

  toggleSensitivityMode() {
    this._sensitivityAuto = this.sensitivityAutoTarget.checked
    localStorage.setItem("voice-sensitivity-auto", this._sensitivityAuto)
    this._updateSensitivityUI()
    this._broadcastSensitivity()
  }

  updateSensitivity() {
    const value = parseInt(this.sensitivitySliderTarget.value, 10)
    if (this.hasSensitivityMarkerTarget) {
      this.sensitivityMarkerTarget.style.left = `${((value + 100) / 100) * 100}%`
    }
    localStorage.setItem("voice-sensitivity-threshold", value)
    this._broadcastSensitivity()
  }

  _updateSensitivityUI() {
    if (this.hasSensitivitySliderWrapTarget) {
      if (this._sensitivityAuto) {
        this.sensitivitySliderWrapTarget.classList.add("opacity-40", "pointer-events-none")
      } else {
        this.sensitivitySliderWrapTarget.classList.remove("opacity-40", "pointer-events-none")
      }
    }
    if (this.hasSensitivityModeLabelTarget) {
      this.sensitivityModeLabelTarget.textContent = this._sensitivityAuto ? "Automatic" : "Manual"
    }
  }

  _broadcastSensitivity() {
    const threshold = parseInt(localStorage.getItem("voice-sensitivity-threshold") ?? "-50", 10)
    window.dispatchEvent(new CustomEvent("voice:input-sensitivity-changed", {
      detail: { auto: this._sensitivityAuto, threshold }
    }))
  }
}
