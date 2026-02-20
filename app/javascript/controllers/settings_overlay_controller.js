import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["frame"]

  close() {
    this.element.classList.add("hidden")
    document.body.style.overflow = ""
    if (this.hasFrameTarget) this.frameTarget.innerHTML = ""
  }

  escClose(e) {
    if (e.key === "Escape" && !this.element.classList.contains("hidden") &&
        !e.target.closest("input, textarea, [contenteditable]")) {
      this.close()
    }
  }

  frameLoaded() {
    this.element.classList.remove("hidden")
  }
}
