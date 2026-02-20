import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["sidebar", "backdrop"]

  connect() {
    const overlay = document.getElementById("settings-overlay")
    this._isOverlay = !!(overlay && overlay.contains(this.element))

    if (!this._isOverlay) {
      // Full-page mode: remember where to go back
      if (!sessionStorage.getItem("settings_return_url")) {
        const ref = document.referrer
        sessionStorage.setItem(
          "settings_return_url",
          ref && ref.startsWith(window.location.origin) ? ref : "/"
        )
      }
    }

    this._onKeydown = (e) => {
      if (e.key === "Escape" && !e.target.closest("input, textarea, [contenteditable]")) {
        this.exitSettings()
      }
    }
    // Only bind escape in full-page mode; overlay controller handles it in overlay mode
    if (!this._isOverlay) {
      document.addEventListener("keydown", this._onKeydown)
    }
  }

  disconnect() {
    if (!this._isOverlay) {
      document.removeEventListener("keydown", this._onKeydown)
    }
  }

  exitSettings() {
    if (this._isOverlay) {
      const overlay = document.getElementById("settings-overlay")
      const ctrl = this.application.getControllerForElementAndIdentifier(overlay, "settings-overlay")
      if (ctrl) ctrl.close()
    } else {
      const url = sessionStorage.getItem("settings_return_url") || "/"
      sessionStorage.removeItem("settings_return_url")
      window.location.href = url
    }
  }

  open() {
    this.sidebarTarget.classList.remove("hidden")
    if (this.hasBackdropTarget) this.backdropTarget.classList.remove("hidden")
  }

  close() {
    this.sidebarTarget.classList.add("hidden")
    if (this.hasBackdropTarget) this.backdropTarget.classList.add("hidden")
  }
}
