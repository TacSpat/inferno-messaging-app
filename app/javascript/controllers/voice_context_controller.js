import { Controller } from "@hotwired/stimulus"
import { positionPopup } from "../utils/popup_positioning"

/**
 * Right-click context menu for voice channel participants.
 *
 * Scoped to the voice participant grid or the channel sidebar.
 * Actions include self-mute/deafen, server mute/deafen,
 * move to channel, disconnect, profile view, and copy ID.
 */
export default class extends Controller {
  static values = { serverId: String }

  connect() {
    this.menu = null
    this.moveDropdown = null
    this.boundClose = this.closeMenu.bind(this)
    this._boundEscape = (e) => { if (e.key === "Escape") this.closeMenu() }
    this._onStreamContext = (e) => this.showStreamMenu(e)
    window.addEventListener("voice:stream-context", this._onStreamContext)
  }

  disconnect() {
    this.closeMenu()
    window.removeEventListener("voice:stream-context", this._onStreamContext)
  }

  async show(event) {
    event.preventDefault()
    event.stopPropagation()
    this.closeMenu()

    // Find the voice card or sidebar row
    const target = event.currentTarget
    const userId = target.dataset.voiceParticipantId || target.dataset.voiceUserId
    if (!userId) return

    // Resolve server ID from controller value, DOM data, or the sidebar
    const serverId = this.serverIdValue
      || document.querySelector("[data-current-server-id]")?.dataset.currentServerId
      || document.querySelector("[data-channel-sidebar-server-id-value]")?.dataset.channelSidebarServerIdValue
    if (!serverId) return

    try {
      const response = await fetch(`/servers/${serverId}/voice/context_menu/${userId}`, {
        headers: { "X-Requested-With": "XMLHttpRequest" }
      })
      if (!response.ok) return

      const html = await response.text()
      this.menu = document.createElement("div")
      this.menu.className = "fixed z-[60] context-pop"
      this.menu.setAttribute("data-voice-context-menu", "")
      this.menu.innerHTML = html

      document.body.appendChild(this.menu)
      positionPopup(this.menu, { x: event.clientX, y: event.clientY }, {
        preferredSide: "below",
        horizontalAlign: "left"
      })
      this._bindActions(serverId)
      setTimeout(() => {
        document.addEventListener("click", this.boundClose)
        document.addEventListener("keydown", this._boundEscape)
      }, 10)
    } catch (e) {
      console.warn("[VoiceContext] Failed to load context menu:", e)
    }
  }

