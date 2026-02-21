import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  async copy(event) {
    const value = event.currentTarget.dataset.clipboardValue
    if (!value) return

    await navigator.clipboard.writeText(value)
    const btn = event.currentTarget
    const original = btn.textContent
    btn.textContent = "Copied!"
    setTimeout(() => { btn.textContent = original }, 2000)
  }
}
