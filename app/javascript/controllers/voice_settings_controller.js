import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["verifyBtn", "verifyResult", "verifyStatus"]

  connect() {
    // Sync server-side audio processing settings → localStorage,
    // and wire up live-propagation so changes apply to active calls immediately.
    this._syncCheckbox("noise_suppression", "voice-noise-suppression", "voice:noise-suppression-changed", "enabled")
    this._syncCheckbox("echo_cancellation", "voice-echo-cancellation", "voice:echo-cancellation-changed", "enabled")
    this._syncCheckbox("auto_gain_control", "voice-auto-gain-control", "voice:agc-changed", "enabled")
  }

  // Sync a checkbox to localStorage and dispatch a live event on change
  _syncCheckbox(name, storageKey, eventName, detailKey) {
    const checkbox = this.element.querySelector(`input[name="${name}"][type="checkbox"]`)
    if (!checkbox) return

    // Initial sync
    localStorage.setItem(storageKey, checkbox.checked ? "true" : "false")

    // Live propagation on toggle
    checkbox.addEventListener("change", () => {
      const val = checkbox.checked
      localStorage.setItem(storageKey, val ? "true" : "false")
      window.dispatchEvent(new CustomEvent(eventName, { detail: { [detailKey]: val } }))
    })
  }

  async verify() {
    const btn = this.verifyBtnTarget
    const result = this.verifyResultTarget
    btn.textContent = "Verifying..."
    btn.disabled = true
    result.classList.add("hidden")

    try {
      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
      const response = await fetch("/settings/voice/verify", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        }
      })
      const data = await response.json()

      result.classList.remove("hidden")
      if (data.success) {
        result.className = "text-sm text-green-400"
        result.textContent = data.message

        // Update the status badge dynamically
        if (this.hasVerifyStatusTarget) {
          this.verifyStatusTarget.innerHTML = `
            <div class="flex items-center gap-1.5 text-green-400 text-sm">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/></svg>
              Verified
              <span class="text-gray-500 text-xs">(just now)</span>
            </div>
          `
        }
      } else {
        result.className = "text-sm text-red-400"
        result.textContent = data.message
      }
    } catch (e) {
      result.classList.remove("hidden")
      result.className = "text-sm text-red-400"
      result.textContent = "Verification request failed"
    } finally {
      btn.textContent = "Verify Connection"
      btn.disabled = false
    }
  }
}