  showStreamMenu(event) {
    this.closeMenu()
    const { identity, x, y } = event.detail
    if (!identity) return

    const voiceEl = document.querySelector("[data-controller~='voice-channel']")
    if (!voiceEl) return
    const vc = this.application.getControllerForElementAndIdentifier(voiceEl, "voice-channel")
    if (!vc) return

    const hasAudio = vc._screenShareAudioElements.has(identity)
    const isLocal = identity === vc.room?.localParticipant?.identity
    const hasChildren = vc._childChannels?.length > 0

    // Nothing to show if no audio and no broadcast option
    if (!hasAudio && !(isLocal && hasChildren)) return

    const wrapper = document.createElement("div")
    wrapper.className = "w-52 bg-gray-900 rounded-lg shadow-2xl border border-gray-700 py-1.5 px-1.5 text-sm"

    // Volume slider + mute for remote screen shares with audio
    if (hasAudio && !isLocal) {
      const saved = localStorage.getItem(`ss-vol-${identity}`)
      const savedVal = saved ? parseInt(saved, 10) : 100

      // Volume slider
      const volDiv = document.createElement("div")
      volDiv.className = "px-2.5 py-1.5"
      volDiv.innerHTML = `
        <div class="flex items-center justify-between mb-1">
          <span class="text-gray-400 text-xs">Stream Volume</span>
          <span class="text-gray-500 text-[10px]" data-ss-vol-label>${savedVal}%</span>
        </div>
        <input type="range" min="0" max="200" value="${savedVal}"
               class="w-full h-1 accent-accent cursor-pointer"
               data-ss-vol-slider>
      `
      wrapper.appendChild(volDiv)

      const slider = volDiv.querySelector("[data-ss-vol-slider]")
      const label = volDiv.querySelector("[data-ss-vol-label]")
      slider.addEventListener("input", (e) => {
        e.stopPropagation()
        const vol = parseInt(slider.value, 10)
        label.textContent = `${vol}%`
        localStorage.setItem(`ss-vol-${identity}`, vol)
        vc.setScreenShareVolume(identity, vol / 100)
      })

      // Mute toggle
      const el = vc._screenShareAudioElements.get(identity)
      const isMuted = el?.muted ?? false
      const sep = document.createElement("div")
      sep.className = "border-t border-gray-700 my-1"
      wrapper.appendChild(sep)

      const muteBtn = document.createElement("button")
      muteBtn.className = "flex items-center justify-between w-full px-2.5 py-1.5 text-gray-300 hover:bg-gray-700 hover:text-white rounded cursor-pointer"
      muteBtn.innerHTML = `
        <span>${isMuted ? "Unmute" : "Mute"} Stream Audio</span>
        <div class="w-8 h-4 rounded-full transition-colors ${isMuted ? "bg-accent" : "bg-gray-600"} relative">
          <span class="block w-3 h-3 bg-white rounded-full absolute top-0.5 transition-transform ${isMuted ? "translate-x-4" : "translate-x-0.5"}"></span>
        </div>
      `
      muteBtn.addEventListener("click", (e) => {
        e.stopPropagation()
        const nowMuted = vc.muteScreenShareAudio(identity)
        const toggle = muteBtn.querySelector(".rounded-full")
        const knob = muteBtn.querySelector(".rounded-full span")
        const lbl = muteBtn.querySelector("span")
        lbl.textContent = `${nowMuted ? "Unmute" : "Mute"} Stream Audio`
        toggle.classList.toggle("bg-accent", nowMuted)
        toggle.classList.toggle("bg-gray-600", !nowMuted)
        knob.classList.toggle("translate-x-4", nowMuted)
        knob.classList.toggle("translate-x-0.5", !nowMuted)
      })
      wrapper.appendChild(muteBtn)
    }

    // Broadcast toggle for local stream in parent channels with children
    if (isLocal && hasChildren) {
      if (wrapper.children.length > 0) {
        const sep = document.createElement("div")
        sep.className = "border-t border-gray-700 my-1"
        wrapper.appendChild(sep)
      }

      const broadcastBtn = document.createElement("button")
      broadcastBtn.className = "flex items-center justify-between w-full px-2.5 py-1.5 text-gray-300 hover:bg-gray-700 hover:text-white rounded cursor-pointer"
      const isOn = vc._broadcasting
      broadcastBtn.innerHTML = `
        <span>Broadcast to Children</span>
        <div class="w-8 h-4 rounded-full transition-colors ${isOn ? "bg-green-500" : "bg-gray-600"} relative">
          <span class="block w-3 h-3 bg-white rounded-full absolute top-0.5 transition-transform ${isOn ? "translate-x-4" : "translate-x-0.5"}"></span>
        </div>
      `
      broadcastBtn.addEventListener("click", (e) => {
        e.stopPropagation()
        vc.toggleBroadcast()
        const nowOn = vc._broadcasting
        const toggle = broadcastBtn.querySelector(".rounded-full")
        const knob = broadcastBtn.querySelector(".rounded-full span")
        toggle.classList.toggle("bg-green-500", nowOn)
        toggle.classList.toggle("bg-gray-600", !nowOn)
        knob.classList.toggle("translate-x-4", nowOn)
        knob.classList.toggle("translate-x-0.5", !nowOn)
      })
      wrapper.appendChild(broadcastBtn)
    }

    this.menu = document.createElement("div")
    this.menu.className = "fixed z-[60] context-pop"
    this.menu.setAttribute("data-voice-context-menu", "")
    this.menu.appendChild(wrapper)

    document.body.appendChild(this.menu)
    positionPopup(this.menu, { x, y }, {
      preferredSide: "below",
      horizontalAlign: "left"
    })
    setTimeout(() => {
      document.addEventListener("click", this.boundClose)
      document.addEventListener("keydown", this._boundEscape)
    }, 10)
  }

