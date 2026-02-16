import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { serverId: String }

  connect() {
    this.menu = null
    this.moveDropdown = null
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
    const voiceStateId = target.dataset.voiceStateId
    if (!voiceStateId) return

    const response = await fetch(`/voice_states/${voiceStateId}/context_menu`, {
      headers: { "X-Requested-With": "XMLHttpRequest" }
    })
    if (!response.ok) return

    const html = await response.text()
    this.menu = document.createElement("div")
    this.menu.className = "fixed z-[60]"
    this.menu.setAttribute("data-context-menu", "voice")
    this.menu.innerHTML = html

    let left = event.clientX
    let top = event.clientY
    if (left + 220 > window.innerWidth) left = window.innerWidth - 220
    if (top + 300 > window.innerHeight) top = window.innerHeight - 300

    this.menu.style.left = `${left}px`
    this.menu.style.top = `${top}px`

    document.body.appendChild(this.menu)
    this.bindMenuActions()
    setTimeout(() => document.addEventListener("click", this.boundClose), 10)
  }

  bindMenuActions() {
    if (!this.menu) return
    this.menu.querySelectorAll("[data-context-action]").forEach(btn => {
      const action = btn.dataset.contextAction
      if (action === "serverMute") {
        btn.addEventListener("click", (e) => this.handleServerMute(e))
      } else if (action === "serverDeafen") {
        btn.addEventListener("click", (e) => this.handleServerDeafen(e))
      } else if (action === "kick") {
        btn.addEventListener("click", (e) => this.handleKick(e))
      } else if (action === "showMoveTargets") {
        btn.addEventListener("click", (e) => this.showMoveTargets(e))
      }
    })
  }

  async handleServerMute(event) {
    event.stopPropagation()
    const voiceStateId = event.currentTarget.dataset.voiceStateId
    const csrf = document.querySelector("meta[name=csrf-token]")?.content

    try {
      const res = await fetch(`/voice_states/${voiceStateId}/server_mute`, {
        method: "PATCH",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      })
      if (!res.ok) {
        const data = await res.json()
        this.showToast(data.error || "Failed to toggle server mute", true)
      }
    } catch (err) {
      this.showToast("Failed to toggle server mute", true)
    }
    this.closeMenu()
  }

  async handleServerDeafen(event) {
    event.stopPropagation()
    const voiceStateId = event.currentTarget.dataset.voiceStateId
    const csrf = document.querySelector("meta[name=csrf-token]")?.content

    try {
      const res = await fetch(`/voice_states/${voiceStateId}/server_deafen`, {
        method: "PATCH",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      })
      if (!res.ok) {
        const data = await res.json()
        this.showToast(data.error || "Failed to toggle server deafen", true)
      }
    } catch (err) {
      this.showToast("Failed to toggle server deafen", true)
    }
    this.closeMenu()
  }

  async handleKick(event) {
    event.stopPropagation()
    const voiceStateId = event.currentTarget.dataset.voiceStateId
    const csrf = document.querySelector("meta[name=csrf-token]")?.content

    try {
      const res = await fetch(`/voice_states/${voiceStateId}/kick`, {
        method: "POST",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      })
      if (!res.ok) {
        const data = await res.json()
        this.showToast(data.error || "Failed to disconnect user", true)
      }
    } catch (err) {
      this.showToast("Failed to disconnect user", true)
    }
    this.closeMenu()
  }

  showMoveTargets(event) {
    event.preventDefault()
    event.stopPropagation()

    if (this.moveDropdown) {
      this.moveDropdown.remove()
      this.moveDropdown = null
      return
    }

    const btn = event.currentTarget
    const voiceStateId = btn.dataset.voiceStateId
    const channels = JSON.parse(btn.dataset.channels || "[]")

    if (!this.menu || !channels.length) return

    this.moveDropdown = document.createElement("div")
    this.moveDropdown.className = "absolute z-[70] w-48 bg-gray-900 rounded-lg shadow-2xl border border-gray-700 py-1.5 text-sm max-h-64 overflow-y-auto"

    const wrapper = btn.closest(".context-move-wrapper")
    const btnRect = wrapper.getBoundingClientRect()

    let ddLeft = btnRect.right + 4
    if (ddLeft + 200 > window.innerWidth) {
      ddLeft = btnRect.left - 200
    }
    let ddTop = btnRect.top
    if (ddTop + 260 > window.innerHeight) {
      ddTop = window.innerHeight - 264
    }

    this.moveDropdown.style.position = "fixed"
    this.moveDropdown.style.left = `${ddLeft}px`
    this.moveDropdown.style.top = `${ddTop}px`

    let html = '<p class="px-3 py-1.5 text-[10px] font-semibold text-gray-500 uppercase sticky top-0 bg-gray-900">Move to</p>'
    channels.forEach(ch => {
      html += `<button class="flex items-center w-full px-3 py-1.5 text-gray-300 hover:bg-gray-700 hover:text-white rounded-sm"
                       data-context-action="move"
                       data-voice-state-id="${voiceStateId}"
                       data-target-channel-id="${ch.id}">
                 <svg class="w-4 h-4 text-gray-500 mr-2 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.536 8.464a5 5 0 010 7.072M12 6v12m-3.536-2.464a5 5 0 010-7.072"/></svg>
                 <span class="truncate">${this.escapeHtml(ch.name)}</span>
               </button>`
    })

    this.moveDropdown.innerHTML = html
    document.body.appendChild(this.moveDropdown)

    // Bind move actions
    this.moveDropdown.querySelectorAll('[data-context-action="move"]').forEach(moveBtn => {
      moveBtn.addEventListener("click", (e) => this.handleMove(e))
    })

    this.moveDropdown.addEventListener("click", (e) => e.stopPropagation())
  }

  async handleMove(event) {
    event.stopPropagation()
    const voiceStateId = event.currentTarget.dataset.voiceStateId
    const targetChannelId = event.currentTarget.dataset.targetChannelId
    const csrf = document.querySelector("meta[name=csrf-token]")?.content

    try {
      const res = await fetch(`/voice_states/${voiceStateId}/move`, {
        method: "POST",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
        body: JSON.stringify({ target_channel_id: targetChannelId })
      })
      if (!res.ok) {
        const data = await res.json()
        this.showToast(data.error || "Failed to move user", true)
      }
    } catch (err) {
      this.showToast("Failed to move user", true)
    }
    this.closeMenu()
  }

  closeMenu(event) {
    if (this.moveDropdown) {
      if (event && this.moveDropdown.contains(event.target)) return
      this.moveDropdown.remove()
      this.moveDropdown = null
    }
    if (this.menu) {
      if (event && this.menu.contains(event.target)) return
      this.menu.remove()
      this.menu = null
    }
    document.removeEventListener("click", this.boundClose)
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  showToast(msg, isError = false) {
    const toast = document.createElement("div")
    toast.className = `fixed bottom-6 right-6 ${isError ? "bg-red-600" : "bg-green-600"} text-white px-4 py-2 rounded-lg shadow-lg z-[200] text-sm font-medium`
    toast.textContent = msg
    document.body.appendChild(toast)
    setTimeout(() => toast.remove(), 3000)
  }
}
