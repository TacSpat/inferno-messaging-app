import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { current: String }

  connect() {
    if (this.currentValue) {
      document.documentElement.dataset.theme = this.currentValue
      localStorage.setItem("theme", this.currentValue)
    }
  }

  preview(e) {
    const theme = e.target.value
    const apply = () => { document.documentElement.dataset.theme = theme }

    if (document.startViewTransition) {
      document.startViewTransition(apply)
    } else {
      apply()
    }
  }

  disconnect() {
    document.documentElement.dataset.theme = this.currentValue
  }
}
