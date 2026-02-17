import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu"]

  toggle() {
    const isHidden = this.menuTarget.classList.contains("hidden")
    if (isHidden) {
      this.menuTarget.classList.remove("hidden")
      this.menuTarget.classList.add("dropdown-enter")
    } else {
      this.close()
    }
  }

  close() {
    this.menuTarget.classList.add("hidden")
    this.menuTarget.classList.remove("dropdown-enter")
  }

  closeOnClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.close()
    }
  }

  connect() {
    this.boundClose = this.closeOnClickOutside.bind(this)
    document.addEventListener("click", this.boundClose)
  }

  disconnect() {
    document.removeEventListener("click", this.boundClose)
  }
}
