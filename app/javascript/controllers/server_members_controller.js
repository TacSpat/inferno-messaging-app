import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

export default class extends Controller {
  static values = { serverId: String }
  static targets = ["list"]

  connect() {
    this.subscription = createConsumer().subscriptions.create(
      { channel: "ServerChannel", server_id: this.serverIdValue },
      {
        received: (data) => this.handleMessage(data)
      }
    )
  }

  disconnect() {
    if (this.subscription) this.subscription.unsubscribe()
  }

  handleMessage(data) {
    switch (data.type) {
      case "member_join":
        this.addMember(data)
        break
      case "member_leave":
        this.removeMember(data)
        break
      case "presence":
        this.updatePresence(data)
        break
      case "member_update":
        this.updateMember(data)
        break
    }
  }

  // Map any state to just "online" or "offline"
  normalizeState(state) {
    return state === "offline" ? "offline" : "online"
  }

  addMember(data) {
    if (!this.hasListTarget) return
    const existing = this.listTarget.querySelector(`[data-user-id="${data.user_id}"]`)
    if (existing) return

    this.ensureGroupHeader("online")
    const header = this.listTarget.querySelector('[data-status-group="online"]')
    let sibling = header.nextElementSibling
    while (sibling && !sibling.hasAttribute('data-status-group')) {
      sibling = sibling.nextElementSibling
    }
    if (sibling) {
      sibling.insertAdjacentHTML('beforebegin', data.html)
    } else {
      this.listTarget.insertAdjacentHTML('beforeend', data.html)
    }
    this.recountGroups()
  }

  removeMember(data) {
    if (!this.hasListTarget) return
    const el = this.listTarget.querySelector(`[data-user-id="${data.user_id}"]`)
    if (el) {
      el.remove()
      this.recountGroups()
    }
  }

  updatePresence(data) {
    if (!this.hasListTarget) return
    const el = this.listTarget.querySelector(`[data-user-id="${data.user_id}"]`)
    if (!el) return

    // Update status dot color
    const dot = el.querySelector('.rounded-full.border-2')
    if (dot) {
      dot.classList.remove('bg-green-500', 'bg-yellow-500', 'bg-red-500', 'bg-gray-500')
      const colorMap = { online: 'bg-green-500', idle: 'bg-yellow-500', dnd: 'bg-red-500', offline: 'bg-gray-500' }
      dot.classList.add(colorMap[data.state] || 'bg-gray-500')
    }

    // Update opacity
    const group = this.normalizeState(data.state)
    if (group === 'offline') {
      el.classList.add('opacity-40')
    } else {
      el.classList.remove('opacity-40')
    }

    // Move to correct group (online or offline)
    this.moveToGroup(el, group)
  }

  ensureGroupHeader(group) {
    let header = this.listTarget.querySelector(`[data-status-group="${group}"]`)
    if (header) return header

    const label = group === "online" ? "Online" : "Offline"
    const html = `<h3 class="text-xs font-semibold text-gray-400 uppercase tracking-wide mb-1 mt-4 first:mt-0 px-2" data-status-group="${group}">${label} \u2014 0</h3>`

    if (group === "online") {
      // Online always goes first
      this.listTarget.insertAdjacentHTML('afterbegin', html)
    } else {
      // Offline goes at the end
      this.listTarget.insertAdjacentHTML('beforeend', html)
    }
    return this.listTarget.querySelector(`[data-status-group="${group}"]`)
  }

  moveToGroup(el, group) {
    this.ensureGroupHeader(group)
    const header = this.listTarget.querySelector(`[data-status-group="${group}"]`)
    let sibling = header.nextElementSibling
    while (sibling && !sibling.hasAttribute('data-status-group')) {
      sibling = sibling.nextElementSibling
    }
    if (sibling) {
      sibling.before(el)
    } else {
      this.listTarget.appendChild(el)
    }
    this.recountGroups()
  }

  updateMember(data) {
    if (!this.hasListTarget) return
    const el = this.listTarget.querySelector(`[data-user-id="${data.user_id}"]`)
    if (el && data.html) {
      el.outerHTML = data.html
    }
    // Also update display names in message history
    document.querySelectorAll(`[data-author-id="${data.user_id}"] .text-orange-400`).forEach(nameEl => {
      if (data.display_name) nameEl.textContent = data.display_name
    })
    // Update own user panel (bottom-left) if it's the current user
    const currentUserId = document.body.dataset.currentUserId
    if (String(data.user_id) === String(currentUserId)) {
      const panel = document.querySelector("[style*='1a1b1e']")
      if (panel) {
        const nameEl = panel.querySelector(".text-white.truncate")
        if (nameEl && data.display_name) nameEl.textContent = data.display_name
        const tagEl = panel.querySelector(".text-gray-400.truncate")
        if (tagEl && data.tag) tagEl.textContent = data.tag
      }
    }
  }

  recountGroups() {
    ["online", "offline"].forEach(state => {
      const header = this.listTarget.querySelector(`[data-status-group="${state}"]`)
      if (!header) return
      let count = 0
      let sibling = header.nextElementSibling
      while (sibling && !sibling.hasAttribute('data-status-group')) {
        if (sibling.hasAttribute('data-user-id')) count++
        sibling = sibling.nextElementSibling
      }
      if (count === 0) {
        header.remove()
      } else {
        const label = state === "online" ? "Online" : "Offline"
        header.textContent = `${label} \u2014 ${count}`
      }
    })
  }
}
