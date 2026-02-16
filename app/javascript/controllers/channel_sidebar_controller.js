import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

export default class extends Controller {
  static values = { serverId: String }

  connect() {
    this.subscription = createConsumer().subscriptions.create(
      { channel: "ServerChannel", server_id: this.serverIdValue },
      {
        received: (data) => this.handleMessage(data)
      }
    )

    this._channelCache = new Map()

    // Use capture phase so we fire before Turbo's bubble-phase handler
    this._onChannelClick = this._handleChannelClick.bind(this)
    this.element.addEventListener("click", this._onChannelClick, true)

    // Cache current channel content before Turbo replaces it (non-cached navigations)
    this._onBeforeFrameRender = (e) => {
      if (e.target.id !== "main-content") return
      const frame = e.target
      const currentId = this._getCurrentChannelId(frame)
      if (currentId && !this._channelCache.has(currentId)) {
        this._channelCache.set(currentId, frame.innerHTML)
        this._enforceCacheLimit()
      }
    }
    document.addEventListener("turbo:before-frame-render", this._onBeforeFrameRender)
  }

  disconnect() {
    if (this.subscription) this.subscription.unsubscribe()
    this.element.removeEventListener("click", this._onChannelClick, true)
    document.removeEventListener("turbo:before-frame-render", this._onBeforeFrameRender)
    this._channelCache.clear()
  }

  _getCurrentChannelId(frame) {
    const el = frame?.querySelector("[data-current-channel-id]")
    return el?.dataset.currentChannelId || null
  }

  _enforceCacheLimit() {
    while (this._channelCache.size > 10) {
      const oldest = this._channelCache.keys().next().value
      this._channelCache.delete(oldest)
    }
  }

  _handleChannelClick(e) {
    const link = e.target.closest("a[data-channel-id]")
    if (!link) return

    const targetId = link.dataset.channelId
    const frame = document.getElementById("main-content")
    const currentId = this._getCurrentChannelId(frame)

    // Same channel — no-op
    if (targetId === currentId) {
      e.preventDefault()
      e.stopPropagation()
      return
    }

    // If target is cached: prevent Turbo fetch, restore from cache
    if (this._channelCache.has(targetId)) {
      e.preventDefault()
      e.stopPropagation()

      // Cache current channel first
      if (currentId && frame) {
        this._channelCache.set(currentId, frame.innerHTML)
        this._enforceCacheLimit()
      }

      // Restore cached channel
      frame.innerHTML = this._channelCache.get(targetId)
      this._channelCache.delete(targetId)

      // Update URL
      history.pushState({}, "", link.getAttribute("href"))
    }
    // Non-cached: turbo:before-frame-render will cache current content automatically

    // Always update active channel styling
    this._updateActiveChannel(link)
  }

  _updateActiveChannel(link) {
    const active = this.element.querySelector("a[data-channel-id].bg-gray-600")
    if (active && active !== link) {
      active.classList.remove("bg-gray-600")
      if (active.querySelector(".unread-pill") || active.querySelector(".font-bold")) {
        active.classList.add("hover:bg-gray-700")
      } else {
        active.classList.remove("text-white")
        active.classList.add("text-gray-400", "hover:bg-gray-700", "hover:text-gray-200")
      }
    }

    link.classList.remove("text-gray-400", "hover:bg-gray-700", "hover:text-gray-200")
    link.classList.add("bg-gray-600", "text-white")

    const pill = link.querySelector(".unread-pill")
    if (pill) pill.remove()
    const nameSpan = link.querySelector(".truncate")
    if (nameSpan) nameSpan.classList.remove("font-bold")
    const badge = link.querySelector(".mention-badge")
    if (badge) badge.remove()
  }

  handleMessage(data) {
    switch (data.type) {
      case "channel_created":
        this.addChannel(data)
        break
      case "channel_updated":
        this.updateChannel(data)
        break
      case "channel_deleted":
        this.removeChannel(data)
        break
      case "category_created":
        this.addCategory(data)
        break
      case "category_updated":
        this.updateCategory(data)
        break
      case "category_deleted":
        this.removeCategory(data)
        break
      case "sidebar_reorder":
        this.reorderSidebar(data)
        break
      case "voice_state_join":
        this.handleVoiceJoin(data)
        break
      case "voice_state_leave":
        this.handleVoiceLeave(data)
        break
      case "voice_state_update":
        this.handleVoiceUpdate(data)
        break
      case "voice_state_kicked":
        this.handleVoiceKicked(data)
        break
      case "voice_state_moved":
        this.handleVoiceMoved(data)
        break
    }
  }

