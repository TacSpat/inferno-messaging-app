import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this._overlay = null
    this._pingInterval = null
    this._wasOffline = false

    this._onOffline = () => this._showOverlay()
    this._onOnline = () => this._startPinging()

    window.addEventListener("offline", this._onOffline)
    window.addEventListener("online", this._onOnline)

    // Also detect fetch failures — catches server-down without full browser "offline"
    this._originalFetch = null
    this._failCount = 0
    this._monitorActionCable()
  }

  disconnect() {
    window.removeEventListener("offline", this._onOffline)
    window.removeEventListener("online", this._onOnline)
    this._stopPinging()
    this._removeOverlay()
    if (this._cableCheck) clearInterval(this._cableCheck)
  }

  _monitorActionCable() {
    // Poll ActionCable connection state as a secondary signal
    this._cableCheck = setInterval(() => {
      try {
        const consumer = document.querySelector("meta[name='action-cable-url']")
        if (!consumer) return
        // Check if we already know we're offline
        if (this._overlay) return
        // Use navigator as a cheap check
        if (!navigator.onLine) this._showOverlay()
      } catch {}
    }, 10000)
  }

  _showOverlay() {
    if (this._overlay) return
    this._wasOffline = true

    const overlay = document.createElement("div")
    overlay.id = "connection-lost-overlay"
    overlay.style.cssText = `
      position: fixed; inset: 0; z-index: 9999;
      display: flex; align-items: center; justify-content: center;
      background: rgba(10, 10, 9, 0.85);
      transition: opacity 0.3s ease;
    `
    overlay.innerHTML = `
      <div style="
        width: 400px; height: 300px;
        display: flex; flex-direction: column; align-items: center; justify-content: center;
        background: #0a0a09;
        border-radius: 12px;
        position: relative;
        overflow: hidden;
      ">
        <div style="position:absolute;inset:0;background:radial-gradient(ellipse at 50% 80%, rgba(220,38,38,0.12) 0%, transparent 60%);pointer-events:none;"></div>
        <div style="
          font-size: 48px; font-weight: 700; margin-bottom: 16px;
          background: linear-gradient(135deg, #dc2626, #f87171);
          -webkit-background-clip: text; -webkit-text-fill-color: transparent;
          letter-spacing: 2px; position: relative;
        ">INFERNO</div>
        <div id="conn-spinner" style="
          width: 32px; height: 32px; margin: 0 auto 16px;
          border: 3px solid rgba(225, 224, 223, 0.08);
          border-top-color: #dc2626; border-radius: 50%;
          animation: conn-spin 0.8s linear infinite;
        "></div>
        <div id="conn-status" style="font-size: 14px; color: #a8a7a5; margin-bottom: 8px; position: relative;">
          Connection lost
        </div>
        <div style="font-size: 12px; color: #656361; position: relative;">
          Waiting to reconnect...
        </div>
      </div>
      <style>
        @keyframes conn-spin { to { transform: rotate(360deg); } }
      </style>
    `

    document.body.appendChild(overlay)
    this._overlay = overlay
    this._startPinging()
  }

  _startPinging() {
    this._stopPinging()
    // Ping immediately, then every 3 seconds
    this._ping()
    this._pingInterval = setInterval(() => this._ping(), 3000)
  }

  _stopPinging() {
    if (this._pingInterval) {
      clearInterval(this._pingInterval)
      this._pingInterval = null
    }
  }

  async _ping() {
    try {
      const resp = await fetch("/up", {
        method: "GET",
        cache: "no-store",
        signal: AbortSignal.timeout(5000)
      })
      if (resp.ok) {
        this._onReconnected()
      }
    } catch {
      // Still offline — update status text
      if (this._overlay) {
        const status = this._overlay.querySelector("#conn-status")
        if (status) status.textContent = "Reconnecting..."
      }
      // Make sure overlay is showing
      if (!this._overlay) this._showOverlay()
    }
  }

  _onReconnected() {
    this._stopPinging()

    if (this._overlay) {
      const status = this._overlay.querySelector("#conn-status")
      if (status) {
        status.textContent = "Connected!"
        status.style.color = "#4ade80"
      }
      const sub = this._overlay.querySelector("div > div:last-child")
      if (sub) sub.textContent = ""

      // Fade out and reload to restore ActionCable + Turbo state
      setTimeout(() => {
        if (this._overlay) {
          this._overlay.style.opacity = "0"
          setTimeout(() => {
            this._removeOverlay()
            // Reload to fully restore subscriptions and page state
            window.location.reload()
          }, 300)
        }
      }, 600)
    }

    this._wasOffline = false
  }

  _removeOverlay() {
    if (this._overlay) {
      this._overlay.remove()
      this._overlay = null
    }
  }
}
