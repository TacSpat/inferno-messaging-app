import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { serverId: String }

  connect() {
    this.card = null
    this.boundClose = this.closeCard.bind(this)
  }

  disconnect() {
    this.closeCard()
  }

  async show(event) {
    event.preventDefault()
    event.stopPropagation()
    this.closeCard()

    // Close any other profile cards (e.g. from message clicks)
    document.querySelectorAll("[data-profile-card]").forEach(el => el.remove())

    const target = event.currentTarget
    const userId = target.dataset.userId
    if (!userId || !this.serverIdValue) return

    const response = await fetch(`/servers/${this.serverIdValue}/members/${userId}/profile_card`, {
      headers: { "X-Requested-With": "XMLHttpRequest" }
    })
    if (!response.ok) return

    // Close any open member context menu
    document.querySelectorAll("[data-context-menu='member']").forEach(el => el.remove())
    const notifMenu = document.getElementById("notif-context-menu")
    if (notifMenu) notifMenu.remove()

    const html = await response.text()
    this.card = document.createElement("div")
    this.card.className = "fixed z-50 context-pop"
    this.card.setAttribute("data-profile-card", "")
    this.card.innerHTML = html

    // Position to the left of the member sidebar
    const rect = target.getBoundingClientRect()
    let left = rect.left - 288
    let top = rect.top
    if (left < 8) left = rect.right + 8
    if (top + 400 > window.innerHeight) top = window.innerHeight - 400
    this.card.style.left = `${Math.max(8, left)}px`
    this.card.style.top = `${Math.max(8, top)}px`

    document.body.appendChild(this.card)
    setTimeout(() => document.addEventListener("click", this.boundClose), 10)
  }

  closeCard(event) {
    if (this.card) {
      // Don't close if clicking inside the card
      if (event && this.card.contains(event.target)) return
      this.card.remove()
      this.card = null
    }
    document.removeEventListener("click", this.boundClose)
  }
}
