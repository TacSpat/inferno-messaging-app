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
    this.menu.className = "fixed z-[60] context-pop"
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

    const tpl = document.getElementById("tpl-move-dropdown").content.cloneNode(true)
    this.moveDropdown = tpl.firstElementChild
    const channelsContainer = this.moveDropdown.querySelector('[data-slot="channels"]')

    const itemTpl = document.getElementById("tpl-move-channel-item")
    channels.forEach(ch => {
      const itemClone = itemTpl.content.cloneNode(true)
      const itemBtn = itemClone.querySelector("button")
      itemBtn.dataset.contextAction = "move"
      itemBtn.dataset.voiceStateId = voiceStateId
      itemBtn.dataset.targetChannelId = ch.id
      itemBtn.querySelector('[data-slot="name"]').textContent = ch.name
      channelsContainer.appendChild(itemClone)
    })

    // Position dropdown
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

  showToast(msg, isError = false) {
    const toast = document.createElement("div")
    toast.className = `fixed bottom-6 right-6 ${isError ? "bg-danger" : "bg-success"} text-white px-4 py-2 rounded-lg shadow-lg z-[200] text-sm font-medium context-pop`
    toast.textContent = msg
    document.body.appendChild(toast)
    setTimeout(() => {
      toast.style.transition = "opacity 0.3s"
      toast.style.opacity = "0"
      setTimeout(() => toast.remove(), 300)
    }, 3000)
  }
}
