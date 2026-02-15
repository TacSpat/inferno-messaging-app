import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["arrow", "channels"]
  static values = { id: String }

  connect() {
    const collapsed = this.getCollapsed()
    if (collapsed.includes(this.idValue)) {
      this.collapse()
    }
  }

  toggle() {
    const isCollapsed = this.channelsTarget.classList.contains("hidden")
    if (isCollapsed) {
      this.expand()
      this.removeFromStorage()
    } else {
      this.collapse()
      this.addToStorage()
    }
  }

  collapse() {
    this.channelsTarget.classList.add("hidden")
    this.arrowTarget.classList.add("-rotate-90")
  }

  expand() {
    this.channelsTarget.classList.remove("hidden")
    this.arrowTarget.classList.remove("-rotate-90")
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