  buildChannelHtml(data) {
    const serverId = this.serverIdValue
    return `<a href="/servers/${serverId}/channels/${data.channel_id}"
               data-turbo-frame="main-content"
               data-channel-id="${data.channel_id}"
               class="flex items-center px-2 py-1.5 rounded group relative text-gray-400 hover:bg-gray-700 hover:text-gray-200">
              <span class="text-lg mr-1.5 opacity-60">#</span>
              <span class="truncate text-sm font-medium flex-1">${this.escapeHtml(data.name)}</span>
            </a>`
  }

  addChannel(data) {
    // Don't add if already exists
    if (this.element.querySelector(`[data-channel-id="${data.channel_id}"]`)) return
    const html = this.buildChannelHtml(data)

    if (data.category_id) {
      const categoryEl = this.element.querySelector(`[data-category-id="${data.category_id}"]`)
      if (categoryEl) {
        const channelsDiv = categoryEl.querySelector("[data-category-collapse-target='channels']")
        if (channelsDiv) {
          channelsDiv.insertAdjacentHTML("beforeend", html)
          return
        }
      }
    }
    const firstCategory = this.element.querySelector("[data-category-id]")
    if (firstCategory) {
      firstCategory.insertAdjacentHTML("beforebegin", html)
    } else {
      this.element.insertAdjacentHTML("beforeend", html)
    }
  }

  updateChannel(data) {
    const existing = this.element.querySelector(`[data-channel-id="${data.channel_id}"]`)
    if (!existing) return
    const nameSpan = existing.querySelector(".truncate")
    if (nameSpan && data.name) nameSpan.textContent = data.name
  }

  removeChannel(data) {
    const el = this.element.querySelector(`[data-channel-id="${data.channel_id}"]`)
    if (el) el.remove()
  }

  buildCategoryHtml(data) {
    const serverId = this.serverIdValue
    return `<div data-controller="category-collapse" data-category-collapse-id-value="${data.category_id}" data-category-id="${data.category_id}" class="mb-1">
              <div class="flex items-center justify-between px-2 pt-4 pb-1 cursor-pointer group"
                   data-action="click->category-collapse#toggle">
                <div class="flex items-center">
                  <svg data-category-collapse-target="arrow" class="w-3 h-3 text-gray-400 mr-0.5 transition-transform duration-200" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/>
                  </svg>
                  <span class="text-xs font-semibold text-gray-400 uppercase tracking-wide group-hover:text-gray-200">${this.escapeHtml(data.name)}</span>
                </div>
              </div>
              <div data-category-collapse-target="channels" class="space-y-0.5"></div>
            </div>`
  }

  addCategory(data) {
    if (this.element.querySelector(`[data-category-id="${data.category_id}"]`)) return
    const html = this.buildCategoryHtml(data)
    this.element.insertAdjacentHTML("beforeend", html)
  }

  updateCategory(data) {
    const el = this.element.querySelector(`[data-category-id="${data.category_id}"]`)
    if (el && data.name) {
      const nameSpan = el.querySelector(".uppercase.tracking-wide")
      if (nameSpan) nameSpan.textContent = data.name
    }
  }

  removeCategory(data) {
    const el = this.element.querySelector(`[data-category-id="${data.category_id}"]`)
    if (!el) return
    const channels = el.querySelectorAll("[data-channel-id]")
    const firstCategory = this.element.querySelector("[data-category-id]")
    channels.forEach(ch => {
      if (firstCategory && firstCategory !== el) firstCategory.before(ch)
      else this.element.prepend(ch)
    })
    el.remove()
  }

