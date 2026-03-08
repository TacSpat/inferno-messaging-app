import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel", "toggleBtn"]

  connect() {
    const saved = localStorage.getItem("sidechat-visible")
    if (saved === "false") {
      this.hide()
    } else {
      this.show()
    }
  }

  toggle() {
    if (this.panelTarget.classList.contains("hidden")) {
      this.show()
    } else {
      this.hide()
    }
  }

  show() {
    this.panelTarget.classList.remove("hidden")
    this.panelTarget.classList.add("lg:flex")
    localStorage.setItem("sidechat-visible", "true")
    if (this.hasToggleBtnTarget) {
      this.toggleBtnTarget.classList.add("text-white")
      this.toggleBtnTarget.classList.remove("text-gray-400")
    }
  }

  hide() {
    this.panelTarget.classList.add("hidden")
    this.panelTarget.classList.remove("lg:flex")
    localStorage.setItem("sidechat-visible", "false")
    if (this.hasToggleBtnTarget) {
      this.toggleBtnTarget.classList.remove("text-white")
      this.toggleBtnTarget.classList.add("text-gray-400")
    }
  }
}
