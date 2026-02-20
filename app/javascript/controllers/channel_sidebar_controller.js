import { Controller } from "@hotwired/stimulus"
import consumer from "../lib/cable"

export default class extends Controller {
  static values = { serverId: String, autoJoinVoice: { type: Boolean, default: true } }

  connect() {
    this.subscription = consumer.subscriptions.create(
      { channel: "ServerChannel", server_id: this.serverIdValue },
      {
        received: (data) => this.handleMessage(data)
      }
    )

    this._channelCache = new Map()
    this._activeChannelId = this._getCurrentChannelId(document.getElementById("main-content"))

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
    const isVoice = link.dataset.voiceChannel === "true"
    const sameChannel = targetId === this._activeChannelId

    // Same channel — no-op (but voice channels still try to join below)
    if (sameChannel) {
      e.preventDefault()
      e.stopPropagation()
      if (!isVoice) return
    }

    if (!sameChannel) {
      const frame = document.getElementById("main-content")
      const currentId = this._activeChannelId || this._getCurrentChannelId(frame)

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

      // Update active channel styling
      this._updateActiveChannel(link)
    }

    // Toggle member sidebar: hide for voice, respect user preference for text
    const memberSidebar = document.getElementById("member-sidebar")
    if (memberSidebar) {
      if (isVoice) {
        memberSidebar.classList.add("!hidden")
      } else if (localStorage.getItem("members_hidden") !== "1") {
        memberSidebar.classList.remove("!hidden")
      }
    }

    // Voice channels: join if not already in a call
    if (isVoice) {
      const bar = document.getElementById("voice-controls-bar")
      const inCall = bar && !bar.classList.contains("hidden")
      if (inCall) return

      if (this.autoJoinVoiceValue) {
        window.dispatchEvent(new CustomEvent("voice:join", {
          detail: { channelId: targetId, serverId: this.serverIdValue }
        }))
      } else {
        const name = link.querySelector(".truncate")?.textContent?.trim() || "this channel"
        if (confirm(`Join voice channel "${name}"?`)) {
          window.dispatchEvent(new CustomEvent("voice:join", {
            detail: { channelId: targetId, serverId: this.serverIdValue }
          }))
        }
      }
    }
  }

