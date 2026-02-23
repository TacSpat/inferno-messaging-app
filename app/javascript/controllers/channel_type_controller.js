import { Controller } from "@hotwired/stimulus"

// Toggles voice-specific options visibility based on channel type select
export default class extends Controller {
  static targets = ["select", "voiceOptions"]

  connect() {
    this.toggle()
  }

  toggle() {
    if (!this.hasSelectTarget || !this.hasVoiceOptionsTarget) return
    const isVoice = this.selectTarget.value === "voice"
    this.voiceOptionsTarget.classList.toggle("hidden", !isVoice)
  }
}
