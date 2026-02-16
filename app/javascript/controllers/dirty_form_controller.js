import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["saveBar"]

  connect() {
    this._snapshot = this._captureState()
    this._onChange = this._checkDirty.bind(this)
    this.element.addEventListener("input", this._onChange)
    this.element.addEventListener("change", this._onChange)
  }

  disconnect() {
    this.element.removeEventListener("input", this._onChange)
    this.element.removeEventListener("change", this._onChange)
  }

  reset() {
    const elements = this.element.elements
    for (let i = 0; i < elements.length; i++) {
      const el = elements[i]
      if (!el.name || !(el.name in this._snapshot)) continue
      if (el.type === "checkbox") {
        el.checked = this._snapshot[el.name]
      } else {
        el.value = this._snapshot[el.name]
      }
    }
    this._checkDirty()
  }

  _captureState() {
    const state = {}
    const elements = this.element.elements
    for (let i = 0; i < elements.length; i++) {
      const el = elements[i]
      if (!el.name) continue
      if (el.type === "checkbox") {
        state[el.name] = el.checked
      } else {
        state[el.name] = el.value
      }
    }
    return state
  }

  _checkDirty() {
    const current = this._captureState()
    let dirty = false
    for (const key in this._snapshot) {
      if (this._snapshot[key] !== current[key]) {
        dirty = true
        break
      }
    }
    if (this.hasSaveBarTarget) {
      if (dirty) {
        this.saveBarTarget.style.display = ""
        requestAnimationFrame(() => {
          this.saveBarTarget.style.opacity = "1"
          this.saveBarTarget.style.transform = "translateY(0)"
        })
      } else {
        this.saveBarTarget.style.opacity = "0"
        this.saveBarTarget.style.transform = "translateY(100%)"
        setTimeout(() => {
          if (!this._isDirty()) this.saveBarTarget.style.display = "none"
        }, 200)
      }
    }
  }

  _isDirty() {
    const current = this._captureState()
    for (const key in this._snapshot) {
      if (this._snapshot[key] !== current[key]) return true
    }
    return false
  }
}
