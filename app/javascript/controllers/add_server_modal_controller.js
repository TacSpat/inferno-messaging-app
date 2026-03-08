import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal"]

  open() {
    this.modalTarget.classList.remove("hidden")
  }

  close() {
    this.modalTarget.classList.add("hidden")
  }

  backdropClose(e) {
    if (e.target === this.modalTarget) {
      this.close()
    }
  }

  keydown(e) {
    if (e.key === "Escape") {
      if (this.modalTarget.classList.contains("hidden")) return
      this.close()
    }
  }
}
