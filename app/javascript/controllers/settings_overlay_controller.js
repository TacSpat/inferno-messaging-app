import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["frame"]

  close() {
    this.element.classList.add("hidden")
    this.element.style.backgroundColor = ""
    this.element.style.backdropFilter = ""
    document.body.style.overflow = ""
    if (this.hasFrameTarget) this.frameTarget.innerHTML = ""
    document.dispatchEvent(new CustomEvent("settings-overlay:closed"))
  }

  escClose(e) {
    if (e.key === "Escape" && !this.element.classList.contains("hidden") &&
        !e.target.closest("input, textarea, [contenteditable]")) {
      this.close()
    }
  }

  frameLoaded() {
    this.element.classList.remove("hidden")
    if (this.element.querySelector("[data-controller~='theme-picker']")) return
    this.element.style.backgroundColor = "var(--settings-overlay-bg)"
    this.element.style.backdropFilter = "blur(6px)"
  }
}
