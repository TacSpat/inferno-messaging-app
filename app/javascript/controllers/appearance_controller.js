import { Controller } from "@hotwired/stimulus"
import consumer from "../lib/cable"

const MANUAL_KEY = "inferno_manual_status"
const MANUAL_STATES = ["dnd", "invisible"]

export default class extends Controller {
  connect() {
    this.idleTimeout = null
    this.pingInterval = null
    this.isIdle = false
    this.IDLE_MS = 15 * 60 * 1000 // 15 minutes
    this.PING_MS = 30 * 1000 // 30 seconds
    this.manualStatus = localStorage.getItem(MANUAL_KEY) || null
    this.pickerOpen = false

    this.subscription = consumer.subscriptions.create(
      { channel: "AppearanceChannel", manual_status: this.manualStatus || undefined },
      {
        connected: () => {
          this.updateUserPanelDot(this.manualStatus || "online")

          if (this._isManualLock()) {
            this.stopIdleDetection()
          } else {
            this.startIdleDetection()
          }
          this.startPing()
        },
        disconnected: () => {
          this.stopIdleDetection()
          this.stopPing()
          if (!this._isManualLock()) {
            this.updateUserPanelDot("offline")
          }
        }
      }
    )

    // Close picker on outside click or Escape
    this._boundCloseOnClick = (e) => {
      if (this.pickerOpen && !e.target.closest("[data-status-picker]") && !e.target.closest("[data-user-status-dot]")) {
        this.closeStatusPicker()
      }
    }
    this._boundCloseOnKey = (e) => {
      if (e.key === "Escape" && this.pickerOpen) this.closeStatusPicker()
    }
    document.addEventListener("click", this._boundCloseOnClick)
    document.addEventListener("keydown", this._boundCloseOnKey)
  }

  disconnect() {
    this.stopIdleDetection()
    this.stopPing()
    if (this.subscription) this.subscription.unsubscribe()
    document.removeEventListener("click", this._boundCloseOnClick)
    document.removeEventListener("keydown", this._boundCloseOnKey)
  }

  // --- Status picker actions ---

  toggleStatusPicker(event) {
    event.stopPropagation()
    const dot = event.currentTarget
    const picker = dot.closest(".relative")?.querySelector("[data-status-picker]")
    if (!picker) return

    if (this.pickerOpen) {
      this.closeStatusPicker()
    } else {
      // Close any other open pickers first
      document.querySelectorAll("[data-status-picker]").forEach(p => p.classList.add("hidden"))
      picker.classList.remove("hidden")
      this.pickerOpen = true
    }
  }

  closeStatusPicker() {
    document.querySelectorAll("[data-status-picker]").forEach(p => p.classList.add("hidden"))
    this.pickerOpen = false
  }

  pickStatus(event) {
    const status = event.currentTarget.dataset.status
    if (!status) return
    this.setStatus(status)
    this.closeStatusPicker()
  }

  setStatus(status) {
    if (status === "online") {
      // Clear manual override, resume auto behavior
      this.manualStatus = null
      localStorage.removeItem(MANUAL_KEY)
      this.isIdle = false
      this.startIdleDetection()
    } else {
      this.manualStatus = status
      localStorage.setItem(MANUAL_KEY, status)
      if (this._isManualLock()) {
        this.stopIdleDetection()
      } else {
        // "idle" manual pick — still allow auto transitions
        this.startIdleDetection()
      }
    }

    if (this.subscription) {
      this.subscription.perform("set_status", { status })
    }
    this.updateUserPanelDot(status)
  }

  // --- Ping ---

  startPing() {
    this.stopPing()
    this.pingInterval = setInterval(() => {
      const state = this._isManualLock() ? this.manualStatus : (this.isIdle ? "idle" : "online")
      this.subscription.perform("ping", { state })
    }, this.PING_MS)
  }

  stopPing() {
    if (this.pingInterval) {
      clearInterval(this.pingInterval)
      this.pingInterval = null
    }
  }

  // --- Idle detection ---

  startIdleDetection() {
    this.resetIdle()
    this.boundReset = this.resetIdle.bind(this)
    document.addEventListener("mousemove", this.boundReset)
    document.addEventListener("keydown", this.boundReset)
    document.addEventListener("click", this.boundReset)
    this.boundVisibility = () => {
      if (document.hidden) this.goIdle()
      else this.resetIdle()
    }
    document.addEventListener("visibilitychange", this.boundVisibility)
  }

  stopIdleDetection() {
    clearTimeout(this.idleTimeout)
    if (this.boundReset) {
      document.removeEventListener("mousemove", this.boundReset)
      document.removeEventListener("keydown", this.boundReset)
      document.removeEventListener("click", this.boundReset)
    }
    if (this.boundVisibility) {
      document.removeEventListener("visibilitychange", this.boundVisibility)
    }
  }

  resetIdle() {
    if (this._isManualLock()) return

    clearTimeout(this.idleTimeout)
    if (this.isIdle) {
      this.isIdle = false
      this.subscription.perform("back")
      this.updateUserPanelDot(this.manualStatus || "online")
    }
    this.idleTimeout = setTimeout(() => this.goIdle(), this.IDLE_MS)
  }

  goIdle() {
    if (this._isManualLock()) return

    if (!this.isIdle) {
      this.isIdle = true
      this.subscription.perform("away")
      this.updateUserPanelDot("idle")
    }
  }

  // --- UI ---

  updateUserPanelDot(state) {
    const colorMap = {
      online: "bg-green-500",
      idle: "bg-yellow-500",
      dnd: "bg-red-500",
      invisible: "bg-gray-500",
      offline: "bg-gray-500"
    }
    const dots = document.querySelectorAll("[data-user-status-dot]")
    dots.forEach(dot => {
      dot.classList.remove("bg-green-500", "bg-yellow-500", "bg-red-500", "bg-gray-500")
      dot.classList.add(colorMap[state] || "bg-gray-500")
    })
  }

  // --- Helpers ---

  _isManualLock() {
    return MANUAL_STATES.includes(this.manualStatus)
  }
}
