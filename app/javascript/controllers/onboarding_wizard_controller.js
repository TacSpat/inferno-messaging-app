import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "step", "stepIndicator", "stepDot", "stepLabel",
    "rulesCheck", "rulesNext"
  ]

  connect() {
    this._currentStep = 0
  }

  next() {
    if (this._currentStep >= this.stepTargets.length - 1) return
    this._goTo(this._currentStep + 1)
  }

  prev() {
    if (this._currentStep <= 0) return
    this._goTo(this._currentStep - 1)
  }

  rulesToggled() {
    if (this.hasRulesNextTarget && this.hasRulesCheckTarget) {
      this.rulesNextTarget.disabled = !this.rulesCheckTarget.checked
    }
  }

  _goTo(step) {
    this.stepTargets[this._currentStep].classList.add("hidden")
    this.stepTargets[step].classList.remove("hidden")

    this.stepDotTargets.forEach((dot, i) => {
      dot.classList.toggle("bg-accent", i <= step)
      dot.classList.toggle("text-white", i <= step)
      dot.classList.toggle("bg-gray-700", i > step)
      dot.classList.toggle("text-gray-500", i > step)
    })
    this.stepLabelTargets.forEach((label, i) => {
      label.classList.toggle("text-white", i === step)
      label.classList.toggle("text-gray-500", i !== step)
    })

    this._currentStep = step
    window.scrollTo({ top: 0, behavior: "smooth" })
  }
}
