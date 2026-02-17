import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["video"]

  connect() {
    const video = this.videoTarget
    video.removeAttribute("controls")

    this._injectStyles()
    this._buildOverlay(video)
    this._restoreVolume(video)
    this._bindEvents(video)

    // Listen for volume changes from other players
    this._onVolumeSync = (e) => {
      if (e.detail.source === this) return
      video.volume = e.detail.volume
      video.muted = e.detail.muted
    }
    document.addEventListener("vp:volume", this._onVolumeSync)
  }

  disconnect() {
    if (this._hideTimer) clearTimeout(this._hideTimer)
    if (this._mouseMoveHandler) {
      this.element.removeEventListener("mousemove", this._mouseMoveHandler)
    }
    if (this._mouseLeaveHandler) {
      this.element.removeEventListener("mouseleave", this._mouseLeaveHandler)
    }
    if (this._onVolumeSync) {
      document.removeEventListener("vp:volume", this._onVolumeSync)
    }
  }

  // ---- Build UI ----

  _buildOverlay(video) {
    // Big centered play button overlay
    const bigPlay = document.createElement("div")
    bigPlay.className = "vp-big-play"
    bigPlay.innerHTML = `<svg class="w-16 h-16 text-white drop-shadow-lg" fill="currentColor" viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>`
    bigPlay.addEventListener("click", () => this._togglePlay(video))
    this.element.appendChild(bigPlay)
    this._bigPlay = bigPlay

    // Controls bar (hidden initially, slides in on hover)
    const bar = document.createElement("div")
    bar.className = "vp-controls vp-controls-hidden"

    // Play/Pause button
    const playBtn = document.createElement("button")
    playBtn.className = "vp-btn"
    playBtn.innerHTML = this._playIcon()
    playBtn.addEventListener("click", () => this._togglePlay(video))
    bar.appendChild(playBtn)
    this._playBtn = playBtn

    // Time display
    const time = document.createElement("span")
    time.className = "vp-time"
    time.textContent = "0:00 / 0:00"
    bar.appendChild(time)
    this._timeDisplay = time

    // Seek bar container
    const seekWrap = document.createElement("div")
    seekWrap.className = "vp-seek-wrap"

    const buffered = document.createElement("div")
    buffered.className = "vp-buffered"
    seekWrap.appendChild(buffered)
    this._bufferedBar = buffered

    const progress = document.createElement("div")
    progress.className = "vp-progress"
    seekWrap.appendChild(progress)
    this._progressBar = progress

    seekWrap.addEventListener("click", (e) => {
      const rect = seekWrap.getBoundingClientRect()
      const pct = (e.clientX - rect.left) / rect.width
      video.currentTime = pct * video.duration
    })
    bar.appendChild(seekWrap)

    // Volume wrapper (button + slider)
    const volWrap = document.createElement("div")
    volWrap.className = "vp-vol-wrap"

    const volBtn = document.createElement("button")
    volBtn.className = "vp-btn"
    volBtn.innerHTML = this._volumeIcon(1)
    volBtn.addEventListener("click", () => {
      video.muted = !video.muted
      this._saveVolume(video.volume, video.muted)
    })
    volWrap.appendChild(volBtn)
    this._volBtn = volBtn

    // Volume slider
    const volSlider = document.createElement("input")
    volSlider.type = "range"
    volSlider.min = "0"
    volSlider.max = "1"
    volSlider.step = "0.05"
    volSlider.value = "1"
    volSlider.className = "vp-volume-slider"
    volSlider.addEventListener("input", () => {
      const v = parseFloat(volSlider.value)
      video.volume = v
      video.muted = v === 0
      this._saveVolume(v, v === 0)
    })
    volWrap.appendChild(volSlider)
    this._volSlider = volSlider

    bar.appendChild(volWrap)

    // Fullscreen button
    const fsBtn = document.createElement("button")
    fsBtn.className = "vp-btn"
    fsBtn.innerHTML = this._fullscreenIcon()
    fsBtn.addEventListener("click", () => {
      if (document.fullscreenElement) {
        document.exitFullscreen()
      } else {
        this.element.requestFullscreen()
      }
    })
    bar.appendChild(fsBtn)

    this.element.appendChild(bar)
    this._controlsBar = bar
  }

  _bindEvents(video) {
    // Click video to toggle play
    video.addEventListener("click", () => this._togglePlay(video))

    // Update progress/time
    video.addEventListener("timeupdate", () => {
      if (!video.duration) return
      const pct = (video.currentTime / video.duration) * 100
      this._progressBar.style.width = `${pct}%`
      this._timeDisplay.textContent = `${this._fmt(video.currentTime)} / ${this._fmt(video.duration)}`
    })

    video.addEventListener("loadedmetadata", () => this._onMetadata(video))
    video.addEventListener("durationchange", () => this._onMetadata(video))
    // Metadata may already be loaded before controller connects
    if (video.readyState >= 1) this._onMetadata(video)

    video.addEventListener("progress", () => {
      if (video.buffered.length > 0) {
        const end = video.buffered.end(video.buffered.length - 1)
        this._bufferedBar.style.width = `${(end / video.duration) * 100}%`
      }
    })

    video.addEventListener("play", () => {
      this._playBtn.innerHTML = this._pauseIcon()
      this._bigPlay.classList.add("vp-hidden")
      this._pinned = false
      this._startAutoHide()
    })

    video.addEventListener("pause", () => {
      this._playBtn.innerHTML = this._playIcon()
      this._bigPlay.classList.remove("vp-hidden")
      // Keep controls visible if paused midway
      if (video.currentTime > 0 && video.currentTime < video.duration) {
        this._showControls()
        this._pinned = true
      }
    })

    video.addEventListener("ended", () => {
      this._playBtn.innerHTML = this._playIcon()
      this._bigPlay.classList.remove("vp-hidden")
      this._pinned = false
      this._hideControls()
    })

    video.addEventListener("volumechange", () => {
      const v = video.muted ? 0 : video.volume
      this._volBtn.innerHTML = this._volumeIcon(v)
      this._volSlider.value = v
    })

    // Auto-hide controls on mouse move/leave
    this._mouseMoveHandler = () => {
      this._showControls()
      if (!video.paused) this._startAutoHide()
    }
    this._mouseLeaveHandler = () => {
      if (!video.paused || !this._pinned) this._hideControls()
    }
    this.element.addEventListener("mousemove", this._mouseMoveHandler)
    this.element.addEventListener("mouseleave", this._mouseLeaveHandler)
  }

  // ---- Helpers ----

  _togglePlay(video) {
    if (video.paused) {
      video.play()
    } else {
      video.pause()
    }
  }

  _restoreVolume(video) {
    try {
      const saved = localStorage.getItem("videoVolume")
      const muted = localStorage.getItem("videoMuted") === "true"
      if (saved !== null) {
        const v = parseFloat(saved)
        video.volume = v
        video.muted = muted
        if (this._volSlider) this._volSlider.value = muted ? 0 : v
        if (this._volBtn) this._volBtn.innerHTML = this._volumeIcon(muted ? 0 : v)
      }
    } catch {}
  }

  _saveVolume(volume, muted) {
    try {
      localStorage.setItem("videoVolume", volume)
      localStorage.setItem("videoMuted", muted)
    } catch {}
    // Sync all other players on the page
    document.dispatchEvent(new CustomEvent("vp:volume", {
      detail: { volume, muted, source: this }
    }))
  }

  _showControls() {
    if (this._hideTimer) clearTimeout(this._hideTimer)
    this._controlsBar.classList.remove("vp-controls-hidden")
  }

  _hideControls() {
    this._controlsBar.classList.add("vp-controls-hidden")
  }

  _startAutoHide() {
    if (this._hideTimer) clearTimeout(this._hideTimer)
    this._hideTimer = setTimeout(() => this._hideControls(), 2000)
  }

  _onMetadata(video) {
    if (video.duration) {
      this._timeDisplay.textContent = `${this._fmt(video.currentTime)} / ${this._fmt(video.duration)}`
    }
    if (!this._layoutApplied) {
      this._layoutApplied = true
      this._applyLayout(video)
    }
  }

  _applyLayout(video) {
    if (video.videoHeight > video.videoWidth) {
      this._controlsBar.classList.add("vp-vertical")
      this._setupVerticalVolume()
    }
  }

  _setupVerticalVolume() {
    // Remove inline slider from the vol-wrap
    this._volSlider.remove()

    // Create a popup container appended to the controller element
    const popup = document.createElement("div")
    popup.className = "vp-vol-popup"
    popup.appendChild(this._volSlider)
    this._volSlider.className = "vp-vol-popup-slider"
    this.element.appendChild(popup)
    this._volPopup = popup

    // Position popup above the volume button
    const positionPopup = () => {
      const containerRect = this.element.getBoundingClientRect()
      const btnRect = this._volBtn.getBoundingClientRect()
      const btnCenterX = btnRect.left + btnRect.width / 2 - containerRect.left
      popup.style.left = `${btnCenterX - popup.offsetWidth / 2}px`
    }

    // Show/hide on hover with a delay so mouse can travel
    let hideTimeout
    const show = () => { clearTimeout(hideTimeout); positionPopup(); popup.classList.add("vp-vol-popup-visible") }
    const hide = () => { hideTimeout = setTimeout(() => popup.classList.remove("vp-vol-popup-visible"), 200) }

    this._volBtn.parentElement.addEventListener("mouseenter", show)
    this._volBtn.parentElement.addEventListener("mouseleave", hide)
    popup.addEventListener("mouseenter", show)
    popup.addEventListener("mouseleave", hide)
  }

  _fmt(s) {
    if (!s || isNaN(s)) return "0:00"
    const m = Math.floor(s / 60)
    const sec = Math.floor(s % 60)
    return `${m}:${sec < 10 ? "0" : ""}${sec}`
  }

  // ---- Icons ----

  _playIcon() {
    return `<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>`
  }

  _pauseIcon() {
    return `<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24"><path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/></svg>`
  }

  _volumeIcon(level) {
    if (level === 0) {
      return `<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24"><path d="M16.5 12c0-1.77-1.02-3.29-2.5-4.03v2.21l2.45 2.45c.03-.2.05-.41.05-.63zm2.5 0c0 .94-.2 1.82-.54 2.64l1.51 1.51A8.796 8.796 0 0021 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71zM4.27 3L3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06a8.99 8.99 0 003.69-1.81L19.73 21 21 19.73l-9-9L4.27 3zM12 4L9.91 6.09 12 8.18V4z"/></svg>`
    }
    if (level < 0.5) {
      return `<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24"><path d="M18.5 12c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM5 9v6h4l5 5V4L9 9H5z"/></svg>`
    }
    return `<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/></svg>`
  }

  _fullscreenIcon() {
    return `<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 8V4m0 0h4M4 4l5 5m11-1V4m0 0h-4m4 0l-5 5M4 16v4m0 0h4m-4 0l5-5m11 5v-4m0 4h-4m4 0l-5-5"/></svg>`
  }

  // ---- Inject Styles ----

  _injectStyles() {
    if (document.getElementById("video-player-style")) return
    const style = document.createElement("style")
    style.id = "video-player-style"
    style.textContent = `
      [data-controller="video-player"] {
        position: relative;
        cursor: pointer;
      }
      .vp-big-play {
        position: absolute;
        inset: 0;
        display: flex;
        align-items: center;
        justify-content: center;
        z-index: 2;
        pointer-events: none;
        transition: opacity 0.2s;
      }
      .vp-big-play.vp-hidden {
        opacity: 0;
        pointer-events: none;
      }
      .vp-controls {
        position: absolute;
        bottom: 0;
        left: 0;
        right: 0;
        display: flex;
        align-items: center;
        gap: 8px;
        padding: 8px 10px;
        background: linear-gradient(to top, rgba(0,0,0,0.8), transparent);
        z-index: 3;
        transform: translateY(0);
        opacity: 1;
        transition: transform 0.25s ease, opacity 0.25s ease;
      }
      .vp-controls.vp-controls-hidden {
        transform: translateY(100%);
        opacity: 0;
        pointer-events: none;
      }
      .vp-btn {
        background: none;
        border: none;
        color: #e5e7eb;
        cursor: pointer;
        padding: 2px;
        display: flex;
        align-items: center;
        justify-content: center;
        flex-shrink: 0;
        transition: color 0.15s;
      }
      .vp-btn:hover { color: #fff; }
      .vp-time {
        font-size: 12px;
        color: #878583;
        white-space: nowrap;
        flex-shrink: 0;
        user-select: none;
      }
      .vp-seek-wrap {
        flex: 1;
        height: 4px;
        background: rgba(255,255,255,0.2);
        border-radius: 2px;
        position: relative;
        cursor: pointer;
        min-width: 60px;
      }
      .vp-seek-wrap:hover {
        height: 6px;
      }
      .vp-buffered {
        position: absolute;
        top: 0;
        left: 0;
        height: 100%;
        background: rgba(255,255,255,0.25);
        border-radius: 2px;
        pointer-events: none;
        width: 0%;
      }
      .vp-progress {
        position: absolute;
        top: 0;
        left: 0;
        height: 100%;
        background: #3b82f6;
        border-radius: 2px;
        pointer-events: none;
        width: 0%;
      }
      .vp-vol-wrap {
        position: relative;
        display: flex;
        align-items: center;
        flex-shrink: 0;
      }
      .vp-volume-slider {
        width: 60px;
        height: 4px;
        -webkit-appearance: none;
        appearance: none;
        background: rgba(255,255,255,0.2);
        border-radius: 2px;
        outline: none;
        cursor: pointer;
        flex-shrink: 0;
      }
      .vp-volume-slider::-webkit-slider-thumb {
        -webkit-appearance: none;
        width: 12px;
        height: 12px;
        border-radius: 50%;
        background: #fff;
        cursor: pointer;
      }
      .vp-volume-slider::-moz-range-thumb {
        width: 12px;
        height: 12px;
        border-radius: 50%;
        background: #fff;
        cursor: pointer;
        border: none;
      }
      .vp-volume-slider::-webkit-slider-runnable-track {
        height: 4px;
        border-radius: 2px;
      }
      .vp-volume-slider::-moz-range-track {
        height: 4px;
        border-radius: 2px;
        background: rgba(255,255,255,0.2);
      }
      /* Vertical video layout */
      .vp-vertical {
        flex-wrap: wrap;
        gap: 4px 8px;
      }
      .vp-vertical .vp-seek-wrap {
        order: -1;
        width: 100%;
        flex: none;
        min-width: 0;
      }
      .vp-vertical .vp-time {
        flex: 1;
        font-size: 11px;
      }
      /* Vertical volume popup */
      .vp-vol-popup {
        position: absolute;
        bottom: 52px;
        background: rgba(0,0,0,0.85);
        border-radius: 6px;
        padding: 10px 6px;
        z-index: 4;
        opacity: 0;
        pointer-events: none;
        transition: opacity 0.2s;
      }
      .vp-vol-popup-visible {
        opacity: 1;
        pointer-events: auto;
      }
      .vp-vol-popup-slider {
        writing-mode: vertical-lr;
        direction: rtl;
        width: 4px;
        height: 80px;
        -webkit-appearance: none;
        appearance: none;
        background: rgba(255,255,255,0.2);
        border-radius: 2px;
        outline: none;
        cursor: pointer;
      }
      .vp-vol-popup-slider::-webkit-slider-thumb {
        -webkit-appearance: none;
        width: 14px;
        height: 14px;
        border-radius: 50%;
        background: #fff;
        cursor: pointer;
      }
      .vp-vol-popup-slider::-moz-range-thumb {
        width: 14px;
        height: 14px;
        border-radius: 50%;
        background: #fff;
        cursor: pointer;
        border: none;
      }
      /* Fullscreen: center and scale video */
      [data-controller="video-player"]:fullscreen {
        display: flex;
        align-items: center;
        justify-content: center;
        background: #000;
      }
      [data-controller="video-player"]:fullscreen video {
        max-width: 100% !important;
        max-height: 100vh !important;
        width: 100%;
        height: 100%;
        object-fit: contain;
      }
    `
    document.head.appendChild(style)
  }
}
