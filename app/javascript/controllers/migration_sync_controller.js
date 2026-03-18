import { Controller } from "@hotwired/stimulus"
import consumer from "../lib/cable"

export default class extends Controller {
  static targets = ["step", "progressBar", "detail", "error", "errorMsg"]
  static values = { url: String }

  static stepLabels = {
    starting: "Connecting to relays...",
    contacts: "Recovering contacts...",
    blocks: "Syncing block list...",
    servers: "Rejoining servers...",
    profiles: "Fetching contact profiles...",
    messages: "Recovering message history...",
    channels: "Syncing channel history...",
    servers_finishing: "Waiting for servers to sync...",
    complete: "Done! Redirecting...",
    failed: "Migration encountered an error",
    waiting: "Starting migration..."
  }

  connect() {
    // Subscribe to ActionCable for real-time progress updates
    this.subscription = consumer.subscriptions.create(
      { channel: "MigrationChannel" },
      { received: (data) => this.handleProgress(data) }
    )

    // Also do an initial poll to catch progress that arrived before subscription was ready
    this.pollOnce()
  }

  disconnect() {
    this.subscription?.unsubscribe()
  }

  handleProgress(data) {
    const label = this.constructor.stepLabels[data.step] || data.step
    this.stepTarget.textContent = label
    this.progressBarTarget.style.width = data.progress + "%"

    if (data.step === "complete" && data.redirect_url) {
      this.progressBarTarget.style.width = "100%"
      this.stepTarget.textContent = "Done! Redirecting..."
      this.detailTarget.textContent = "Welcome back!"
      setTimeout(() => { window.location.href = data.redirect_url }, 800)
    } else if (data.step === "failed") {
      this.showError(data.error || "Migration encountered an error. Your account was created — some data may sync later.")
    }
  }

  async pollOnce() {
    try {
      const response = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
      const data = await response.json()
      this.handleProgress(data)
    } catch {
      // ActionCable will deliver updates — no need to retry
    }
  }

  showError(msg) {
    this.errorTarget.classList.remove("hidden")
    this.errorMsgTarget.textContent = msg
    this.detailTarget.textContent = ""
    this.progressBarTarget.classList.remove("bg-gradient-to-r", "from-accent-dark", "to-accent")
    this.progressBarTarget.classList.add("bg-danger")
  }
}
