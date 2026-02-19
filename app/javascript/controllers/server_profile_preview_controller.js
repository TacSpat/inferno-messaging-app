import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["nameInput", "namePreview", "iconInput", "iconPreview", "iconImage", "iconInitial",
                    "bannerInput", "bannerPreview", "bannerImage"]

  updateName() {
    const name = this.nameInputTarget.value.trim()
    this.namePreviewTarget.textContent = name || "Server"
    if (this.hasIconInitialTarget) {
      this.iconInitialTarget.textContent = (name || "S")[0].toUpperCase()
    }
  }

  previewIcon(e) {
    const file = e.target.files[0]
    if (!file) return
    const url = URL.createObjectURL(file)
    if (this.hasIconImageTarget) {
      this.iconImageTarget.src = url
    } else {
      const img = document.createElement("img")
      img.src = url
      img.className = "w-full h-full object-cover"
      img.dataset.serverProfilePreviewTarget = "iconImage"
      if (this.hasIconInitialTarget) this.iconInitialTarget.classList.add("hidden")
      this.iconPreviewTarget.appendChild(img)
    }
  }

  removeIcon() {
    if (this.hasIconImageTarget) this.iconImageTarget.remove()
    if (this.hasIconInitialTarget) this.iconInitialTarget.classList.remove("hidden")
    if (this.hasIconInputTarget) this.iconInputTarget.value = ""
  }

  previewBanner(e) {
    const file = e.target.files[0]
    if (!file) return
    const url = URL.createObjectURL(file)
    if (this.hasBannerImageTarget) {
      this.bannerImageTarget.src = url
    } else {
      const img = document.createElement("img")
      img.src = url
      img.className = "w-full h-full object-cover"
      img.dataset.serverProfilePreviewTarget = "bannerImage"
      this.bannerPreviewTarget.appendChild(img)
    }
  }

  removeBanner() {
    if (this.hasBannerImageTarget) this.bannerImageTarget.remove()
    if (this.hasBannerInputTarget) this.bannerInputTarget.value = ""
  }
}
