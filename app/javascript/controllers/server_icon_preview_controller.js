import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["iconLabel", "iconPlaceholder", "iconPreview", "iconInput",
                     "bannerLabel", "bannerPlaceholder", "bannerPreview", "bannerInput"]

  previewIcon() {
    const file = this.iconInputTarget.files[0]
    if (!file) return
    const url = URL.createObjectURL(file)
    this.iconPreviewTarget.src = url
    this.iconPreviewTarget.classList.remove("hidden")
    this.iconPlaceholderTarget.classList.add("hidden")
    this.iconLabelTarget.classList.remove("border-dashed")
    this.iconLabelTarget.classList.add("border-solid", "border-accent/40")
  }

  previewBanner() {
    const file = this.bannerInputTarget.files[0]
    if (!file) return
    const url = URL.createObjectURL(file)
    this.bannerPreviewTarget.src = url
    this.bannerPreviewTarget.classList.remove("hidden")
    this.bannerPlaceholderTarget.classList.add("hidden")
    this.bannerLabelTarget.classList.remove("border-dashed")
    this.bannerLabelTarget.classList.add("border-solid", "border-accent/40")
  }
}