  _bindActions(serverId) {
    if (!this.menu) return

    this.menu.querySelectorAll("[data-context-action]").forEach(btn => {
      const action = btn.dataset.contextAction

      if (action === "viewProfile") {
        btn.addEventListener("click", (e) => {
          e.stopPropagation()
          this.closeMenu()
          document.dispatchEvent(new CustomEvent("inferno:open-profile-overlay", {
            detail: { userId: btn.dataset.userId, serverId: btn.dataset.serverId },
            bubbles: true
          }))
        })
      } else if (action === "selfMute") {
        btn.addEventListener("click", (e) => {
          e.stopPropagation()
          this.closeMenu()
          // Trigger the voice channel controller's toggleMute
          const voiceCtrl = document.querySelector("[data-controller~='voice-channel']")
          if (voiceCtrl) {
            const controller = this.application.getControllerForElementAndIdentifier(voiceCtrl, "voice-channel")
            controller?.toggleMute()
          }
        })
      } else if (action === "selfDeafen") {
        btn.addEventListener("click", (e) => {
          e.stopPropagation()
          this.closeMenu()
          const voiceCtrl = document.querySelector("[data-controller~='voice-channel']")
          if (voiceCtrl) {
            const controller = this.application.getControllerForElementAndIdentifier(voiceCtrl, "voice-channel")
            controller?.toggleDeafen()
          }
        })
      } else if (action === "userVolume") {
        // Per-user volume slider — load saved value and bind input
        const userId = btn.dataset.userId
        const saved = localStorage.getItem(`user-vol-${userId}`)
        if (saved) btn.value = saved
        const label = btn.closest("div")?.querySelector("[data-volume-label]")
        if (label) label.textContent = `${btn.value}%`
        btn.addEventListener("input", (e) => {
          e.stopPropagation()
          const vol = parseInt(btn.value, 10)
          if (label) label.textContent = `${vol}%`
          localStorage.setItem(`user-vol-${userId}`, vol)
          this._setUserVolume(userId, vol / 100)
        })
        // Apply saved volume immediately if different from default
        if (saved) this._setUserVolume(userId, parseInt(saved, 10) / 100)
      } else if (action === "showcaseUser") {
        btn.addEventListener("click", (e) => {
          e.stopPropagation()
          this._showcaseUser(serverId, btn.dataset.userId, btn.dataset.childChannelId)
          this.closeMenu()
        })
      } else if (action === "showcaseChannel") {
        btn.addEventListener("click", (e) => {
          e.stopPropagation()
          this._showcaseChannel(serverId, btn.dataset.childChannelId)
          this.closeMenu()
        })
      } else if (action === "serverMute") {
        btn.addEventListener("click", (e) => {
          e.stopPropagation()
          this._patchVoiceModeration(serverId, btn.dataset.userId, "server_mute")
          this.closeMenu()
        })
      } else if (action === "serverDeafen") {
        btn.addEventListener("click", (e) => {
          e.stopPropagation()
          this._patchVoiceModeration(serverId, btn.dataset.userId, "server_deafen")
          this.closeMenu()
        })
      } else if (action === "moveToChannel") {
        btn.addEventListener("click", (e) => {
          e.stopPropagation()
          this._showMoveDropdown(e, serverId, btn)
        })
      } else if (action === "disconnectMember") {
        btn.addEventListener("click", (e) => {
          e.stopPropagation()
          const username = btn.dataset.username
          if (confirm(`Disconnect ${username} from voice?`)) {
            this._disconnectMember(serverId, btn.dataset.userId)
          }
          this.closeMenu()
        })
      }
    })
  }

