import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["arrow", "channels"]
  static values = { id: String }

  connect() {
    const collapsed = this.getCollapsed()
    if (collapsed.includes(this.idValue)) {
      // Initial load — no animation
      this.channelsTarget.style.height = "0px"
      this.channelsTarget.style.overflow = "hidden"
      this.channelsTarget.style.opacity = "0"
      this.arrowTarget.classList.add("-rotate-90")
      this._collapsed = true
    } else {
      this._collapsed = false
    }
  }

  toggle() {
    if (this._collapsed) {
      this.expand()
      this.removeFromStorage()
    } else {
      this.collapse()
      this.addToStorage()
    }
  }

  collapse() {
    this._collapsed = true
    const el = this.channelsTarget
    const height = el.scrollHeight

    // Set explicit height so transition works
    el.style.height = `${height}px`
    el.style.overflow = "hidden"
    el.offsetHeight // force reflow

    el.style.transition = "height 200ms ease, opacity 150ms ease"
    el.style.height = "0px"
    el.style.opacity = "0"

    this.arrowTarget.classList.add("-rotate-90")

    el.addEventListener("transitionend", () => {
      el.style.transition = ""
    }, { once: true })
  }

  expand() {
    this._collapsed = false
    const el = this.channelsTarget
    el.style.overflow = "hidden"
    el.style.display = ""

    // Measure target height
    const targetHeight = el.scrollHeight

    el.style.transition = "height 200ms ease, opacity 150ms ease"
    el.style.height = `${targetHeight}px`
    el.style.opacity = "1"

    this.arrowTarget.classList.remove("-rotate-90")

    el.addEventListener("transitionend", () => {
      // Clear inline styles so content can reflow naturally
      el.style.height = ""
      el.style.overflow = ""
      el.style.transition = ""
    }, { once: true })
  }

  getCollapsed() {
    try {
      return JSON.parse(localStorage.getItem("collapsed_categories") || "[]")
    } catch {
      return []
    }
  }

  addToStorage() {
    const collapsed = this.getCollapsed()
    if (!collapsed.includes(this.idValue)) {
      collapsed.push(this.idValue)
      localStorage.setItem("collapsed_categories", JSON.stringify(collapsed))
    }
  }

  removeFromStorage() {
    const collapsed = this.getCollapsed().filter(id => id !== this.idValue)
    localStorage.setItem("collapsed_categories", JSON.stringify(collapsed))
  }
}
