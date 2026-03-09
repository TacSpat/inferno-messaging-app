import { Controller } from "@hotwired/stimulus"
import consumer from "../lib/cable"
import Sortable from "sortablejs"

export default class extends Controller {
  static values = { serverId: String, autoJoinVoice: { type: Boolean, default: true }, canMoveMembers: { type: Boolean, default: false } }

  connect() {
    this.subscription = consumer.subscriptions.create(
      { channel: "ServerChannel", server_id: this.serverIdValue },
      {
        received: (data) => this.handleMessage(data)
      }
    )

    this._channelCache = new Map()  // channelId → DocumentFragment (live DOM nodes)
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
        this._cacheFrame(currentId, frame)
      }
    }
    document.addEventListener("turbo:before-frame-render", this._onBeforeFrameRender)

    // Keep _activeChannelId in sync after Turbo frame navigations we didn't intercept
    this._onFrameLoad = (e) => {
      if (e.target.id !== "main-content") return
      const newId = this._getCurrentChannelId(e.target)
      if (newId) this._activeChannelId = newId
    }
    document.addEventListener("turbo:frame-load", this._onFrameLoad)

    this._voiceSortables = []
    this._initVoiceSortables()

    // Reinit voice sortables after channel reorder (same element, both controllers)
    this._onReorderDone = () => this._initVoiceSortables()
    this.element.addEventListener("channel-reorder:done", this._onReorderDone)

    // Right-click context menu for creating channels/categories
    this._onContextMenu = this._handleContextMenu.bind(this)
    this.element.addEventListener("contextmenu", this._onContextMenu)
  }

  disconnect() {
    if (this.subscription) this.subscription.unsubscribe()
    this.element.removeEventListener("click", this._onChannelClick, true)
    this.element.removeEventListener("channel-reorder:done", this._onReorderDone)
    this.element.removeEventListener("contextmenu", this._onContextMenu)
    document.removeEventListener("turbo:before-frame-render", this._onBeforeFrameRender)
    document.removeEventListener("turbo:frame-load", this._onFrameLoad)
    this._channelCache.clear()
    this._destroyVoiceSortables()
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

  // Snapshot live DOM nodes from the frame into a DocumentFragment
  _cacheFrame(channelId, frame) {
    // Save scroll positions of scrollable containers before detaching
    const scrollData = []
    frame.querySelectorAll("#messages, #sidechat-messages").forEach(el => {
      if (el.scrollTop !== 0) scrollData.push({ id: el.id, top: el.scrollTop })
    })

    const fragment = document.createDocumentFragment()
    while (frame.firstChild) {
      fragment.appendChild(frame.firstChild)
    }
    this._channelCache.set(channelId, { fragment, scrollData })
    this._enforceCacheLimit()
  }

  // Restore cached DOM nodes back into the frame
  _restoreFrame(channelId, frame) {
    const cached = this._channelCache.get(channelId)
    if (!cached) return
    this._channelCache.delete(channelId)
    const { fragment, scrollData } = cached

    // Clear current contents
    while (frame.firstChild) {
      frame.removeChild(frame.firstChild)
    }
    // Move cached nodes back (images/videos already decoded — no pop-in)
    frame.appendChild(fragment)

    // Restore scroll positions
    requestAnimationFrame(() => {
      for (const { id, top } of scrollData) {
        const el = frame.querySelector(`#${id}`)
        if (el) el.scrollTop = top
      }
    })
  }

  _handleChannelClick(e) {
    // Chat button on voice channels: navigate without joining voice
    const chatBtn = e.target.closest("[data-channel-chat-btn]")
    if (chatBtn) {
      e.preventDefault()
      e.stopPropagation()
      const link = chatBtn.closest("a[data-channel-id]")
      if (link) {
        this._updateActiveChannel(link)
        const memberSidebar = document.getElementById("member-sidebar")
        if (memberSidebar) memberSidebar.classList.add("!hidden")
      }
      // Ensure sidechat opens when the view loads
      localStorage.setItem("sidechat-visible", "true")
      const frame = document.getElementById("main-content")
      if (frame) {
        const currentId = this._activeChannelId
        if (currentId) {
          this._cacheFrame(currentId, frame)
        }
        this._activeChannelId = chatBtn.dataset.channelChatBtn
        frame.src = chatBtn.dataset.href
      }
      return
    }

    const link = e.target.closest("a[data-channel-id]")
    if (!link) return

    const targetId = link.dataset.channelId
    const isVoice = link.dataset.voiceChannel === "true"
    // Detect same channel via tracked ID or visual state (fallback if _activeChannelId is stale)
    const sameChannel = targetId === this._activeChannelId || link.classList.contains("bg-gray-600")

    // Same channel — no-op (but voice channels still try to join below)
    if (sameChannel) {
      this._activeChannelId = targetId
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
        if (currentId) {
          this._cacheFrame(currentId, frame)
        }

        // Restore cached channel — move live DOM nodes back
        this._restoreFrame(targetId, frame)

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

    // Voice channels: join/switch
    if (isVoice) {
      const bar = document.getElementById("voice-controls-bar")
      const inCall = bar && !bar.classList.contains("hidden")

      if (inCall) {
        // Already in a call — switch to the new channel
        window.dispatchEvent(new CustomEvent("voice:join", {
          detail: { channelId: targetId, serverId: this.serverIdValue }
        }))
      } else if (this.autoJoinVoiceValue) {
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
      case "sidebar_refresh":
        this.refreshPage()
        break
      case "server_deleted":
        this.handleServerDeleted()
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
    if (data.channel_type === "voice") link.dataset.voiceChannel = "true"
    this._setChannelIcon(link.querySelector('[data-slot="icon"]'), data.channel_type)
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

    // Update icon if channel_type changed
    if (data.channel_type) {
      const iconSlot = existing.querySelector('[data-slot="icon"]')
      if (iconSlot) this._setChannelIcon(iconSlot, data.channel_type)
      if (data.channel_type === "voice") existing.dataset.voiceChannel = "true"
      else delete existing.dataset.voiceChannel
    }

    // Move to new category if category_id changed
    if (data.category_id !== undefined) {
      const currentParent = existing.closest("[data-category-id]")
      const currentCatId = currentParent?.dataset.categoryId || null

      if (data.category_id !== currentCatId) {
        if (data.category_id) {
          const targetCat = this.element.querySelector(`[data-category-id="${data.category_id}"]`)
          const channelsDiv = targetCat?.querySelector("[data-category-collapse-target='channels']")
          if (channelsDiv) channelsDiv.appendChild(existing)
        } else {
          // Moved to uncategorized — place before first category
          const firstCategory = this.element.querySelector("[data-category-id]")
          if (firstCategory) firstCategory.before(existing)
          else this.element.appendChild(existing)
        }
      }
    }
  }

  removeChannel(data) {
    const el = this.element.querySelector(`[data-channel-id="${data.channel_id}"]`)
    if (el) el.remove()

    // If the user is currently viewing the deleted channel, navigate to the first available channel
    if (this._activeChannelId === data.channel_id) {
      const firstChannel = this.element.querySelector("a[data-channel-id]")
      if (firstChannel) {
        window.Turbo?.visit(firstChannel.getAttribute("href"), { action: "replace" })
      } else {
        window.Turbo?.visit("/", { action: "replace" })
      }
    }
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
    // If this client just performed a drag-reorder, DOM is already correct — skip
    if (window._skipNextSidebarReorder && Date.now() - window._skipNextSidebarReorder < 5000) {
      return
    }

    const { channels, categories } = data

    if (!channels?.length && !categories?.length) return

    const rootChannels = (channels || []).filter(ch => !ch.parent_channel_id && !ch.category_id)
    const nestedChannels = (channels || []).filter(ch => ch.parent_channel_id)
    const categorizedByGroup = {}
    ;(channels || []).filter(ch => ch.category_id && !ch.parent_channel_id).forEach(ch => {
      if (!categorizedByGroup[ch.category_id]) categorizedByGroup[ch.category_id] = []
      categorizedByGroup[ch.category_id].push(ch)
    })
    Object.values(categorizedByGroup).forEach(g => g.sort((a, b) => a.position - b.position))

    // Build interleaved root items: uncategorized channels + categories, sorted by position
    const rootItems = []
    rootChannels.forEach(ch => rootItems.push({ type: "channel", id: ch.id, position: ch.position }))
    ;(categories || []).forEach(cat => rootItems.push({ type: "category", id: cat.id, position: cat.position }))
    rootItems.sort((a, b) => a.position - b.position)

    // Reorder root-level items in DOM order
    rootItems.forEach(item => {
      if (item.type === "category") {
        const el = this.element.querySelector(`[data-category-id="${item.id}"]`)
        if (el) this.element.appendChild(el)
      } else {
        this._moveChannelGroup(item.id, el => this.element.appendChild(el))
      }
    })

    // Place categorized channels inside their categories
    Object.entries(categorizedByGroup).forEach(([catId, group]) => {
      const catEl = this.element.querySelector(`[data-category-id="${catId}"]`)
      if (!catEl) return
      const container = catEl.querySelector("[data-category-collapse-target='channels']")
      if (!container) return
      group.forEach(ch => {
        this._moveChannelGroup(ch.id, el => container.appendChild(el))
      })
    })

    // Place nested channels inside their parent's voice-child-channels
    nestedChannels.sort((a, b) => a.position - b.position).forEach(ch => {
      const parentLink = this.element.querySelector(`[data-channel-id="${ch.parent_channel_id}"]`)
      if (!parentLink) return
      let childContainer = this.element.querySelector(
        `.voice-child-channels[data-parent-channel="${ch.parent_channel_id}"]`
      )
      if (!childContainer) {
        childContainer = document.createElement("div")
        childContainer.className = "voice-child-channels"
        childContainer.dataset.parentChannel = ch.parent_channel_id
        const participants = this.element.querySelector(
          `.voice-participants[data-voice-channel-participants="${ch.parent_channel_id}"]`
        )
        ;(participants || parentLink).after(childContainer)
      }
      this._moveChannelGroup(ch.id, el => childContainer.appendChild(el))
    })

    this._initVoiceSortables()
  }

  // Move a channel's <a> tag plus its voice-participants and voice-child-channels
  // as an atomic group. The placeFn receives each element to place in the DOM.
  _moveChannelGroup(channelId, placeFn) {
    const el = this.element.querySelector(`[data-channel-id="${channelId}"]`)
    if (!el) return
    const parts = [el]
    const participants = this.element.querySelector(
      `.voice-participants[data-voice-channel-participants="${channelId}"]`
    )
    if (participants) parts.push(participants)
    const childContainer = this.element.querySelector(
      `.voice-child-channels[data-parent-channel="${channelId}"]`
    )
    if (childContainer) parts.push(childContainer)
    parts.forEach(p => placeFn(p))
  }

  refreshPage() {
    // Full page refresh to re-run server-side visibility checks
    window.Turbo?.visit(window.location.href, { action: "replace" })
  }

  handleServerDeleted() {
    window.Turbo?.visit("/", { action: "replace" })
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
      if (!container.querySelector(`[data-voice-user-id="${data.user_id}"]`)) {
        container.appendChild(this._buildSidebarParticipant(data))
      }
    }

    // Update main voice view participant grid (if viewing this channel)
    // Use querySelectorAll to update both desktop and mobile grids
    const wrapper = document.querySelector("[data-current-channel-id]")
    if (wrapper?.dataset.currentChannelId === data.channel_id) {
      const color = data.profile_color || "#1e1c1b"

      // Handle empty states (both desktop and mobile)
      document.querySelectorAll("[data-voice-empty-state]").forEach(emptyState => {
        const cardEl = this._buildVoiceCard(data, color)
        const gridOuter = document.createElement("div")
        gridOuter.className = "flex-1 p-3 overflow-y-auto"
        gridOuter.dataset.voiceParticipantGrid = ""
        const gridInner = document.createElement("div")
        gridInner.className = "voice-grid h-full"
        gridInner.appendChild(cardEl)
        gridOuter.appendChild(gridInner)
        emptyState.replaceWith(gridOuter)
      })

      // Handle existing grids (both desktop and mobile)
      document.querySelectorAll("[data-voice-participant-grid]").forEach(gridContainer => {
        const grid = gridContainer.querySelector(".voice-grid") || gridContainer
        if (!grid.querySelector(`[data-voice-participant-id="${data.user_id}"]`)) {
          grid.appendChild(this._buildVoiceCard(data, color))
        }
      })
    }

    // For the current user: swap join button and show voice controls bar
    const currentUserId = document.body.dataset.currentUserId
    if (data.user_id === currentUserId) {
      // Swap "Join Voice" button → "You're connected" text
      const joinBtn = document.querySelector("[data-voice-join-btn]")
      if (joinBtn) {
        joinBtn.outerHTML = '<p class="text-green-400 text-sm font-medium" data-voice-connected-text>You\'re connected to this voice channel</p>'
      }

      // Show voice controls bar (sidebar + mobile)
      const bar = document.getElementById("voice-controls-bar")
      if (bar) {
        bar.classList.remove("hidden")
        const channelNameEl = bar.querySelector("[data-voice-channel-target='channelName']")
        if (channelNameEl) {
          const name = document.querySelector(`a[data-channel-id="${data.channel_id}"] span.truncate`)?.textContent || "Voice"
          channelNameEl.textContent = name
        }
      }
      const mobileBar = document.getElementById("mobile-voice-controls")
      if (mobileBar) mobileBar.classList.remove("hidden")
    }

    this._updateLinkedVoiceBanner(data.channel_id, 1)
    this._initVoiceSortables()
  }

  handleVoiceLeave(data) {
    // Update sidebar participant list
    const container = this.element.querySelector(`[data-voice-channel-participants="${data.channel_id}"]`)
    if (container) {
      const participant = container.querySelector(`[data-voice-user-id="${data.user_id}"]`)
      if (participant) participant.remove()
      if (!container.children.length) container.remove()
    }

    // Update main voice view participant grids (both desktop and mobile)
    const wrapper = document.querySelector("[data-current-channel-id]")
    if (wrapper?.dataset.currentChannelId === data.channel_id) {
      document.querySelectorAll(`[data-voice-participant-id="${data.user_id}"]`).forEach(card => card.remove())

      // Show empty state if grids are now empty
      this._showEmptyStateIfEmpty(wrapper)
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
      const mobileBar = document.getElementById("mobile-voice-controls")
      if (mobileBar) mobileBar.classList.add("hidden")
    }

    this._updateLinkedVoiceBanner(data.channel_id, -1)
    this._initVoiceSortables()
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

        // Toggle broadcast badge on avatar
        const avatarWrap = participant.querySelector(".relative")
        if (avatarWrap) {
          const existingBadge = avatarWrap.querySelector(".voice-broadcast-badge")
          if (data.broadcasting && !existingBadge) {
            avatarWrap.insertAdjacentHTML("beforeend", this._broadcastBadgeHtml())
          } else if (!data.broadcasting && existingBadge) {
            existingBadge.remove()
          }
        }
      }

      // Update main voice view card status icons (both desktop and mobile grids)
      document.querySelectorAll(`[data-voice-participant-id="${data.user_id}"]`).forEach(card => {
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
      })
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

    // Remove card from main voice view (both desktop and mobile)
    const wrapper = document.querySelector("[data-current-channel-id]")
    if (wrapper?.dataset.currentChannelId === data.channel_id) {
      document.querySelectorAll(`[data-voice-participant-id="${data.user_id}"]`).forEach(card => card.remove())
      this._showEmptyStateIfEmpty(wrapper)
    }

    // If the kicked user is the current user, dispatch force-disconnect
    const currentUserId = document.body.dataset.currentUserId
    if (data.user_id === currentUserId) {
      window.dispatchEvent(new CustomEvent("voice:force-disconnect"))
      if (data.reason === "afk") {
        this._showToast("You were disconnected for being AFK")
      }
    }
  }

  handleVoiceMoved(data) {
    // Remove participant from ALL channel sidebar lists
    // (handles both normal broadcast and SortableJS drag which already moved the element)
    this.element.querySelectorAll(`[data-voice-user-id="${data.user_id}"]`).forEach(el => {
      const container = el.closest("[data-voice-channel-participants]")
      el.remove()
      if (container && !container.children.length) container.remove()
    })

    // Add participant to new channel's sidebar list (fresh element with correct channel_id)
    const newChannelLink = this.element.querySelector(`a[data-channel-id="${data.to_channel_id}"]`)
    if (newChannelLink) {
      let newContainer = this.element.querySelector(`[data-voice-channel-participants="${data.to_channel_id}"]`)
      if (!newContainer) {
        newContainer = document.createElement("div")
        newContainer.className = "voice-participants"
        newContainer.dataset.voiceChannelParticipants = data.to_channel_id
        newChannelLink.insertAdjacentElement("afterend", newContainer)
      }
      const rowData = { ...data, channel_id: data.to_channel_id }
      newContainer.appendChild(this._buildSidebarParticipant(rowData))
    }

    // Update main voice view if viewing either channel (both desktop and mobile grids)
    const wrapper = document.querySelector("[data-current-channel-id]")
    if (wrapper) {
      const currentChannelId = wrapper.dataset.currentChannelId
      if (currentChannelId === data.from_channel_id) {
        // Remove card from old channel view (all grids)
        document.querySelectorAll(`[data-voice-participant-id="${data.user_id}"]`).forEach(card => card.remove())
        this._showEmptyStateIfEmpty(wrapper)
      } else if (currentChannelId === data.to_channel_id) {
        // Add card to new channel view (all grids)
        const color = data.profile_color || "#1e1c1b"

        document.querySelectorAll("[data-voice-empty-state]").forEach(emptyState => {
          const cardEl = this._buildVoiceCard(data, color)
          const gridOuter = document.createElement("div")
          gridOuter.className = "flex-1 p-3 overflow-y-auto"
          gridOuter.dataset.voiceParticipantGrid = ""
          const gridInner = document.createElement("div")
          gridInner.className = "voice-grid h-full"
          gridInner.appendChild(cardEl)
          gridOuter.appendChild(gridInner)
          emptyState.replaceWith(gridOuter)
        })

        document.querySelectorAll("[data-voice-participant-grid]").forEach(gridContainer => {
          const grid = gridContainer.querySelector(".voice-grid") || gridContainer
          if (!grid.querySelector(`[data-voice-participant-id="${data.user_id}"]`)) {
            grid.appendChild(this._buildVoiceCard(data, color))
          }
        })
      }
    }

    // If the moved user is the current user, dispatch force-move and navigate
    const currentUserId = document.body.dataset.currentUserId
    if (data.user_id === currentUserId) {
      window.dispatchEvent(new CustomEvent("voice:force-move", {
        detail: {
          toChannelId: data.to_channel_id,
          toChannelName: data.to_channel_name,
          voiceStateId: data.voice_state_id,
          afk: data.afk
        }
      }))
      if (data.afk) {
        this._showToast("You were moved to AFK")
      }
      // Navigate to the new channel's view
      const newChannelLink = this.element.querySelector(`a[data-channel-id="${data.to_channel_id}"]`)
      if (newChannelLink) newChannelLink.click()
    }

    this._initVoiceSortables()
  }

  _showEmptyStateIfEmpty(wrapper) {
    const channelName = wrapper.querySelector("h1")?.textContent || "Voice Channel"
    document.querySelectorAll("[data-voice-participant-grid]").forEach(gridContainer => {
      const voiceGrid = gridContainer.querySelector(".voice-grid")
      if (voiceGrid && voiceGrid.children.length === 0) {
        gridContainer.replaceWith(this._buildVoiceEmptyState(channelName))
      }
    })
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

  _updateLinkedVoiceBanner(voiceChannelId, delta) {
    const banner = document.querySelector(`[data-linked-voice-banner="${voiceChannelId}"]`)
    if (!banner) return

    const oldCount = parseInt(banner.dataset.linkedVoiceCount || "0", 10)
    const newCount = Math.max(0, oldCount + delta)
    banner.dataset.linkedVoiceCount = newCount

    const name = banner.dataset.linkedVoiceName
    const href = banner.dataset.linkedVoiceHref

    if (newCount > 0) {
      banner.querySelector("[data-linked-voice-inner]").outerHTML = `
        <div class="bg-accent/10 border-b border-accent/20 px-4 py-2 flex items-center gap-2 shrink-0" data-linked-voice-inner>
          <svg class="w-4 h-4 text-accent-light shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.536 8.464a5 5 0 010 7.072M12 6v12m-3.536-2.464a5 5 0 010-7.072M18.364 5.636a9 9 0 010 12.728M5.636 18.364a9 9 0 010-12.728"/></svg>
          <span class="text-sm text-accent-light">
            <strong>${name}</strong> is live &mdash; <span data-linked-voice-count-text>${newCount}</span> in voice
          </span>
          <a href="${href}"
             class="text-xs text-accent hover:underline ml-auto"
             onclick="event.preventDefault(); const sl = document.querySelector('a[data-channel-id=&quot;${voiceChannelId}&quot;]'); if (sl) { sl.click(); } else { Turbo.visit(this.href); }">Join</a>
        </div>`
    } else {
      banner.querySelector("[data-linked-voice-inner]").outerHTML = `
        <div class="border-b border-gray-800 px-4 py-1.5 flex items-center gap-1.5 shrink-0" data-linked-voice-inner>
          <svg class="w-3.5 h-3.5 text-gray-500 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"/></svg>
          <span class="text-xs text-gray-500">
            Linked to <a href="${href}"
                         class="text-gray-400 hover:text-gray-300 hover:underline"
                         onclick="event.preventDefault(); const sl = document.querySelector('a[data-channel-id=&quot;${voiceChannelId}&quot;]'); if (sl) { sl.click(); } else { Turbo.visit(this.href); }">${name}</a>
          </span>
        </div>`
    }
  }

  _buildSidebarParticipant(data) {
    const row = document.createElement("div")
    row.className = "flex items-center py-0.5 pl-6 pr-2 rounded hover:bg-gray-700/50 group"
    row.dataset.voiceUserId = data.user_id
    row.dataset.voiceStateId = data.voice_state_id || ""

    const avatarWrap = document.createElement("div")
    avatarWrap.className = "relative"

    if (data.avatar_url) {
      const img = document.createElement("img")
      img.src = data.avatar_url
      img.className = "w-5 h-5 rounded-full object-cover voice-sidebar-avatar"
      img.loading = "lazy"
      avatarWrap.appendChild(img)
    } else {
      const fb = document.createElement("div")
      fb.className = "w-5 h-5 rounded-full flex items-center justify-center text-[10px] font-bold text-white voice-sidebar-avatar"
      fb.style.backgroundColor = data.profile_color || "#1e1c1b"
      fb.textContent = (data.username?.[0] || "?").toUpperCase()
      avatarWrap.appendChild(fb)
    }

    if (data.broadcasting) {
      avatarWrap.insertAdjacentHTML("beforeend", this._broadcastBadgeHtml())
    }

    row.appendChild(avatarWrap)

    const name = document.createElement("span")
    name.className = "ml-1.5 text-xs text-gray-300 truncate flex-1"
    name.textContent = data.username || "Unknown"
    row.appendChild(name)

    if (data.self_mute) {
      name.insertAdjacentHTML("afterend", '<svg class="voice-mute-icon w-3 h-3 text-gray-500 ml-1 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"/></svg>')
    }
    if (data.self_deaf) {
      name.insertAdjacentHTML("afterend", '<svg class="voice-deaf-icon w-3 h-3 text-gray-500 ml-1 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728L5.636 5.636"/></svg>')
    }

    return row
  }

  _broadcastBadgeHtml() {
    return '<div class="voice-broadcast-badge" title="Broadcasting to children"><svg class="w-1.5 h-1.5 text-white" fill="none" stroke="currentColor" stroke-width="3" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M11 5.882V19.24a1.76 1.76 0 01-3.417.592l-2.147-6.15M18 13a3 3 0 100-6M5.436 13.683A4.001 4.001 0 017 6h1.832c4.1 0 7.625-1.234 9.168-3v14c-1.543-1.766-5.067-3-9.168-3H7a3.988 3.988 0 01-1.564-.317z"/></svg></div>'
  }

  _buildVoiceEmptyState(channelName) {
    const tpl = document.getElementById("tpl-voice-empty-state").content.cloneNode(true)
    tpl.querySelector('[data-slot="channel-name"]').textContent = channelName
    return tpl.firstElementChild
  }

  _setChannelIcon(slot, channelType) {
    if (channelType === "voice") {
      slot.className = "mr-1.5 opacity-60 shrink-0"
      slot.innerHTML = '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.536 8.464a5 5 0 010 7.072M18.364 5.636a9 9 0 010 12.728M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/></svg>'
    } else {
      slot.className = "text-lg mr-1.5 opacity-60"
      slot.innerHTML = ""
      slot.textContent = "#"
    }
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

  // ─── Voice participant drag-and-drop ───────────────────────

  _initVoiceSortables() {
    this._destroyVoiceSortables()
    if (!this.canMoveMembersValue) return

    // Ensure every voice channel has a drop target container
    this.element.querySelectorAll("a[data-voice-channel]").forEach(link => {
      const channelId = link.dataset.channelId
      if (!this.element.querySelector(`[data-voice-channel-participants="${channelId}"]`)) {
        const container = document.createElement("div")
        container.className = "voice-participants"
        container.dataset.voiceChannelParticipants = channelId
        link.insertAdjacentElement("afterend", container)
      }
    })

    this.element.querySelectorAll("[data-voice-channel-participants]").forEach(container => {
      const sortable = Sortable.create(container, {
        group: "voice-participants",
        animation: 150,
        ghostClass: "opacity-20",
        chosenClass: "bg-gray-600",
        dragClass: "shadow-lg",
        fallbackOnBody: true,
        draggable: "[data-voice-user-id]:not([data-voice-remote])",
        onEnd: (evt) => this._handleVoiceParticipantDrop(evt)
      })
      this._voiceSortables.push(sortable)
    })
  }

  _destroyVoiceSortables() {
    if (this._voiceSortables) {
      this._voiceSortables.forEach(s => s.destroy())
      this._voiceSortables = []
    }
  }

  async _handleVoiceParticipantDrop(evt) {
    const item = evt.item
    const fromContainer = evt.from
    const toContainer = evt.to
    if (!toContainer || fromContainer === toContainer) return

    const userId = item.dataset.voiceUserId
    const fromChannelId = fromContainer.dataset.voiceChannelParticipants
    const toChannelId = toContainer.dataset.voiceChannelParticipants
    if (!userId || !toChannelId) return

    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    try {
      const response = await fetch(`/servers/${this.serverIdValue}/voice/move/${userId}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({ channel_id: toChannelId })
      })
      if (!response.ok) {
        // Revert: the broadcast won't arrive, so move item back.
        // Containers may have changed during await — re-query by channel ID.
        const origContainer = this.element.querySelector(`[data-voice-channel-participants="${fromChannelId}"]`)
        if (origContainer && item.parentNode) {
          origContainer.appendChild(item)
        }
        this._initVoiceSortables()
      }
    } catch (e) {
      console.warn("[ChannelSidebar] Voice move failed:", e)
      const origContainer = this.element.querySelector(`[data-voice-channel-participants="${fromChannelId}"]`)
      if (origContainer && item.parentNode) {
        origContainer.appendChild(item)
      }
      this._initVoiceSortables()
    }
  }

  _showToast(message) {
    const toast = document.createElement("div")
    toast.className = "fixed bottom-6 left-1/2 -translate-x-1/2 bg-gray-800 border border-gray-600 text-white text-sm px-4 py-2 rounded-lg shadow-lg z-50 transition-opacity duration-300"
    toast.textContent = message
    document.body.appendChild(toast)
    setTimeout(() => {
      toast.style.opacity = "0"
      setTimeout(() => toast.remove(), 300)
    }, 3000)
  }

  // --- Right-click context menu for channel/category creation ---

  _handleContextMenu(e) {
    // Only show if user has manage_channels permission
    const canManage = this.element.dataset.channelReorderCanManageValue === "true"
    if (!canManage) return

    // Don't override context menu on channel links themselves
    const channelLink = e.target.closest("[data-channel-id]")
    if (channelLink) return

    e.preventDefault()

    // Determine insertion context from click location
    const { categoryId, position } = this._getInsertionPoint(e.target, e.clientY)
    const serverId = this.serverIdValue

    const items = [
      {
        icon: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/></svg>',
        label: "Create Channel",
        action: () => {
          let url = `/servers/${serverId}/channels/new?`
          if (categoryId) url += `category_id=${categoryId}&`
          if (position !== null) url += `position=${position}`
          window.Turbo.visit(url)
        }
      },
      {
        icon: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"/></svg>',
        label: "Create Category",
        action: () => {
          // Category position based on which category area we're in
          const catPosition = this._getCategoryInsertionPosition(e.target, e.clientY)
          let url = `/servers/${serverId}/categories/new`
          if (catPosition !== null) url += `?position=${catPosition}`
          window.Turbo.visit(url)
        }
      }
    ]

    this._renderSidebarContextMenu(e.clientX, e.clientY, items)
  }

  _getInsertionPoint(target, clientY) {
    // Check if we're inside a category
    const categoryEl = target.closest("[data-category-id]")
    const categoryId = categoryEl?.dataset.categoryId || null

    // Find the nearest channel above the click point within the same scope
    let position = null
    const scope = categoryEl
      ? categoryEl.querySelector("[data-category-collapse-target='channels']")
      : this.element

    if (scope) {
      const channels = scope.querySelectorAll(":scope > [data-channel-id]")
      let insertAfter = -1
      for (const ch of channels) {
        const rect = ch.getBoundingClientRect()
        if (rect.bottom <= clientY) {
          const pos = parseInt(ch.dataset.channelPosition, 10)
          if (!isNaN(pos) && pos > insertAfter) insertAfter = pos
        }
      }
      position = insertAfter + 1
    }

    return { categoryId, position }
  }

  _getCategoryInsertionPosition(target, clientY) {
    const categories = this.element.querySelectorAll("[data-category-id]")
    let insertAfter = -1
    for (const cat of categories) {
      const rect = cat.getBoundingClientRect()
      if (rect.top <= clientY) {
        const pos = parseInt(cat.dataset.categoryPosition, 10)
        if (!isNaN(pos) && pos > insertAfter) insertAfter = pos
      }
    }
    return insertAfter + 1
  }

  _renderSidebarContextMenu(x, y, items) {
    // Remove existing context menu
    document.getElementById("sidebar-context-menu")?.remove()

    const menu = document.createElement("div")
    menu.id = "sidebar-context-menu"
    menu.className = "fixed z-[100] bg-gray-900 border border-gray-700 rounded-lg shadow-xl py-1 min-w-[180px]"
    menu.style.cssText = `left:${x}px;top:${y}px`

    items.forEach(item => {
      const btn = document.createElement("button")
      btn.className = "w-full flex items-center px-3 py-2 text-sm text-gray-300 hover:bg-accent/20 hover:text-white transition cursor-pointer"
      btn.innerHTML = `${item.icon}<span>${item.label}</span>`
      btn.addEventListener("click", () => {
        menu.remove()
        item.action()
      })
      menu.appendChild(btn)
    })

    document.body.appendChild(menu)

    // Adjust position if overflowing viewport
    const rect = menu.getBoundingClientRect()
    if (rect.right > window.innerWidth) menu.style.left = `${window.innerWidth - rect.width - 8}px`
    if (rect.bottom > window.innerHeight) menu.style.top = `${window.innerHeight - rect.height - 8}px`

    // Close on click outside or Escape
    const close = (e) => {
      if (e.type === "keydown" && e.key !== "Escape") return
      menu.remove()
      document.removeEventListener("click", close)
      document.removeEventListener("keydown", close)
      document.removeEventListener("contextmenu", close)
    }
    setTimeout(() => {
      document.addEventListener("click", close)
      document.addEventListener("keydown", close)
      document.addEventListener("contextmenu", close)
    }, 0)
  }
}
