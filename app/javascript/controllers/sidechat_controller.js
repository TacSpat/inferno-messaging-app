import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel", "toggleBtn"]

  connect() {
    this._animating = false
    const saved = localStorage.getItem("sidechat-visible")
    if (saved === "false") {
      this.hide(false)
    } else {
      this.show(false)
    }
  }

  toggle() {
    if (this._animating) return
    if (this.hasPanelTarget && this._isHidden()) {
      this.show(true)
    } else {
      this.hide(true)
    }
  }

  _isHidden() {
    return this.panelTarget.dataset.panelHidden === "true"
  }

  show(animate = true) {
    if (!this.hasPanelTarget) return
    const el = this.panelTarget

    localStorage.setItem("sidechat-visible", "true")
    if (this.hasToggleBtnTarget) {
      this.toggleBtnTarget.classList.add("text-white")
      this.toggleBtnTarget.classList.remove("text-gray-400")
    }

    el.dataset.panelHidden = "false"
    el.classList.remove("hidden")
    el.classList.add("flex")

    // Shrink voice cards
    const voiceContent = this.element.querySelector("[data-voice-content]")
    if (voiceContent) voiceContent.classList.add("voice-compact")

    if (!animate) return

    this._animating = true
    el.style.overflow = "hidden"
    el.style.minWidth = "0px"
    el.style.maxWidth = "0px"
    el.style.opacity = "0"
    el.style.borderLeftWidth = "0px"
    el.offsetHeight
    el.style.transition = "min-width 200ms ease, max-width 200ms ease, opacity 150ms ease, border-left-width 200ms ease"
    el.style.minWidth = "350px"
    el.style.maxWidth = "350px"
    el.style.opacity = "1"
    el.style.borderLeftWidth = ""
    const cleanup = (e) => {
      if (e.propertyName !== "max-width") return
      el.removeEventListener("transitionend", cleanup)
      el.style.transition = ""
      el.style.overflow = ""
      el.style.minWidth = ""
      el.style.maxWidth = ""
      this._animating = false
    }
    el.addEventListener("transitionend", cleanup)
  }

  hide(animate = true) {
    if (!this.hasPanelTarget) return
    const el = this.panelTarget

    localStorage.setItem("sidechat-visible", "false")
    if (this.hasToggleBtnTarget) {
      this.toggleBtnTarget.classList.remove("text-white")
      this.toggleBtnTarget.classList.add("text-gray-400")
    }

    el.dataset.panelHidden = "true"

    // Grow voice cards back
    const voiceContent = this.element.querySelector("[data-voice-content]")
    if (voiceContent) voiceContent.classList.remove("voice-compact")

    if (!animate) {
      el.classList.add("hidden")
      el.classList.remove("flex")
      return
    }

    this._animating = true
    el.style.overflow = "hidden"
    const w = el.offsetWidth
    el.style.minWidth = w + "px"
    el.style.maxWidth = w + "px"
    el.offsetHeight
    el.style.transition = "min-width 200ms ease, max-width 200ms ease, opacity 150ms ease, border-left-width 200ms ease"
    el.style.minWidth = "0px"
    el.style.maxWidth = "0px"
    el.style.opacity = "0"
    el.style.borderLeftWidth = "0px"
    const cleanup = (e) => {
      if (e.propertyName !== "max-width") return
      el.removeEventListener("transitionend", cleanup)
      el.classList.add("hidden")
      el.classList.remove("flex")
      el.style.transition = ""
      el.style.overflow = ""
      el.style.minWidth = ""
      el.style.maxWidth = ""
      el.style.opacity = ""
      el.style.borderLeftWidth = ""
      this._animating = false
    }
    el.addEventListener("transitionend", cleanup)
  }
}
