import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["copyNpubBtn", "passwordInput", "passwordForm", "keyDisplay", "nsecValue", "error",
                     "encryptedSection", "encryptedPasswordInput", "backupPasswordInput", "encryptedResult",
                     "ncryptsecValue", "encryptedError", "encryptedForm"]

  async copyNpub(event) {
    const value = event.currentTarget.dataset.value
    await navigator.clipboard.writeText(value)
    const btn = this.copyNpubBtnTarget
    btn.textContent = "Copied!"
    setTimeout(() => { btn.textContent = "Copy" }, 2000)
  }

  async revealKey() {
    const password = this.passwordInputTarget.value
    if (!password) {
      this.showError("Please enter your password")
      return
    }

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    try {
      const response = await fetch("/settings/reveal_nostr_key", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
        },
        body: JSON.stringify({ password }),
      })

      const data = await response.json()

      if (response.ok) {
        this.nsecValueTarget.textContent = data.nsec
        this.passwordFormTarget.classList.add("hidden")
        this.keyDisplayTarget.classList.remove("hidden")
        this.hideError()
      } else {
        this.showError(data.error || "Failed to reveal key")
      }
    } catch {
      this.showError("Network error. Please try again.")
    }
  }

  async copyNsec() {
    const value = this.nsecValueTarget.textContent
    await navigator.clipboard.writeText(value)
    const btn = this.keyDisplayTarget.querySelector("button")
    btn.textContent = "Copied!"
    setTimeout(() => { btn.textContent = "Copy" }, 2000)
  }

  async exportEncrypted() {
    const password = this.encryptedPasswordInputTarget.value
    const backupPassword = this.backupPasswordInputTarget.value

    if (!password) {
      this.showEncryptedError("Please enter your account password")
      return
    }
    if (!backupPassword || backupPassword.length < 8) {
      this.showEncryptedError("Backup password must be at least 8 characters")
      return
    }

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    try {
      const response = await fetch("/settings/export_encrypted_key", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
        },
        body: JSON.stringify({ password, backup_password: backupPassword }),
      })

      const data = await response.json()

      if (response.ok) {
        this.ncryptsecValueTarget.textContent = data.ncryptsec
        this.encryptedFormTarget.classList.add("hidden")
        this.encryptedResultTarget.classList.remove("hidden")
        this.hideEncryptedError()
      } else {
        this.showEncryptedError(data.error || "Failed to export key")
      }
    } catch {
      this.showEncryptedError("Network error. Please try again.")
    }
  }

  async copyNcryptsec() {
    const value = this.ncryptsecValueTarget.textContent
    await navigator.clipboard.writeText(value)
    const btn = this.encryptedResultTarget.querySelector("button")
    btn.textContent = "Copied!"
    setTimeout(() => { btn.textContent = "Copy" }, 2000)
  }

  showError(message) {
    this.errorTarget.textContent = message
    this.errorTarget.classList.remove("hidden")
  }

  hideError() {
    this.errorTarget.classList.add("hidden")
  }

  showEncryptedError(message) {
    this.encryptedErrorTarget.textContent = message
    this.encryptedErrorTarget.classList.remove("hidden")
  }

  hideEncryptedError() {
    this.encryptedErrorTarget.classList.add("hidden")
  }
}
