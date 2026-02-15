import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { serverId: String }

  connect() {
    this.menu = null
    this.boundClose = this.closeMenu.bind(this)
  }

  disconnect() {
    this.closeMenu()
  }

  async show(event) {
    event.preventDefault()
    event.stopPropagation()
    this.closeMenu()

    const target = event.currentTarget
    const userId = target.dataset.userId
    if (!userId || !this.serverIdValue) return

    const response = await fetch(`/servers/${this.serverIdValue}/members/${userId}/context_menu`, {
      headers: { "X-Requested-With": "XMLHttpRequest" }
    })
    if (!response.ok) return

    const html = await response.text()
    this.menu = document.createElement("div")
    this.menu.className = "fixed z-[60]"
    this.menu.innerHTML = html

    let left = event.clientX
    let top = event.clientY
    if (left + 220 > window.innerWidth) left = window.innerWidth - 220
    if (top + 300 > window.innerHeight) top = window.innerHeight - 300
    this.menu.style.left = `${left}px`
    this.menu.style.top = `${top}px`

    document.body.appendChild(this.menu)
    setTimeout(() => document.addEventListener("click", this.boundClose), 10)
  }

  closeMenu(event) {
    if (this.menu) {
      if (event && this.menu.contains(event.target)) return
      this.menu.remove()
      this.menu = null
    }
    document.removeEventListener("click", this.boundClose)
  }
}