  reorderSidebar(data) {
    const { channels, categories } = data

    // Sort categories by position and reorder DOM
    if (categories?.length) {
      const sorted = [...categories].sort((a, b) => a.position - b.position)
      sorted.forEach(cat => {
        const el = this.element.querySelector(`[data-category-id="${cat.id}"]`)
        if (el) this.element.appendChild(el)
      })
    }

    // Move channels to their correct category/position
    if (channels?.length) {
      // Group by category
      const byCat = {}
      channels.forEach(ch => {
        const key = ch.category_id || "__uncategorized__"
        if (!byCat[key]) byCat[key] = []
        byCat[key].push(ch)
      })

      // Sort each group by position
      Object.values(byCat).forEach(group => group.sort((a, b) => a.position - b.position))

      // Place uncategorized channels before first category
      if (byCat["__uncategorized__"]) {
        const firstCat = this.element.querySelector("[data-category-id]")
        byCat["__uncategorized__"].forEach(ch => {
          const el = this.element.querySelector(`[data-channel-id="${ch.id}"]`)
          if (!el) return
          if (firstCat) firstCat.before(el)
          else this.element.appendChild(el)
        })
      }

      // Place categorized channels
      Object.entries(byCat).forEach(([catId, group]) => {
        if (catId === "__uncategorized__") return
        const catEl = this.element.querySelector(`[data-category-id="${catId}"]`)
        if (!catEl) return
        const container = catEl.querySelector("[data-category-collapse-target='channels']")
        if (!container) return
        group.forEach(ch => {
          const el = this.element.querySelector(`[data-channel-id="${ch.id}"]`)
          if (el) container.appendChild(el)
        })
      })
    }
  }

  handleVoiceJoin(data) {
    // Update sidebar participant list
    const channelLink = this.element.querySelector(`a[data-channel-id="${data.channel_id}"]`)
    if (channelLink) {
      let container = this.element.querySelector(`[data-voice-channel-participants="${data.channel_id}"]`)
      if (!container) {
        container = document.createElement("div")
        container.className = "voice-participants"
        container.dataset.voiceChannelParticipants = data.channel_id
        channelLink.insertAdjacentElement("afterend", container)
      }

      // Don't add if already present
      if (!container.querySelector(`[data-voice-user-id="${data.user_id}"]`) && data.html) {
        container.insertAdjacentHTML("beforeend", data.html)
      }
    }

    // Update main voice view participant grid (if viewing this channel)
    const wrapper = document.querySelector("[data-current-channel-id]")
    if (wrapper?.dataset.currentChannelId === data.channel_id) {
      const gridContainer = document.querySelector("[data-voice-participant-grid]")
      const emptyState = document.querySelector("[data-voice-empty-state]")

      const color = data.profile_color || "#2b2d31"
      const initial = data.username?.[0]?.toUpperCase() || "?"
      const avatarHtml = data.avatar_url
        ? `<img src="${data.avatar_url}" class="voice-avatar" />`
        : `<div class="voice-avatar-fallback" style="background-color: color-mix(in srgb, ${color}, white 20%)">${initial}</div>`

      const vsId = data.voice_state_id || ""
      const cardHtml = `
        <div class="voice-card group" data-voice-participant-id="${data.user_id}" data-voice-state-id="${vsId}" data-action="contextmenu->voice-context#show" style="--card-color: ${color}">
          <div class="voice-card-inner">
            <div class="voice-avatar-wrapper">${avatarHtml}</div>
            <div class="voice-username-pill">
              <span class="truncate">${this.escapeHtml(data.username)}</span>
            </div>
          </div>
        </div>`

      if (emptyState) {
        emptyState.outerHTML = `<div class="flex-1 p-3 overflow-y-auto" data-voice-participant-grid><div class="voice-grid h-full">${cardHtml}</div></div>`
      } else if (gridContainer) {
        const grid = gridContainer.querySelector(".voice-grid") || gridContainer
        if (!grid.querySelector(`[data-voice-participant-id="${data.user_id}"]`)) {
          grid.insertAdjacentHTML("beforeend", cardHtml)
        }
      }
    }
  }

