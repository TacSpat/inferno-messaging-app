import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["checkbox", "roleSelector", "purgeWarning"]

  connect() {
    this.wasEncrypted = this.checkboxTarget.checked
  }

  toggle() {
    if (this.checkboxTarget.checked) {
      this.roleSelectorTarget.classList.remove("hidden")
      if (this.hasPurgeWarningTarget) {
        this.purgeWarningTarget.classList.add("hidden")
      }
    } else {
      this.roleSelectorTarget.classList.add("hidden")
      // Show purge warning when disabling encryption on a previously encrypted channel
      if (this.hasPurgeWarningTarget && this.wasEncrypted) {
        this.purgeWarningTarget.classList.remove("hidden")
      }
    }
  }

  confirmSubmit(event) {
    // If encryption was on and is now being turned off, confirm the destructive action
    if (this.wasEncrypted && !this.checkboxTarget.checked) {
      if (!confirm("Disabling encryption will permanently delete all message history in this channel. This cannot be undone. Continue?")) {
        event.preventDefault()
      }
    }
  }
}
