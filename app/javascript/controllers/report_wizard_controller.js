import { Controller } from "@hotwired/stimulus"

const CATEGORY_LABELS = {
  csam: "Child exploitation material",
  threats: "Credible threats of violence",
  terrorism: "Terrorism-related content",
  other_illegal: "Other criminal activity"
}

export default class extends Controller {
  static targets = [
    "step", "stepIndicator", "stepDot", "stepLabel",
    "categoryNext", "categoryList", "categoryDisplay", "categoryField",
    "confirmCheck", "generateBtn"
  ]

  connect() {
    this._currentStep = 0
    this._selectedCategory = null
  }

  next() {
    if (this._currentStep >= this.stepTargets.length - 1) return
    this._goTo(this._currentStep + 1)
  }

  prev() {
    if (this._currentStep <= 0) return
    this._goTo(this._currentStep - 1)
  }

  categorySelected(e) {
    this._selectedCategory = e.target.value
    if (this.hasCategoryNextTarget) this.categoryNextTarget.disabled = false
  }

  confirmToggled() {
    if (this.hasGenerateBtnTarget && this.hasConfirmCheckTarget) {
      this.generateBtnTarget.disabled = !this.confirmCheckTarget.checked
    }
  }

  _goTo(step) {
    // Hide current
    this.stepTargets[this._currentStep].classList.add("hidden")
    // Show target
    this.stepTargets[step].classList.remove("hidden")

    // Update step indicators
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

    // On entering step 3 (confirm), sync the category
    if (step === 3 && this._selectedCategory) {
      if (this.hasCategoryDisplayTarget) {
        this.categoryDisplayTarget.textContent = CATEGORY_LABELS[this._selectedCategory] || this._selectedCategory
      }
      if (this.hasCategoryFieldTarget) {
        this.categoryFieldTarget.value = this._selectedCategory
      }
      // Reset confirm checkbox each time we enter
      if (this.hasConfirmCheckTarget) {
        this.confirmCheckTarget.checked = false
        this.confirmToggled()
      }
    }

    this._currentStep = step
    // Scroll to top of settings panel
    this.element.scrollIntoView({ behavior: "smooth", block: "start" })
  }
}