  async _patchVoiceModeration(serverId, userId, action) {
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    try {
      await fetch(`/servers/${serverId}/voice/${action}/${userId}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        }
      })
    } catch (e) {
      console.warn("[VoiceContext] Moderation action failed:", e)
    }
  }

  async _disconnectMember(serverId, userId) {
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    try {
      await fetch(`/servers/${serverId}/voice/disconnect/${userId}`, {
        method: "DELETE",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        }
      })
    } catch (e) {
      console.warn("[VoiceContext] Disconnect failed:", e)
    }
  }

  _showMoveDropdown(event, serverId, btn) {
    if (this.moveDropdown) {
      this.moveDropdown.remove()
      this.moveDropdown = null
      return
    }

    const channels = JSON.parse(btn.dataset.voiceChannels || "[]")
    const userId = btn.dataset.userId

    const tpl = document.getElementById("tpl-move-dropdown")
    if (!tpl) return

    this.moveDropdown = tpl.content.cloneNode(true).firstElementChild
    const slot = this.moveDropdown.querySelector("[data-slot='channels']")

    if (channels.length === 0) {
      slot.innerHTML = '<p class="px-3 py-2 text-xs text-gray-500">No other voice channels</p>'
    } else {
      const itemTpl = document.getElementById("tpl-move-channel-item")
      channels.forEach(ch => {
        const item = itemTpl.content.cloneNode(true).querySelector("button")
        item.querySelector("[data-slot='name']").textContent = ch.name
        item.addEventListener("click", (e) => {
          e.stopPropagation()
          this._moveMember(serverId, userId, ch.id)
          this.closeMenu()
        })
        slot.appendChild(item)
      })
    }

    // Position to the right of the move button wrapper
    const wrapper = btn.closest(".context-move-wrapper")
    const wrapperRect = wrapper.getBoundingClientRect()

    this.moveDropdown.style.position = "fixed"
    let ddLeft = wrapperRect.right + 4
    if (ddLeft + 200 > window.innerWidth) {
      ddLeft = wrapperRect.left - 200
    }
    let ddTop = wrapperRect.top
    if (ddTop + 260 > window.innerHeight) {
      ddTop = window.innerHeight - 264
    }
    this.moveDropdown.style.left = `${ddLeft}px`
    this.moveDropdown.style.top = `${ddTop}px`

    document.body.appendChild(this.moveDropdown)
    this.moveDropdown.addEventListener("click", (e) => e.stopPropagation())
  }

  async _moveMember(serverId, userId, channelId) {
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    try {
      await fetch(`/servers/${serverId}/voice/move/${userId}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({ channel_id: channelId })
      })
    } catch (e) {
      console.warn("[VoiceContext] Move failed:", e)
    }
  }

  _setUserVolume(userId, gain) {
    const voiceCtrl = document.querySelector("[data-controller~='voice-channel']")
    if (!voiceCtrl) return
    const controller = this.application.getControllerForElementAndIdentifier(voiceCtrl, "voice-channel")
    controller?.setUserVolume(userId, gain)
  }

  async _showcaseUser(serverId, userId, childChannelId) {
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    try {
      await fetch(`/servers/${serverId}/voice_showcases`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({ child_channel_id: childChannelId, user_id: userId })
      })
    } catch (e) {
      console.warn("[VoiceContext] Showcase user failed:", e)
    }
  }

  async _showcaseChannel(serverId, childChannelId) {
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    try {
      await fetch(`/servers/${serverId}/voice_showcases`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({ child_channel_id: childChannelId })
      })
    } catch (e) {
      console.warn("[VoiceContext] Showcase channel failed:", e)
    }
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
    document.removeEventListener("keydown", this._boundEscape)
  }
}
