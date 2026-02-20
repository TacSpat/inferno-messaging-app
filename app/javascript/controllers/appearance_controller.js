import { Controller } from "@hotwired/stimulus"
import consumer from "../lib/cable"

export default class extends Controller {
  connect() {
    this.idleTimeout = null
    this.pingInterval = null
    this.isIdle = false
    this.IDLE_MS = 15 * 60 * 1000 // 15 minutes
    this.PING_MS = 30 * 1000 // 30 seconds

    this.subscription = consumer.subscriptions.create(
      { channel: "AppearanceChannel" },
      {
        connected: () => {
          this.startIdleDetection()
          this.startPing()
          this.updateUserPanelDot("online")
        },
        disconnected: () => {
          this.stopIdleDetection()
          this.stopPing()
          this.updateUserPanelDot("offline")
        }
      }
    )
  }

  disconnect() {
    this.stopIdleDetection()
    this.stopPing()
    if (this.subscription) this.subscription.unsubscribe()
  }

  startPing() {
    this.stopPing()
    this.pingInterval = setInterval(() => {
      this.subscription.perform("ping", { state: this.isIdle ? "idle" : "online" })
    }, this.PING_MS)
  }

  stopPing() {
    if (this.pingInterval) {
      clearInterval(this.pingInterval)
      this.pingInterval = null
    }
  }

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
    clearTimeout(this.idleTimeout)
    if (this.isIdle) {
      this.isIdle = false
      this.subscription.perform("back")
      this.updateUserPanelDot("online")
    }
    this.idleTimeout = setTimeout(() => this.goIdle(), this.IDLE_MS)
  }

  goIdle() {
    if (!this.isIdle) {
      this.isIdle = true
      this.subscription.perform("away")
      this.updateUserPanelDot("idle")
    }
  }

  updateUserPanelDot(state) {
    // Update the status dot in the bottom user panel
    const colorMap = { online: "bg-green-500", idle: "bg-yellow-500", dnd: "bg-red-500", offline: "bg-gray-500" }
    const dots = document.querySelectorAll("[data-user-status-dot]")
    dots.forEach(dot => {
      dot.classList.remove("bg-green-500", "bg-yellow-500", "bg-red-500", "bg-gray-500")
      dot.classList.add(colorMap[state] || "bg-gray-500")
    })
  }
}