  handleVoiceLeave(data) {
    // Update sidebar participant list
    const container = this.element.querySelector(`[data-voice-channel-participants="${data.channel_id}"]`)
    if (container) {
      const participant = container.querySelector(`[data-voice-user-id="${data.user_id}"]`)
      if (participant) participant.remove()
      if (!container.children.length) container.remove()
    }

    // Update main voice view participant grid (if viewing this channel)
    const wrapper = document.querySelector("[data-current-channel-id]")
    if (wrapper?.dataset.currentChannelId === data.channel_id) {
      const card = document.querySelector(`[data-voice-participant-id="${data.user_id}"]`)
      if (card) card.remove()

      // Show empty state if grid is now empty
      const gridContainer = document.querySelector("[data-voice-participant-grid]")
      const voiceGrid = gridContainer?.querySelector(".voice-grid")
      if (gridContainer && voiceGrid && voiceGrid.children.length === 0) {
        const channelName = wrapper.querySelector("h1")?.textContent || "Voice Channel"
        gridContainer.outerHTML = `
          <div class="flex-1 flex flex-col items-center justify-center p-8" data-voice-empty-state>
            <div class="w-24 h-24 rounded-full flex items-center justify-center mx-auto mb-6" style="background: rgba(255,255,255,0.05);">
              <svg class="w-12 h-12 text-gray-500" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M15.536 8.464a5 5 0 010 7.072M12 6v12m-3.536-2.464a5 5 0 010-7.072M18.364 5.636a9 9 0 010 12.728M5.636 18.364a9 9 0 010-12.728"/></svg>
            </div>
            <h2 class="text-xl font-bold text-white mb-1">${this.escapeHtml(channelName)}</h2>
            <p class="text-gray-500 text-sm">No one is in this channel yet.</p>
          </div>`
      }
    }
  }

  handleVoiceUpdate(data) {
    // Update sidebar participant icons
    const participant = this.element.querySelector(`[data-voice-user-id="${data.user_id}"]`)
    if (participant) {
      // Remove all existing state icons
      participant.querySelectorAll(".voice-mute-icon, .voice-deaf-icon, .voice-server-mute-icon, .voice-server-deaf-icon").forEach(el => el.remove())

      const nameSpan = participant.querySelector("span")
      // Server mute takes priority over self mute for display
      if (data.server_mute && nameSpan) {
        nameSpan.insertAdjacentHTML("afterend", '<svg class="voice-server-mute-icon w-3 h-3 text-red-400 ml-1 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/><line x1="3" y1="3" x2="21" y2="21" stroke-width="2" stroke-linecap="round"/></svg>')
      } else if (data.self_mute && nameSpan) {
        nameSpan.insertAdjacentHTML("afterend", '<svg class="voice-mute-icon w-3 h-3 text-gray-500 ml-1 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"/></svg>')
      }
      // Server deaf takes priority over self deaf
      if (data.server_deaf && nameSpan) {
        nameSpan.insertAdjacentHTML("afterend", '<svg class="voice-server-deaf-icon w-3 h-3 text-red-400 ml-1 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728L5.636 5.636"/></svg>')
      } else if (data.self_deaf && nameSpan) {
        nameSpan.insertAdjacentHTML("afterend", '<svg class="voice-deaf-icon w-3 h-3 text-gray-500 ml-1 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728L5.636 5.636"/></svg>')
      }
    }

    // Update main voice view card status icons
    const card = document.querySelector(`[data-voice-participant-id="${data.user_id}"]`)
    if (card) {
      const existingIcons = card.querySelector(".voice-status-icons")
      if (existingIcons) existingIcons.remove()

      const hasMute = data.server_mute || data.self_mute
      const hasDeaf = data.server_deaf || data.self_deaf
      if (hasMute || hasDeaf) {
        let badgesHtml = ""
        if (hasMute) {
          const color = data.server_mute ? "text-red-400" : ""
          badgesHtml += `<div class="voice-status-badge ${data.server_mute ? 'server-muted' : ''}"><svg class="w-3.5 h-3.5 ${color}" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/><line x1="3" y1="3" x2="21" y2="21" stroke-width="2.5" stroke-linecap="round"/></svg></div>`
        }
        if (hasDeaf) {
          const color = data.server_deaf ? "text-red-400" : ""
          badgesHtml += `<div class="voice-status-badge ${data.server_deaf ? 'server-deafened' : ''}"><svg class="w-3.5 h-3.5 ${color}" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"/></svg></div>`
        }
        const inner = card.querySelector(".voice-card-inner")
        if (inner) {
          inner.insertAdjacentHTML("beforeend", `<div class="voice-status-icons">${badgesHtml}</div>`)
        }
      }
    }

    // Dispatch window events for the voice channel controller to handle
    const currentUserId = document.body.dataset.currentUserId
    if (data.user_id === currentUserId) {
      if (data.server_mute !== undefined) {
        window.dispatchEvent(new CustomEvent("voice:server-mute", { detail: { serverMute: data.server_mute } }))
      }
      if (data.server_deaf !== undefined) {
        window.dispatchEvent(new CustomEvent("voice:server-deafen", { detail: { serverDeaf: data.server_deaf } }))
      }
    }
  }