  _updateActiveChannel(link) {
    this._activeChannelId = link.dataset.channelId
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

  buildChannelEl(data) {
    const tpl = document.getElementById("tpl-sidebar-channel").content.cloneNode(true)
    const link = tpl.querySelector("a")
    link.href = `/servers/${this.serverIdValue}/channels/${data.channel_id}`
    link.dataset.channelId = data.channel_id
    this._setNameWithEmojis(link.querySelector('[data-slot="name"]'), data.name)
    return link
  }

  addChannel(data) {
    // Don't add if already exists
    if (this.element.querySelector(`[data-channel-id="${data.channel_id}"]`)) return
    const el = this.buildChannelEl(data)

    if (data.category_id) {
      const categoryEl = this.element.querySelector(`[data-category-id="${data.category_id}"]`)
      if (categoryEl) {
        const channelsDiv = categoryEl.querySelector("[data-category-collapse-target='channels']")
        if (channelsDiv) {
          channelsDiv.appendChild(el)
          return
        }
      }
    }
    const firstCategory = this.element.querySelector("[data-category-id]")
    if (firstCategory) {
      firstCategory.before(el)
    } else {
      this.element.appendChild(el)
    }
  }

  updateChannel(data) {
    const existing = this.element.querySelector(`[data-channel-id="${data.channel_id}"]`)
    if (!existing) return
    const nameSpan = existing.querySelector(".truncate")
    if (nameSpan && data.name) this._setNameWithEmojis(nameSpan, data.name)
  }

  removeChannel(data) {
    const el = this.element.querySelector(`[data-channel-id="${data.channel_id}"]`)
    if (el) el.remove()
  }

  buildCategoryEl(data) {
    const tpl = document.getElementById("tpl-sidebar-category").content.cloneNode(true)
    const wrapper = tpl.querySelector(".mb-1")
    wrapper.dataset.controller = "category-collapse"
    wrapper.dataset.categoryCollapseIdValue = data.category_id
    wrapper.dataset.categoryId = data.category_id
    this._setNameWithEmojis(wrapper.querySelector('[data-slot="name"]'), data.name)
    return wrapper
  }

  addCategory(data) {
    if (this.element.querySelector(`[data-category-id="${data.category_id}"]`)) return
    const el = this.buildCategoryEl(data)
    this.element.appendChild(el)
  }

  updateCategory(data) {
    const el = this.element.querySelector(`[data-category-id="${data.category_id}"]`)
    if (el && data.name) {
      const nameSpan = el.querySelector(".uppercase.tracking-wide")
      if (nameSpan) this._setNameWithEmojis(nameSpan, data.name)
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

      const color = data.profile_color || "#1e1c1b"
      const cardEl = this._buildVoiceCard(data, color)

      if (emptyState) {
        const gridOuter = document.createElement("div")
        gridOuter.className = "flex-1 p-3 overflow-y-auto"
        gridOuter.dataset.voiceParticipantGrid = ""
        const gridInner = document.createElement("div")
        gridInner.className = "voice-grid h-full"
        gridInner.appendChild(cardEl)
        gridOuter.appendChild(gridInner)
        emptyState.replaceWith(gridOuter)
      } else if (gridContainer) {
        const grid = gridContainer.querySelector(".voice-grid") || gridContainer
        if (!grid.querySelector(`[data-voice-participant-id="${data.user_id}"]`)) {
          grid.appendChild(cardEl)
        }
      }
    }

    // For the current user: swap join button and show voice controls bar
    const currentUserId = document.body.dataset.currentUserId
    if (data.user_id === currentUserId) {
      // Swap "Join Voice" button → "You're connected" text
      const joinBtn = document.querySelector("[data-voice-join-btn]")
      if (joinBtn) {
        joinBtn.outerHTML = '<p class="text-green-400 text-sm font-medium" data-voice-connected-text>You\'re connected to this voice channel</p>'
      }

      // Show voice controls bar
      const bar = document.getElementById("voice-controls-bar")
      if (bar) {
        bar.classList.remove("hidden")
        const channelNameEl = bar.querySelector("[data-voice-channel-target='channelName']")
        if (channelNameEl) {
          const name = document.querySelector(`a[data-channel-id="${data.channel_id}"] span.truncate`)?.textContent || "Voice"
          channelNameEl.textContent = name
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
        gridContainer.replaceWith(this._buildVoiceEmptyState(channelName))
      }
    }

    // For the current user: swap connected text back to join button and hide controls bar
    const currentUserId = document.body.dataset.currentUserId
    if (data.user_id === currentUserId) {
      const connectedText = document.querySelector("[data-voice-connected-text]")
      if (connectedText && wrapper) {
        const channelId = wrapper.dataset.currentChannelId || ""
        const serverId = wrapper.dataset.currentServerId || ""
        connectedText.outerHTML = `
          <button type="button"
                  class="px-6 py-2.5 bg-green-600 hover:bg-green-500 text-white font-semibold rounded-full transition flex items-center gap-2 cursor-pointer text-sm"
                  data-voice-join-btn
                  onclick="window.dispatchEvent(new CustomEvent('voice:join', { detail: { channelId: '${channelId}', serverId: '${serverId}' } }))">
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.536 8.464a5 5 0 010 7.072M12 6v12m-3.536-2.464a5 5 0 010-7.072"/></svg>
            Join Voice
          </button>`
      }

      const bar = document.getElementById("voice-controls-bar")
      if (bar) bar.classList.add("hidden")
    }
  }

  handleVoiceUpdate(data) {
    const currentUserId = document.body.dataset.currentUserId

    // For the current user, voice_channel_controller._updateSelfVoiceIndicators()
    // is the source of truth. Skip broadcast-driven icon updates to avoid race
    // conditions (e.g. mute broadcast arriving after a local deafen toggle).
    if (data.user_id !== currentUserId) {
      // Update sidebar participant icons
      const participant = this.element.querySelector(`[data-voice-user-id="${data.user_id}"]`)
      if (participant) {
        participant.querySelectorAll(".voice-mute-icon, .voice-deaf-icon, .voice-server-mute-icon, .voice-server-deaf-icon").forEach(el => el.remove())

        const nameSpan = participant.querySelector("span")
        if (data.server_mute && nameSpan) {
          nameSpan.insertAdjacentHTML("afterend", '<svg class="voice-server-mute-icon w-3 h-3 text-red-400 ml-1 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/><line x1="3" y1="3" x2="21" y2="21" stroke-width="2" stroke-linecap="round"/></svg>')
        } else if (data.self_mute && nameSpan) {
          nameSpan.insertAdjacentHTML("afterend", '<svg class="voice-mute-icon w-3 h-3 text-gray-500 ml-1 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"/></svg>')
        }
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
    }

    // Server moderation events still dispatched for the current user
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
      gridContainer.replaceWith(this._buildVoiceEmptyState(channelName))
    }
  }

  _buildVoiceCard(data, color) {
    const tpl = document.getElementById("tpl-voice-card").content.cloneNode(true)
    const card = tpl.querySelector(".voice-card")
    card.dataset.voiceParticipantId = data.user_id
    card.dataset.voiceStateId = data.voice_state_id || ""
    card.dataset.action = "contextmenu->voice-context#show"
    card.style.setProperty("--card-color", color)

    const initial = data.username?.[0]?.toUpperCase() || "?"
    const avatarSlot = card.querySelector('[data-slot="avatar"]')
    if (data.avatar_url) {
      const img = document.createElement("img")
      img.src = data.avatar_url
      img.className = "voice-avatar"
      avatarSlot.appendChild(img)
    } else {
      const fallback = document.createElement("div")
      fallback.className = "voice-avatar-fallback"
      fallback.style.backgroundColor = `color-mix(in srgb, ${color}, white 20%)`
      fallback.textContent = initial
      avatarSlot.appendChild(fallback)
    }

    card.querySelector('[data-slot="username"]').textContent = data.username
    return card
  }

  _buildVoiceEmptyState(channelName) {
    const tpl = document.getElementById("tpl-voice-empty-state").content.cloneNode(true)
    tpl.querySelector('[data-slot="channel-name"]').textContent = channelName
    return tpl.firstElementChild
  }

  _setNameWithEmojis(el, name) {
    if (!name || !name.includes(":") || !window._emojiMap) {
      el.textContent = name || ""
      return
    }
    const escaped = name.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    const html = escaped.replace(/:([a-z0-9_]+):/g, (match, n) => {
      const url = window._emojiMap[n]
      if (url) return `<img src="${url}" alt="${match}" style="height:1.2em;width:1.2em;object-fit:contain;vertical-align:middle;display:inline" loading="lazy">`
      return match
    })
    if (html !== escaped) el.innerHTML = html
    else el.textContent = name
  }
}
