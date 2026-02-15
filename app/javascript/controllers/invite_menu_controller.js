import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel", "linkText", "copyBtn", "generateBtn"]
  static values = { baseUrl: String, serverId: String }

  toggle(event) {
    event.stopPropagation()
    this.panelTarget.classList.toggle("hidden")
  }

  copy() {
    const text = this.linkTextTarget.textContent.trim()
    if (!text) return
    navigator.clipboard.writeText(text)
    this.copyBtnTarget.textContent = "Copied!"
    setTimeout(() => this.copyBtnTarget.textContent = "Copy", 2000)
  }

  async generate() {
    this.generateBtnTarget.disabled = true
    this.generateBtnTarget.textContent = "Generating..."

    try {
      const token = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch(`/servers/${this.serverIdValue}/settings/invites`, {
        method: "POST",
        headers: {
          "X-CSRF-Token": token,
          "Accept": "application/json"
        }
      })

      if (response.ok) {
        const data = await response.json()
        const url = `${this.baseUrlValue}/invite/${data.code}`
        this.linkTextTarget.textContent = url
        this.linkTextTarget.classList.remove("italic", "text-gray-500")
        this.linkTextTarget.classList.add("text-gray-300", "select-all")
        this.copyBtnTarget.classList.remove("hidden")
        navigator.clipboard.writeText(url)
        this.copyBtnTarget.textContent = "Copied!"
        setTimeout(() => this.copyBtnTarget.textContent = "Copy", 2000)
      }
    } finally {
      this.generateBtnTarget.disabled = false
      this.generateBtnTarget.textContent = "Create New Invite"
    }
  }
}