  handleVoiceKicked(data) {
    // Remove participant from sidebar
    const container = this.element.querySelector(`[data-voice-channel-participants="${data.channel_id}"]`)
    if (container) {
      const participant = container.querySelector(`[data-voice-user-id="${data.user_id}"]`)
      if (participant) participant.remove()
      if (!container.children.length) container.remove()
    }

    // Remove card from main voice view
    const wrapper = document.querySelector("[data-current-channel-id]")
    if (wrapper?.dataset.currentChannelId === data.channel_id) {
      const card = document.querySelector(`[data-voice-participant-id="${data.user_id}"]`)
      if (card) card.remove()

      this._showEmptyStateIfEmpty(wrapper)
    }

    // If the kicked user is the current user, dispatch force-disconnect
    const currentUserId = document.body.dataset.currentUserId
    if (data.user_id === currentUserId) {
      window.dispatchEvent(new CustomEvent("voice:force-disconnect"))
    }
  }

  handleVoiceMoved(data) {
    // Remove participant from old channel's sidebar list
    const oldContainer = this.element.querySelector(`[data-voice-channel-participants="${data.from_channel_id}"]`)
    if (oldContainer) {
      const participant = oldContainer.querySelector(`[data-voice-user-id="${data.user_id}"]`)
      if (participant) participant.remove()
      if (!oldContainer.children.length) oldContainer.remove()
    }

    // Add participant to new channel's sidebar list
    const newChannelLink = this.element.querySelector(`a[data-channel-id="${data.to_channel_id}"]`)
    if (newChannelLink && data.html) {
      let newContainer = this.element.querySelector(`[data-voice-channel-participants="${data.to_channel_id}"]`)
      if (!newContainer) {
        newContainer = document.createElement("div")
        newContainer.className = "voice-participants"
        newContainer.dataset.voiceChannelParticipants = data.to_channel_id
        newChannelLink.insertAdjacentElement("afterend", newContainer)
      }
      if (!newContainer.querySelector(`[data-voice-user-id="${data.user_id}"]`)) {
        newContainer.insertAdjacentHTML("beforeend", data.html)
      }
    }

    // Update main voice view if viewing either channel
    const wrapper = document.querySelector("[data-current-channel-id]")
    if (wrapper) {
      const currentChannelId = wrapper.dataset.currentChannelId
      if (currentChannelId === data.from_channel_id) {
        // Remove card from old channel view
        const card = document.querySelector(`[data-voice-participant-id="${data.user_id}"]`)
        if (card) card.remove()
        this._showEmptyStateIfEmpty(wrapper)
      }
    }

    // If the moved user is the current user, dispatch force-move
    const currentUserId = document.body.dataset.currentUserId
    if (data.user_id === currentUserId) {
      window.dispatchEvent(new CustomEvent("voice:force-move", {
        detail: {
          toChannelId: data.to_channel_id,
          toChannelName: data.to_channel_name,
          voiceStateId: data.voice_state_id
        }
      }))
    }
  }

  _showEmptyStateIfEmpty(wrapper) {
    const gridContainer = document.querySelector("[data-voice-participant-grid]")
    const voiceGrid = gridContainer?.querySelector(".voice-grid")
    if (gridContainer && voiceGrid && voiceGrid.children.length === 0) {
      const channelName = wrapper.querySelector("h1")?.textContent || "Voice Channel"
      gridContainer.outerHTML = `
        <div class="flex-1 flex flex-col items-center justify-center p-8" data-voice-empty-state>
          <div class="w-24 h-24 rounded-full flex items-center justify-center mx-auto mb-6" style="background: rgba(255,255,255,0.05);">
            <svg class="w-12 h-12 text-gray-500" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M15.536 8.464a5 5 0 010 7.072M12 6v12m-3.536-2.464a5 5 0 010-7.072M18.364 5.636a9 9 0 010 12.728M5.636 18.364a9 9 0 010-12.728"/></svg>
          </div>
          <h2 class="text-xl font-bold text-white mb-1">${this.escapeHtml(channelName)}</h2>
          <p class="text-gray-500 text-sm">No one is in this channel yet.</p>
        </div>`
    }
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
