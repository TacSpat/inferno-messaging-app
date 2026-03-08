import { Controller } from "@hotwired/stimulus"
import consumer from "../lib/cable"
import { positionPopup } from "../utils/popup_positioning"

export default class extends Controller {
  connect() {
    this.subscription = consumer.subscriptions.create(
      { channel: "NotificationChannel" },
      {
        received: (data) => this.handleNotification(data)
      }
    )

    this.clearCurrentChannelBadges()
    this._restoreLastChannels()
    this.sidebarTyping = new Map()

    this.handleContextMenu = this.handleContextMenu.bind(this)
    document.addEventListener("contextmenu", this.handleContextMenu)

    this.closeMenu = this.closeMenu.bind(this)
    document.addEventListener("click", this.closeMenu)

    // User card click handler (message avatars/usernames)
    this._handleUserCardClick = (e) => this._onUserCardClick(e)
    document.addEventListener("click", this._handleUserCardClick)

    // Profile overlay event (dispatched by member_context_controller)
    this._handleProfileOverlayEvent = (e) => {
      const { userId, serverId } = e.detail
      this._openProfileOverlay(userId, serverId)
    }
    document.addEventListener("inferno:open-profile-overlay", this._handleProfileOverlayEvent)

    // Friend request bar event delegation + initial render
    this._handleFriendBarClick = (e) => this._onFriendBarClick(e)
    document.addEventListener("click", this._handleFriendBarClick)
    this._frInitBar()

    // Quick-edit button delegation (hover action bar on messages)
    this._handleEditBtnClick = (e) => {
      const btn = e.target.closest("[data-msg-edit-id]")
      if (btn) this.editMessage(btn.dataset.msgEditId)
    }
    document.addEventListener("click", this._handleEditBtnClick)

    // Clean up dynamic badges before Turbo caches the page snapshot
    this._beforeCache = () => this._cleanupForCache()
    document.addEventListener("turbo:before-cache", this._beforeCache)

    // Clear badges for the current channel on every Turbo render (channel switch)
    this._onRender = () => { this.clearCurrentChannelBadges(); this._frInitBar() }
    document.addEventListener("turbo:render", this._onRender)
  }

  disconnect() {
    if (this.subscription) this.subscription.unsubscribe()
    document.removeEventListener("contextmenu", this.handleContextMenu)
    document.removeEventListener("click", this.closeMenu)
    if (this._handleUserCardClick) document.removeEventListener("click", this._handleUserCardClick)
    if (this._handleProfileOverlayEvent) document.removeEventListener("inferno:open-profile-overlay", this._handleProfileOverlayEvent)
    if (this._handleFriendBarClick) document.removeEventListener("click", this._handleFriendBarClick)
    if (this._handleEditBtnClick) document.removeEventListener("click", this._handleEditBtnClick)
    this.closeMenu()
    this._closeUserCard()
    this._closeProfileOverlay()
    if (this._beforeCache) document.removeEventListener("turbo:before-cache", this._beforeCache)
    if (this._onRender) document.removeEventListener("turbo:render", this._onRender)
    if (this.sidebarTyping) {
      this.sidebarTyping.forEach(users => users.forEach(u => clearTimeout(u.timeout)))
      this.sidebarTyping.clear()
    }
  }

  _cleanupForCache() {
    // Remove all JS-added dynamic indicators so the Turbo cache snapshot is clean
    this._closeUserCard()
    this._closeProfileOverlay()
    document.querySelectorAll(".typing-indicator").forEach(el => el.remove())
    document.querySelectorAll(".server-unread-pill").forEach(el => el.remove())
    // Remove all mention badges (red notification dots) from channels and servers
    document.querySelectorAll(".mention-badge").forEach(el => el.remove())
    // Remove home badge
    document.querySelectorAll(".home-badge").forEach(el => el.remove())
    // Remove dynamically-added friend request items (keep server-rendered ones)
    document.querySelectorAll('[data-fr-items] [data-dynamic="true"]').forEach(el => el.remove())
    // Revert JS-added unread styling on channels
    document.querySelectorAll("[data-channel-id][data-unread]").forEach(el => {
      delete el.dataset.unread
      const pill = el.querySelector(".unread-pill")
      if (pill) pill.remove()
      if (!el.classList.contains("bg-gray-600")) {
        el.classList.remove("text-white")
        el.classList.add("text-gray-400")
      }
      const nameSpan = el.querySelector(".truncate")
      if (nameSpan) {
        nameSpan.classList.remove("font-bold")
        nameSpan.classList.add("font-medium")
      }
    })
  }

  _restoreLastChannels() {
    try {
      document.querySelectorAll("a[data-server-id]").forEach(el => {
        const serverId = el.dataset.serverId
        const lastChannel = localStorage.getItem(`lastChannel_${serverId}`)
        if (lastChannel) {
          el.href = el.href.replace(/\/channels\/[^\/]+/, `/channels/${lastChannel}`)
        }
      })
    } catch(e) {}
  }

  get canManage() {
    const el = document.querySelector("[data-channel-reorder-can-manage-value]")
    return el?.dataset?.channelReorderCanManageValue === "true"
  }

  get canManageMessages() {
    const el = document.querySelector("[data-can-manage-messages]")
    return el?.dataset?.canManageMessages === "true"
  }

  get currentServerId() {
    return document.querySelector("[data-current-server-id]")?.dataset?.currentServerId
  }

  // ---- Notification handling ----

  handleNotification(data) {
    if (data.type === "presence") {
      this._updateUserPresence(data)
      return
    }
    if (data.type === "mention") {
      const currentChannelId = document.querySelector("[data-current-channel-id]")
        ?.dataset?.currentChannelId
      if (currentChannelId && String(data.channel_id) === String(currentChannelId)) return
      this.showServerBadge(data.server_id)
      this.showChannelBadge(data.channel_id)
    } else if (data.type === "dm_message") {
      // Skip if we're currently viewing this conversation
      const currentConvEl = document.querySelector("[data-dm-message-form-conversation-id-value]")
      const currentConvId = currentConvEl?.dataset?.dmMessageFormConversationIdValue
      if (currentConvId && String(data.conversation_id) === String(currentConvId)) return
      this.showHomeBadge()
      this.showConversationBadge(data.conversation_id)
    } else if (data.type === "friend_request") {
      this.showHomeBadge()
      this._showFriendRequestBar(data)
    } else if (data.type === "friend_update") {
      this._handleFriendUpdate(data)
    } else if (data.type === "channel_message") {
      const selfId = document.body.dataset.currentUserId
      if (data.user_id && String(data.user_id) === String(selfId)) return
      const currentChannelId = document.querySelector("[data-current-channel-id]")?.dataset?.currentChannelId
      if (currentChannelId && String(data.channel_id) === String(currentChannelId)) return

      // Check if we're viewing a voice channel whose sidechat is this channel
      const currentVoiceItem = currentChannelId && document.querySelector(`[data-channel-id="${currentChannelId}"][data-sidechat-channel-id="${data.channel_id}"]`)
      if (currentVoiceItem) return

      this.showChannelUnread(data.channel_id)
      // Also mark voice channels that use this channel as their sidechat
      const voiceLink = document.querySelector(`[data-sidechat-channel-id="${data.channel_id}"]`)
      if (voiceLink && voiceLink.dataset.channelId !== currentChannelId) {
        this.showChannelUnread(voiceLink.dataset.channelId)
      }
      // Also mark linked text channels when a built-in sidechat message arrives
      const textLink = document.querySelector(`[data-linked-voice-channel-id="${data.channel_id}"]`)
      if (textLink && textLink.dataset.channelId !== currentChannelId) {
        this.showChannelUnread(textLink.dataset.channelId)
      }
      this.showServerUnread(data.server_id)
    } else if (data.type === "channel_typing") {
      this._handleChannelTyping(data)
    } else if (data.type === "clear") {
      if (data.channel_id) this.removeBadge("channel", data.channel_id)
      if (data.server_id && !data.channel_id) this.removeServerBadge(data.server_id)
    }
  }

  clearCurrentChannelBadges() {
    const el = document.querySelector("[data-current-channel-id]")
    if (!el) return
    const channelId = el.dataset.currentChannelId
    const serverId = el.dataset.currentServerId
    if (channelId) {
      this.removeBadge("channel", channelId)
      this.removeChannelUnread(channelId)
      // Viewing a voice channel: clear its linked text channel too
      const voiceItem = document.querySelector(`[data-channel-id="${channelId}"][data-sidechat-channel-id]`)
      if (voiceItem) {
        const scId = voiceItem.dataset.sidechatChannelId
        this.removeBadge("channel", scId)
        this.removeChannelUnread(scId)
      }
      // Viewing a text channel: clear the voice channel that links to it
      const textItem = document.querySelector(`[data-channel-id="${channelId}"][data-linked-voice-channel-id]`)
      if (textItem) {
        const vcId = textItem.dataset.linkedVoiceChannelId
        this.removeBadge("channel", vcId)
        this.removeChannelUnread(vcId)
      }
    }
    if (serverId) {
      this.recountServerBadge(serverId)
      this.recountServerUnread(serverId)
    }
  }

  // ---- Home / DM badge methods ----

  showHomeBadge() {
    const homeBtn = document.querySelector("[data-home-button]")
    if (!homeBtn) return
    let badge = homeBtn.querySelector(".home-badge")
    if (!badge) {
      badge = document.createElement("div")
      badge.className = "home-badge mention-badge absolute -bottom-0.5 -right-0.5 min-w-[18px] h-[18px] bg-accent rounded-full flex items-center justify-center text-white text-xs font-bold px-1 border-2 border-gray-950"
      badge.textContent = "1"
      homeBtn.appendChild(badge)
    } else {
      const count = parseInt(badge.textContent || "0") + 1
      badge.textContent = count > 99 ? "99+" : count
    }
  }

  removeHomeBadge() {
    const homeBtn = document.querySelector("[data-home-button]")
    if (!homeBtn) return
    const badge = homeBtn.querySelector(".home-badge")
    if (badge) badge.remove()
  }

  showConversationBadge(conversationId) {
    const convEl = document.querySelector(`[data-conversation-id="${conversationId}"]`)
    if (!convEl) return
    let badge = convEl.querySelector(".mention-badge")
    if (!badge) {
      badge = document.createElement("div")
      badge.className = "mention-badge ml-auto min-w-[18px] h-[18px] bg-accent rounded-full flex items-center justify-center text-white text-xs font-bold px-1 shrink-0"
      badge.textContent = "1"
      convEl.appendChild(badge)
    } else {
      const count = parseInt(badge.textContent || "0") + 1
      badge.textContent = count > 99 ? "99+" : count
    }
  }

  removeConversationBadge(conversationId) {
    const convEl = document.querySelector(`[data-conversation-id="${conversationId}"]`)
    if (!convEl) return
    const badge = convEl.querySelector(".mention-badge")
    if (badge) badge.remove()
  }

  recountHomeBadge() {
    let total = 0
    document.querySelectorAll("[data-conversation-id] .mention-badge").forEach(badge => {
      total += parseInt(badge.textContent || "0")
    })
    const homeBtn = document.querySelector("[data-home-button]")
    if (!homeBtn) return
    const badge = homeBtn.querySelector(".home-badge")
    if (total <= 0) {
      if (badge) badge.remove()
    } else if (badge) {
      badge.textContent = total > 99 ? "99+" : total
    }
  }

  async markDmsAsRead(conversationId) {
    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    const params = new URLSearchParams()
    if (conversationId) params.append("conversation_id", conversationId)

    await fetch("/notifications/mark_dm_read", {
      method: "POST",
      headers: { "X-CSRF-Token": csrf, "Content-Type": "application/x-www-form-urlencoded" },
      body: params.toString()
    })

    if (conversationId) {
      this.removeConversationBadge(conversationId)
      this.recountHomeBadge()
    } else {
      document.querySelectorAll("[data-conversation-id] .mention-badge").forEach(b => b.remove())
      this.removeHomeBadge()
    }
  }

  showServerBadge(serverId) {
    const serverIcon = document.querySelector(`[data-server-id="${serverId}"]`)
    if (!serverIcon) return
    let badge = serverIcon.querySelector(".mention-badge")
    if (!badge) {
      badge = document.createElement("div")
      badge.className = "mention-badge absolute -bottom-0.5 -right-0.5 min-w-[18px] h-[18px] bg-accent rounded-full flex items-center justify-center text-white text-xs font-bold px-1 border-2 border-gray-950"
      badge.textContent = "1"
      serverIcon.style.position = "relative"
      serverIcon.appendChild(badge)
    } else {
      const count = parseInt(badge.textContent || "0") + 1
      badge.textContent = count > 99 ? "99+" : count
    }
  }

  showChannelBadge(channelId) {
    const channelItem = document.querySelector(`[data-channel-id="${channelId}"]`)
    if (!channelItem) return
    let badge = channelItem.querySelector(".mention-badge")
    if (!badge) {
      badge = document.createElement("div")
      badge.className = "mention-badge ml-auto min-w-[18px] h-[18px] bg-accent rounded-full flex items-center justify-center text-white text-xs font-bold px-1 shrink-0"
      badge.textContent = "1"
      channelItem.appendChild(badge)
    } else {
      const count = parseInt(badge.textContent || "0") + 1
      badge.textContent = count > 99 ? "99+" : count
    }
  }

  removeBadge(type, id) {
    const attr = type === "server" ? "data-server-id" : "data-channel-id"
    const el = document.querySelector(`[${attr}="${id}"]`)
    if (!el) return
    const badge = el.querySelector(".mention-badge")
    if (badge) badge.remove()
  }

  removeServerBadge(serverId) {
    this.removeBadge("server", serverId)
    document.querySelectorAll(`[data-channel-id] .mention-badge`).forEach(b => b.remove())
  }

  recountServerBadge(serverId) {
    let total = 0
    document.querySelectorAll(`[data-channel-id] .mention-badge`).forEach(badge => {
      total += parseInt(badge.textContent || "0")
    })
    const serverIcon = document.querySelector(`[data-server-id="${serverId}"]`)
    if (!serverIcon) return
    const serverBadge = serverIcon.querySelector(".mention-badge")
    if (total <= 0) {
      if (serverBadge) serverBadge.remove()
    } else if (serverBadge) {
      serverBadge.textContent = total > 99 ? "99+" : total
    }
  }

  // ---- Unread (grey) indicator methods ----

  showChannelUnread(channelId) {
    const channelItem = document.querySelector(`[data-channel-id="${channelId}"]`)
    if (!channelItem) return
    // Don't add if already unread
    if (channelItem.dataset.unread === "true") return
    channelItem.dataset.unread = "true"
    // Make text white and bold
    channelItem.classList.remove("text-gray-400")
    channelItem.classList.add("text-white")
    const nameSpan = channelItem.querySelector(".truncate")
    if (nameSpan) {
      nameSpan.classList.remove("font-medium")
      nameSpan.classList.add("font-bold")
    }
    // Add grey pill on the left
    if (!channelItem.querySelector(".unread-pill")) {
      const pill = document.createElement("div")
      pill.className = "unread-pill absolute -left-2 top-1/2 -translate-y-1/2 w-1 h-2 bg-accent rounded-r-full"
      channelItem.appendChild(pill)
    }
  }

  removeChannelUnread(channelId) {
    const channelItem = document.querySelector(`[data-channel-id="${channelId}"]`)
    if (!channelItem) return
    delete channelItem.dataset.unread
    // Only revert text color if not the active channel
    const isActive = channelItem.classList.contains("bg-gray-600")
    if (!isActive) {
      channelItem.classList.remove("text-white")
      channelItem.classList.add("text-gray-400")
    }
    const nameSpan = channelItem.querySelector(".truncate")
    if (nameSpan) {
      nameSpan.classList.remove("font-bold")
      nameSpan.classList.add("font-medium")
    }
    // Remove grey pill
    const pill = channelItem.querySelector(".unread-pill")
    if (pill) pill.remove()
  }

  showServerUnread(serverId) {
    const serverIcon = document.querySelector(`[data-server-id="${serverId}"]`)
    if (!serverIcon) return
    // Don't add if there's already a mention badge or unread pill
    if (serverIcon.querySelector(".mention-badge")) return
    if (serverIcon.querySelector(".server-unread-pill")) return
    // Don't add if this is the active server
    if (serverIcon.classList.contains("from-accent-dark")) return
    const pill = document.createElement("div")
    pill.className = "server-unread-pill absolute -left-[10px] top-1/2 -translate-y-1/2 w-[3px] h-2 bg-accent rounded-r-full"
    serverIcon.appendChild(pill)
  }

  removeServerUnread(serverId) {
    const serverIcon = document.querySelector(`[data-server-id="${serverId}"]`)
    if (!serverIcon) return
    const pill = serverIcon.querySelector(".server-unread-pill")
    if (pill) pill.remove()
  }

  recountServerUnread(serverId) {
    // Check if any channel still has unread indicator
    const hasUnread = document.querySelector("[data-channel-id][data-unread='true']") !== null
    const serverIcon = document.querySelector(`[data-server-id="${serverId}"]`)
    if (!serverIcon) return
    if (!hasUnread) {
      this.removeServerUnread(serverId)
    } else if (!serverIcon.querySelector(".mention-badge")) {
      this.showServerUnread(serverId)
    }
  }

  // ---- Friend request bar ----

  _frInitBar() {
    const bar = document.getElementById("friend-request-bar")
    if (!bar) return

    const items = this._frGetItems()
    if (items.length === 0) {
      bar.classList.add("hidden")
      this._frUpdateToolbarBadge()
      return
    }

    // Show bar only if user hasn't manually hidden it
    const userHid = localStorage.getItem("fr_bar_visible") === "false"
    if (!userHid) {
      bar.classList.remove("hidden")
      bar.style.animation = "none"
      bar.offsetHeight
      bar.style.animation = ""
    }

    this._frRenderCurrent()
    this._frUpdateToolbarBadge()
  }

  _frGetItems() {
    const bar = document.getElementById("friend-request-bar")
    if (!bar) return []
    return Array.from(bar.querySelectorAll("[data-fr-items] [data-friendship-id]"))
  }

  _frGetIndex() {
    const bar = document.getElementById("friend-request-bar")
    return parseInt(bar?.dataset?.frIndex || "0")
  }

  _frSetIndex(i) {
    const bar = document.getElementById("friend-request-bar")
    if (bar) bar.dataset.frIndex = i
  }

  _frRenderCurrent() {
    const bar = document.getElementById("friend-request-bar")
    if (!bar) return
    const items = this._frGetItems()
    if (items.length === 0) {
      bar.classList.add("hidden")
      this._frUpdateToolbarBadge()
      return
    }
    let idx = this._frGetIndex()
    if (idx >= items.length) idx = 0
    if (idx < 0) idx = items.length - 1
    this._frSetIndex(idx)

    const item = items[idx]
    const avatarUrl = item.dataset.frAvatar
    const name = item.dataset.frName
    const color = item.dataset.frColor || "#b45309"
    const initial = item.dataset.frInitial || "?"

    // Update avatar
    const avatarSlot = bar.querySelector("[data-fr-avatar-slot]")
    if (avatarSlot) {
      if (avatarUrl) {
        avatarSlot.innerHTML = ""
        const img = document.createElement("img")
        img.src = avatarUrl
        img.className = "w-6 h-6 rounded-full object-cover"
        avatarSlot.className = "shrink-0"
        avatarSlot.appendChild(img)
      } else {
        avatarSlot.innerHTML = ""
        avatarSlot.textContent = initial
        avatarSlot.className = "w-6 h-6 rounded-full flex items-center justify-center text-xs font-bold shrink-0"
        avatarSlot.style.backgroundColor = color
      }
    }

    // Update name
    const nameSlot = bar.querySelector("[data-fr-name-slot]")
    if (nameSlot) nameSlot.textContent = name

    // Update counter
    const counter = bar.querySelector("[data-fr-counter]")
    if (counter) counter.textContent = `${idx + 1}/${items.length}`

    // Hide arrows if only 1 item
    const prevBtn = bar.querySelector("[data-fr-prev]")
    const nextBtn = bar.querySelector("[data-fr-next]")
    if (prevBtn) prevBtn.style.visibility = items.length <= 1 ? "hidden" : ""
    if (nextBtn) nextBtn.style.visibility = items.length <= 1 ? "hidden" : ""

    // Store current friendship ID on the expanded view for action buttons
    const expanded = bar.querySelector("[data-fr-expanded]")
    if (expanded) expanded.dataset.currentFriendshipId = item.dataset.friendshipId
  }

  _showFriendRequestBar(data) {
    const bar = document.getElementById("friend-request-bar")
    if (!bar) return
    const itemsContainer = bar.querySelector("[data-fr-items]")
    if (!itemsContainer) return

    // Don't add duplicate
    if (data.friendship_id && itemsContainer.querySelector(`[data-friendship-id="${data.friendship_id}"]`)) return

    // Add new data item
    const div = document.createElement("div")
    div.dataset.friendshipId = data.friendship_id
    div.dataset.frName = data.from_user
    div.dataset.frColor = data.profile_color || "#b45309"
    div.dataset.frInitial = data.from_user_initial || "?"
    div.dataset.frAvatar = data.avatar_url || ""
    div.dataset.dynamic = "true"
    itemsContainer.appendChild(div)

    // Show bar if user hasn't manually hidden it
    const userHid = localStorage.getItem("fr_bar_visible") === "false"
    if (!userHid) {
      const wasHidden = bar.classList.contains("hidden")
      if (wasHidden) {
        const items = this._frGetItems()
        this._frSetIndex(items.length - 1)
        bar.classList.remove("hidden")
        bar.style.animation = "none"
        bar.offsetHeight
        bar.style.animation = ""
      }
    }

    this._frRenderCurrent()
    this._frUpdateToolbarBadge()
  }

  _frRemoveCurrentItem() {
    const items = this._frGetItems()
    const idx = this._frGetIndex()
    if (!items[idx]) return
    items[idx].remove()
    // Adjust index
    const remaining = this._frGetItems()
    if (remaining.length === 0) {
      const bar = document.getElementById("friend-request-bar")
      if (bar) bar.classList.add("hidden")
      this._frUpdateToolbarBadge()
      return
    }
    const newIdx = idx >= remaining.length ? 0 : idx
    this._frSetIndex(newIdx)
    this._frRenderCurrent()
    this._frUpdateToolbarBadge()
  }

  _frDecrementHomeBadge() {
    const homeBtn = document.querySelector("[data-home-button]")
    if (!homeBtn) return
    const badge = homeBtn.querySelector(".home-badge")
    if (!badge) return
    const count = parseInt(badge.textContent || "0") - 1
    if (count <= 0) {
      badge.remove()
    } else {
      badge.textContent = count > 99 ? "99+" : count
    }
  }

  _frUpdateToolbarBadge() {
    const count = this._frGetItems().length
    document.querySelectorAll("[data-toolbar-action='toggle-friends']").forEach(btn => {
      if (count <= 0) {
        btn.classList.add("hidden")
      } else {
        btn.classList.remove("hidden")
        const badge = btn.querySelector("[data-toolbar-friend-badge]")
        if (badge) {
          badge.textContent = count
        }
      }
    })
  }

  _onFriendBarClick(e) {
    // Toolbar toggle button
    const toolbarBtn = e.target.closest("[data-toolbar-action='toggle-friends']")
    if (toolbarBtn) {
      const bar = document.getElementById("friend-request-bar")
      if (!bar) return
      const items = this._frGetItems()
      if (items.length === 0) return
      const isHidden = bar.classList.contains("hidden")
      if (isHidden) {
        bar.classList.remove("hidden")
        bar.style.animation = "none"
        bar.offsetHeight
        bar.style.animation = ""
        localStorage.setItem("fr_bar_visible", "true")
      } else {
        bar.classList.add("hidden")
        localStorage.setItem("fr_bar_visible", "false")
      }
      return
    }

    const bar = document.getElementById("friend-request-bar")
    if (!bar) return

    // Prev/Next
    const prevBtn = e.target.closest("[data-fr-prev]")
    if (prevBtn) {
      const display = bar.querySelector("[data-fr-display]")
      if (display) { display.style.opacity = "0"; setTimeout(() => { display.style.opacity = "1" }, 50) }
      this._frSetIndex(this._frGetIndex() - 1)
      setTimeout(() => this._frRenderCurrent(), 50)
      return
    }
    const nextBtn = e.target.closest("[data-fr-next]")
    if (nextBtn) {
      const display = bar.querySelector("[data-fr-display]")
      if (display) { display.style.opacity = "0"; setTimeout(() => { display.style.opacity = "1" }, 50) }
      this._frSetIndex(this._frGetIndex() + 1)
      setTimeout(() => this._frRenderCurrent(), 50)
      return
    }

    // Action buttons (accept/decline/ignore)
    const actionBtn = e.target.closest("[data-friend-action]")
    if (!actionBtn) return
    const expanded = bar.querySelector("[data-fr-expanded]")
    const friendshipId = expanded?.dataset?.currentFriendshipId
    if (!friendshipId) return
    const action = actionBtn.dataset.friendAction

    if (action !== "accept" && action !== "decline" && action !== "ignore") return

    // Disable buttons during fetch
    const actions = bar.querySelectorAll("[data-friend-action]")
    actions.forEach(b => b.disabled = true)

    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    fetch(`/friendships/${friendshipId}/${action}`, {
      method: "POST",
      headers: { "X-CSRF-Token": csrf, "Accept": "application/json" }
    }).then(res => {
      if (res.ok) {
        this._frRemoveCurrentItem()
        this._frDecrementHomeBadge()
        // Refresh the contacts page to update tabs and counts
        this._scheduleContactsRefresh()
      }
      actions.forEach(b => b.disabled = false)
    }).catch(() => {
      actions.forEach(b => b.disabled = false)
    })
  }

  // ---- Sidebar typing indicator ----

  _handleChannelTyping(data) {
    const channelId = data.channel_id
    if (!this.sidebarTyping.has(channelId)) {
      this.sidebarTyping.set(channelId, new Map())
    }
    const users = this.sidebarTyping.get(channelId)
    const existing = users.get(data.user_id)
    if (existing) clearTimeout(existing.timeout)
    const timeout = setTimeout(() => {
      users.delete(data.user_id)
      if (users.size === 0) this.sidebarTyping.delete(channelId)
      this._renderSidebarTyping(channelId)
    }, 3000)
    users.set(data.user_id, {
      username: data.username,
      avatar_url: data.avatar_url,
      avatar_initial: data.avatar_initial,
      avatar_color: data.avatar_color,
      timeout
    })
    this._renderSidebarTyping(channelId)
  }

  _renderSidebarTyping(channelId) {
    const channelItem = document.querySelector(`[data-channel-id="${channelId}"]`)
    if (!channelItem) return
    const existingIndicator = channelItem.querySelector(".typing-indicator")
    const users = this.sidebarTyping.get(channelId)
    if (!users || users.size === 0) {
      if (existingIndicator) existingIndicator.remove()
      return
    }
    this._ensureTypingStyles()
    const userList = Array.from(users.values())
    const maxVisible = 2
    const visible = userList.slice(0, maxVisible)
    const extra = userList.length - maxVisible

    let html = '<div class="flex items-center">'
    // Overlapping avatars
    html += '<div class="flex items-center" style="margin-left: auto;">'
    visible.forEach((u, i) => {
      const offset = i > 0 ? 'margin-left: -4px;' : ''
      if (u.avatar_url) {
        html += `<img src="${u.avatar_url}" class="rounded-full object-cover shrink-0" style="width: 16px; height: 16px; ${offset} border: 1.5px solid var(--color-gray-800); position: relative; z-index: ${maxVisible - i};" alt="${u.username}">`
      } else {
        html += `<div class="rounded-full shrink-0 flex items-center justify-center text-white" style="width: 16px; height: 16px; font-size: 8px; ${offset} border: 1.5px solid var(--color-gray-800); position: relative; z-index: ${maxVisible - i}; background-color: ${u.avatar_color || '#b45309'};">${u.avatar_initial || '?'}</div>`
      }
    })
    if (extra > 0) {
      html += `<span class="text-[9px] text-gray-400 font-semibold" style="margin-left: 2px;">+${extra}</span>`
    }
    html += '</div>'
    // Animated dots
    html += '<span class="typing-dots" style="margin-left: 3px; font-size: 10px; color: var(--color-gray-400);"><span>.</span><span>.</span><span>.</span></span>'
    html += '</div>'

    let indicator = existingIndicator
    if (!indicator) {
      indicator = document.createElement("div")
      indicator.className = "typing-indicator ml-auto shrink-0"
      channelItem.appendChild(indicator)
    }
    indicator.innerHTML = html
  }

  _ensureTypingStyles() {
    if (document.getElementById("typing-dots-style")) return
    const style = document.createElement("style")
    style.id = "typing-dots-style"
    style.textContent = `
      .typing-dots span {
        animation: typingDot 1.4s infinite;
        display: inline-block;
      }
      .typing-dots span:nth-child(2) { animation-delay: 0.2s; }
      .typing-dots span:nth-child(3) { animation-delay: 0.4s; }
      @keyframes typingDot {
        0%, 60%, 100% { opacity: 0.3; }
        30% { opacity: 1; }
      }
    `
    document.head.appendChild(style)
  }

  // ---- Context Menus ----

  handleContextMenu(event) {
    // Ignore right-clicks inside existing context menus or popups
    if (event.target.closest("[data-context-menu]") || event.target.closest("#notif-context-menu")) return

    // Home/DM button
    const homeEl = event.target.closest("[data-home-button]")
    if (homeEl) {
      event.preventDefault()
      this.closeMenu()
      this.showHomeContextMenu(event.clientX, event.clientY)
      return
    }

    // Conversation item in DM sidebar
    const convEl = event.target.closest("[data-conversation-id]")
    if (convEl) {
      event.preventDefault()
      this.closeMenu()
      this.showConversationContextMenu(event.clientX, event.clientY, convEl)
      return
    }

    // Voice participant (sidebar or main view)
    const voiceUserEl = event.target.closest("[data-voice-user-id]") || event.target.closest("[data-voice-participant-id]")
    if (voiceUserEl) {
      event.preventDefault()
      this.closeMenu()
      const userId = voiceUserEl.dataset.voiceUserId || voiceUserEl.dataset.voiceParticipantId
      const serverId = this.currentServerId
        || document.querySelector("[data-channel-sidebar-server-id-value]")?.dataset.channelSidebarServerIdValue
      if (userId && serverId) {
        this._showVoiceParticipantMenu(event.clientX, event.clientY, userId, serverId)
      }
      return
    }

    // Server icon
    const serverEl = event.target.closest("[data-server-id]")
    if (serverEl) {
      event.preventDefault()
      this.closeMenu()
      this.showServerContextMenu(event.clientX, event.clientY, serverEl.dataset.serverId)
      return
    }

    // Channel item (skip if right-clicking a voice participant — those have their own context menu)
    const channelEl = event.target.closest("[data-channel-id]")
    if (channelEl) {
      event.preventDefault()
      this.closeMenu()
      this.showChannelContextMenu(event.clientX, event.clientY, channelEl.dataset.channelId)
      return
    }

    // Category header
    const categoryEl = event.target.closest("[data-category-id]")
    if (categoryEl) {
      event.preventDefault()
      this.closeMenu()
      this.showCategoryContextMenu(event.clientX, event.clientY, categoryEl.dataset.categoryId)
      return
    }

    // Video inside message (delegate to image-preview controller)
    const videoEl = event.target.closest("[data-video-src]")
    if (videoEl) return

    // Message (including images inside messages)
    const messageEl = event.target.closest("[data-message-id]")
    if (messageEl) {
      event.preventDefault()
      this.closeMenu()
      // Close any image-preview context menu
      const imgMenu = document.getElementById("image-context-menu")
      if (imgMenu) imgMenu.remove()
      this.showMessageContextMenu(event.clientX, event.clientY, messageEl, event.target)
      return
    }
  }

  showHomeContextMenu(x, y) {
    const items = [
      {
        icon: this.icons.check,
        label: "Mark as Read",
        action: () => this.markDmsAsRead()
      }
    ]
    this.renderContextMenu(x, y, items)
  }

  showConversationContextMenu(x, y, convEl) {
    const conversationId = convEl.dataset.conversationId
    const convType = convEl.dataset.convType
    const convName = convEl.dataset.convName
    const contactId = convEl.dataset.contactId
    const contactStatus = convEl.dataset.contactStatus
    const otherUserId = convEl.dataset.otherUserId
    const csrf = () => document.querySelector("meta[name=csrf-token]")?.content

    const items = [
      {
        icon: this.icons.check,
        label: "Mark as Read",
        action: () => this.markDmsAsRead(conversationId)
      }
    ]

    if (convType === "group") {
      // Group chat actions
      items.push({ separator: true })
      items.push({
        icon: this.icons.edit,
        label: "Edit Group",
        action: () => {
          // Check if we're already viewing this conversation
          const currentPath = window.location.pathname
          const convPath = convEl.getAttribute("href")
          if (currentPath === convPath) {
            // Already here — just open the panel
            const p = document.getElementById("dm-profile-panel")
            if (p) p.classList.remove("hidden")
            return
          }
          // Navigate to the conversation via sidebar link, then open panel
          const onLoad = (e) => {
            if (e.target.id !== "main-content") return
            document.removeEventListener("turbo:frame-load", onLoad)
            // Small delay to let Stimulus controllers connect
            requestAnimationFrame(() => {
              const p = document.getElementById("dm-profile-panel")
              if (p) p.classList.remove("hidden")
            })
          }
          document.addEventListener("turbo:frame-load", onLoad)
          setTimeout(() => document.removeEventListener("turbo:frame-load", onLoad), 5000)
          convEl.click()
        }
      })
      items.push({ separator: true })
      items.push({
        icon: this.icons.leave,
        label: "Leave Group",
        danger: true,
        action: async () => {
          const ok = await this.showConfirm("Leave Group", `Leave "${convName || "this group chat"}"? You won't be able to rejoin unless invited.`, "Leave", "bg-gradient-to-r from-danger-dark to-danger hover:from-danger hover:to-danger-light")
          if (!ok) return
          const currentUserId = document.body.dataset.currentUserId
          await fetch(`/conversations/${conversationId}/remove_member`, {
            method: "DELETE",
            headers: { "X-CSRF-Token": csrf(), "Content-Type": "application/x-www-form-urlencoded" },
            body: `member_id=${currentUserId}`
          })
          window.Turbo.visit("/conversations")
        }
      })
    } else {
      // Direct DM actions
      if (contactId) {
        items.push({ separator: true })
        if (contactStatus === "accepted") {
          items.push({
            icon: this.icons.userMinus,
            label: "Remove Friend",
            danger: true,
            action: async () => {
              const ok = await this.showConfirm("Remove Friend", `Remove ${convName} from your friends?`, "Remove", "bg-gradient-to-r from-danger-dark to-danger hover:from-danger hover:to-danger-light")
              if (!ok) return
              await fetch(`/friendships/${contactId}`, {
                method: "DELETE",
                headers: { "X-CSRF-Token": csrf() }
              })
              window.Turbo.visit("/conversations")
            }
          })
        } else if (contactStatus === "pending_incoming") {
          items.push({
            icon: this.icons.check,
            label: "Accept Friend Request",
            action: async () => {
              await fetch(`/friendships/${contactId}/accept`, {
                method: "POST",
                headers: { "X-CSRF-Token": csrf() }
              })
              window.Turbo.visit(window.location.pathname)
            }
          })
          items.push({
            icon: this.icons.decline,
            label: "Decline Friend Request",
            danger: true,
            action: async () => {
              await fetch(`/friendships/${contactId}/decline`, {
                method: "POST",
                headers: { "X-CSRF-Token": csrf() }
              })
              window.Turbo.visit(window.location.pathname)
            }
          })
        } else if (contactStatus === "pending_outgoing") {
          items.push({
            icon: this.icons.decline,
            label: "Cancel Friend Request",
            danger: true,
            action: async () => {
              await fetch(`/friendships/${contactId}`, {
                method: "DELETE",
                headers: { "X-CSRF-Token": csrf() }
              })
              window.Turbo.visit(window.location.pathname)
            }
          })
        }
      }

      // Block user (for DMs with a known contact)
      if (contactId) {
        items.push({
          icon: this.icons.block,
          label: "Block User",
          danger: true,
          action: async () => {
            const ok = await this.showConfirm("Block User", `Block ${convName}? They won't be able to message you, and will be removed from your friends.`, "Block", "bg-gradient-to-r from-danger-dark to-danger hover:from-danger hover:to-danger-light")
            if (!ok) return
            await fetch("/blocks", {
              method: "POST",
              headers: { "X-CSRF-Token": csrf(), "Content-Type": "application/x-www-form-urlencoded" },
              body: `contact_id=${contactId}`
            })
            window.Turbo.visit("/conversations")
          }
        })
      }

      items.push({ separator: true })
      items.push({
        icon: this.icons.trash,
        label: "Close Conversation",
        danger: true,
        action: async () => {
          const ok = await this.showConfirm("Close Conversation", `Close your conversation with ${convName}? The conversation will be removed from your sidebar.`, "Close", "bg-gradient-to-r from-danger-dark to-danger hover:from-danger hover:to-danger-light")
          if (!ok) return
          await fetch(`/conversations/${conversationId}`, {
            method: "DELETE",
            headers: { "X-CSRF-Token": csrf() }
          })
          window.Turbo.visit("/conversations")
        }
      })
    }

    this.renderContextMenu(x, y, items)
  }

  showServerContextMenu(x, y, serverId) {
    const items = [
      {
        icon: this.icons.check,
        label: "Mark as Read",
        action: () => this.markAsRead({ serverId })
      },
      { separator: true },
      {
        icon: this.icons.bell,
        label: "Notification Settings",
        disabled: true
      },
      { separator: true },
      {
        icon: this.icons.copy,
        label: "Copy Server ID",
        action: () => navigator.clipboard.writeText(serverId)
      }
    ]
    this.renderContextMenu(x, y, items)
  }

  showChannelContextMenu(x, y, channelId) {
    const serverId = this.currentServerId
    const items = [
      {
        icon: this.icons.check,
        label: "Mark as Read",
        action: () => this.markAsRead({ channelId, serverId })
      },
      { separator: true },
      {
        icon: this.icons.bell,
        label: "Notification Settings",
        disabled: true
      },
    ]

    // Voice channel extras
    const channelEl = document.querySelector(`[data-channel-id="${channelId}"]`)
    if (channelEl?.dataset.voiceChannel) {
      // Monitor volume slider — shown when this is a descendant of the user's current voice channel
      const voiceCtrl = document.querySelector("[data-controller~='voice-channel']")
      const controller = voiceCtrl
        ? this.application.getControllerForElementAndIdentifier(voiceCtrl, "voice-channel")
        : null
      const myChannelId = controller?.currentChannelId

      if (myChannelId && myChannelId !== channelId && this._isDescendantOfChannel(channelEl, myChannelId)) {
        items.push({ separator: true })
        const slider = this._buildChildVolumeSlider(channelId)
        items.push({ customEl: slider })
      }

      // "Kindle Ember" — create a nested voice channel under this one
      if (this.canManage) {
        items.push({ separator: true })
        items.push({
          icon: `<svg class="w-4 h-4 mr-2 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/></svg>`,
          label: "Kindle Ember",
          action: () => { window.location.href = `/servers/${serverId}/channels/new?parent_channel_id=${channelId}` }
        })
      }
    }

    if (this.canManage) {
      items.push({ separator: true })
      items.push({
        icon: this.icons.edit,
        label: "Edit Channel",
        action: () => { window.location.href = `/servers/${serverId}/channels/${channelId}/edit` }
      })
      items.push({
        icon: this.icons.trash,
        label: "Delete Channel",
        danger: true,
        action: () => this.deleteChannel(serverId, channelId)
      })
    }

    items.push({ separator: true })
    items.push({
      icon: this.icons.copy,
      label: "Copy Channel ID",
      action: () => navigator.clipboard.writeText(channelId)
    })

    this.renderContextMenu(x, y, items)
  }

  showCategoryContextMenu(x, y, categoryId) {
    const serverId = this.currentServerId
    const items = []

    if (this.canManage) {
      items.push({
        icon: this.icons.plus,
        label: "Create Channel",
        action: () => { window.location.href = `/servers/${serverId}/channels/new?category_id=${categoryId}` }
      })
      items.push({ separator: true })
      items.push({
        icon: this.icons.edit,
        label: "Edit Category",
        action: () => { window.location.href = `/servers/${serverId}/categories/${categoryId}/edit` }
      })
      items.push({
        icon: this.icons.trash,
        label: "Delete Category",
        danger: true,
        action: () => this.deleteCategory(serverId, categoryId)
      })
      items.push({ separator: true })
    }

    items.push({
      icon: this.icons.copy,
      label: "Copy Category ID",
      action: () => navigator.clipboard.writeText(categoryId)
    })

    this.renderContextMenu(x, y, items)
  }

  async _showVoiceParticipantMenu(x, y, userId, serverId) {
    try {
      const response = await fetch(`/servers/${serverId}/voice/context_menu/${userId}`, {
        headers: { "X-Requested-With": "XMLHttpRequest" }
      })
      if (!response.ok) return

      const html = await response.text()
      const menu = document.createElement("div")
      menu.className = "fixed z-[100] context-pop"
      menu.id = "notif-context-menu"
      menu.setAttribute("data-voice-context-menu", "")
      menu.innerHTML = html

      document.body.appendChild(menu)

      // Position within viewport
      const pad = 24
      const rect = menu.getBoundingClientRect()
      let left = x, top = y
      if (left + rect.width > window.innerWidth - pad) left = window.innerWidth - rect.width - pad
      if (left < pad) left = pad
      if (top + rect.height > window.innerHeight - pad) top = y - rect.height
      if (top < pad) top = pad
      menu.style.left = `${left}px`
      menu.style.top = `${top}px`

      this._bindVoiceMenuActions(menu, serverId)
    } catch (e) {
      console.warn("[VoiceContext] Failed to load context menu:", e)
    }
  }

  _bindVoiceMenuActions(menu, serverId) {
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content

    menu.querySelectorAll("[data-context-action]").forEach(btn => {
      const action = btn.dataset.contextAction

      if (action === "viewProfile") {
        btn.addEventListener("click", () => {
          this.closeMenu()
          document.dispatchEvent(new CustomEvent("inferno:open-profile-overlay", {
            detail: { userId: btn.dataset.userId, serverId: btn.dataset.serverId },
            bubbles: true
          }))
        })
      } else if (action === "selfMute") {
        btn.addEventListener("click", () => {
          this.closeMenu()
          const voiceCtrl = document.querySelector("[data-controller~='voice-channel']")
          if (voiceCtrl) {
            this.application.getControllerForElementAndIdentifier(voiceCtrl, "voice-channel")?.toggleMute()
          }
        })
      } else if (action === "selfDeafen") {
        btn.addEventListener("click", () => {
          this.closeMenu()
          const voiceCtrl = document.querySelector("[data-controller~='voice-channel']")
          if (voiceCtrl) {
            this.application.getControllerForElementAndIdentifier(voiceCtrl, "voice-channel")?.toggleDeafen()
          }
        })
      } else if (action === "serverMute") {
        btn.addEventListener("click", () => {
          this.closeMenu()
          fetch(`/servers/${serverId}/voice/server_mute/${btn.dataset.userId}`, {
            method: "PATCH",
            headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken }
          }).catch(() => {})
        })
      } else if (action === "serverDeafen") {
        btn.addEventListener("click", () => {
          this.closeMenu()
          fetch(`/servers/${serverId}/voice/server_deafen/${btn.dataset.userId}`, {
            method: "PATCH",
            headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken }
          }).catch(() => {})
        })
      } else if (action === "moveToChannel") {
        btn.addEventListener("click", (e) => {
          e.stopPropagation()
          this._showVoiceMoveDropdown(menu, btn, serverId)
        })
      } else if (action === "disconnectMember") {
        btn.addEventListener("click", () => {
          const username = btn.dataset.username
          if (confirm(`Disconnect ${username} from voice?`)) {
            fetch(`/servers/${serverId}/voice/disconnect/${btn.dataset.userId}`, {
              method: "DELETE",
              headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken }
            }).catch(() => {})
          }
          this.closeMenu()
        })
      }
    })
  }

  _showVoiceMoveDropdown(menu, btn, serverId) {
    // Remove existing move dropdown
    const existing = document.querySelector("[data-voice-move-dropdown]")
    if (existing) { existing.remove(); return }

    const channels = JSON.parse(btn.dataset.voiceChannels || "[]")
    const userId = btn.dataset.userId
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content

    const tpl = document.getElementById("tpl-move-dropdown")
    if (!tpl) return

    const dropdown = tpl.content.cloneNode(true).firstElementChild
    dropdown.setAttribute("data-voice-move-dropdown", "")
    const slot = dropdown.querySelector("[data-slot='channels']")

    if (channels.length === 0) {
      slot.innerHTML = '<p class="px-3 py-2 text-xs text-gray-500">No other voice channels</p>'
    } else {
      const itemTpl = document.getElementById("tpl-move-channel-item")
      channels.forEach(ch => {
        const item = itemTpl.content.cloneNode(true).querySelector("button")
        item.querySelector("[data-slot='name']").textContent = ch.name
        item.addEventListener("click", () => {
          fetch(`/servers/${serverId}/voice/move/${userId}`, {
            method: "PATCH",
            headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
            body: JSON.stringify({ channel_id: ch.id })
          }).catch(() => {})
          this.closeMenu()
        })
        slot.appendChild(item)
      })
    }

    // Position to the right of the move button
    const wrapper = btn.closest(".context-move-wrapper")
    const wrapperRect = wrapper.getBoundingClientRect()
    dropdown.style.position = "fixed"
    let ddLeft = wrapperRect.right + 4
    if (ddLeft + 200 > window.innerWidth) ddLeft = wrapperRect.left - 200
    let ddTop = wrapperRect.top
    if (ddTop + 260 > window.innerHeight) ddTop = window.innerHeight - 264
    dropdown.style.left = `${ddLeft}px`
    dropdown.style.top = `${ddTop}px`

    document.body.appendChild(dropdown)
    dropdown.addEventListener("click", (e) => e.stopPropagation())
  }

  showMessageContextMenu(x, y, messageEl, clickTarget) {
    const messageId = messageEl.dataset.messageId
    const serverId = this.currentServerId
    const currentUserId = document.body.dataset.currentUserId
    const authorEl = messageEl.querySelector(".text-accent-light")
    const contentEl = messageEl.querySelector(".message-content")
    const content = contentEl?.textContent?.trim() || ""

    // Copy Link option if right-clicked on a link
    const clickedLink = clickTarget ? clickTarget.closest("a[href]") : null

    // Check if this is the current user's message
    const isAuthor = messageEl.dataset.authorId === currentUserId

    const items = [
      {
        icon: this.icons.reply,
        label: "Reply",
        action: () => {
          const authorName = messageEl.querySelector(".text-accent-light")?.textContent?.trim() || ""
          let rawPreview = messageEl.querySelector(".message-content")?.textContent?.trim() || ""
          // Strip code block markers for cleaner preview
          const preview = rawPreview.replace(/```\w*/g, "").replace(/```/g, "").replace(/\s+/g, " ").trim().substring(0, 80)
          const event = new CustomEvent("inferno:reply", { detail: { messageId, authorName, preview }, bubbles: true })
          document.dispatchEvent(event)
        }
      },
      {
        icon: this.icons.react,
        label: "Add Reaction",
        action: () => {
          const event = new CustomEvent("inferno:react", { detail: { messageId, clientX: x, clientY: y }, bubbles: true })
          document.dispatchEvent(event)
        }
      },
      { separator: true },
      {
        icon: this.icons.copy,
        label: "Copy Text",
        action: () => navigator.clipboard.writeText(content)
      },
      {
        icon: this.icons.react,
        label: "View Reactions",
        action: () => this.viewReactions(messageId)
      },
      {
        icon: this.icons.link,
        label: "Copy Message Link",
        action: () => {
          const el = document.querySelector("[data-current-server-id]")
          if (el) {
            const sId = el.dataset.currentServerId
            const cId = el.dataset.currentChannelId
            const link = `${window.location.origin}/servers/${sId}/channels/${cId}#message-${messageId}`
            navigator.clipboard.writeText(link)
          } else {
            // DM context — use current URL with message anchor
            const link = `${window.location.origin}${window.location.pathname}#message-${messageId}`
            navigator.clipboard.writeText(link)
          }
        }
      },
    ]

    if (clickedLink) {
      items.unshift({
        icon: this.icons.link,
        label: "Open Link",
        action: () => window.open(clickedLink.href, "_blank")
      })
      items.unshift({
        icon: this.icons.link,
        label: "Copy Link",
        action: () => navigator.clipboard.writeText(clickedLink.href)
      })
      items.splice(2, 0, { separator: true })
    }

    // Image-specific options when right-clicking an image
    const clickedImg = clickTarget ? clickTarget.closest("img[data-preview-src]") : null
    if (clickedImg) {
      const imgSrc = clickedImg.dataset.previewSrc
      const imgFilename = clickedImg.dataset.previewFilename || "image"
      items.unshift(
        {
          icon: this.icons.copy,
          label: "Copy Image",
          action: async () => {
            try {
              const res = await fetch(imgSrc, { redirect: "follow" })
              const blob = await res.blob()
              // Clipboard API only supports image/png — convert if needed
              if (blob.type === "image/png") {
                await navigator.clipboard.write([new ClipboardItem({ "image/png": blob })])
              } else {
                const bitmap = await createImageBitmap(blob)
                const canvas = document.createElement("canvas")
                canvas.width = bitmap.width
                canvas.height = bitmap.height
                canvas.getContext("2d").drawImage(bitmap, 0, 0)
                const pngBlob = await new Promise(r => canvas.toBlob(r, "image/png"))
                await navigator.clipboard.write([new ClipboardItem({ "image/png": pngBlob })])
              }
            } catch (err) {
              console.warn("Copy image failed:", err)
            }
          }
        },
        {
          icon: this.icons.link,
          label: "Save Image",
          action: () => { const a = document.createElement("a"); a.href = imgSrc; a.download = imgFilename; a.click() }
        },
        {
          icon: this.icons.link,
          label: "Copy Image Link",
          action: () => navigator.clipboard.writeText(imgSrc)
        },
        { separator: true }
      )
    }

    // Pin/Unpin — available to manage_messages permission holders (server) or any DM participant
    const canPin = this.canManageMessages || messageEl.closest("[data-controller~='dm-message-form']")
    if (canPin && !messageEl.dataset.systemMessage) {
      const isPinned = messageEl.dataset.pinned === "true"
      const pinUrl = messageEl.dataset.pinUrl
      if (pinUrl) {
        items.push({
          icon: this.icons.pin,
          label: isPinned ? "Unpin Message" : "Pin Message",
          action: () => {
            const token = document.querySelector("meta[name=csrf-token]")?.content
            fetch(pinUrl, { method: "POST", headers: { "X-CSRF-Token": token } })
          }
        })
      }
    }

    if (isAuthor) {
      const isSticker = messageEl.dataset.isSticker === "true"
      items.push({ separator: true })
      if (!isSticker) {
        items.push({
          icon: this.icons.edit,
          label: "Edit Message",
          action: () => this.editMessage(messageId)
        })
      }
      items.push({
        icon: this.icons.trash,
        label: "Delete Message",
        danger: true,
        action: () => this.deleteMessage(messageId, true)
      })
    } else if (this.canManageMessages) {
      items.push({ separator: true })
      items.push({
        icon: this.icons.trash,
        label: "Delete Message",
        danger: true,
        action: () => this.deleteMessage(messageId, true)
      })
    }

    this.renderContextMenu(x, y, items)
  }

  async viewReactions(messageId) {
    const channelId = document.querySelector("[data-current-channel-id]")?.dataset?.currentChannelId
    try {
      const res = await fetch(`/channels/${channelId}/messages/${messageId}/reactions_list`)
      if (!res.ok) return
      const data = await res.json()
      if (!data.length) {
        this.showToast("No reactions on this message")
        return
      }
      const overlay = document.createElement("div")
      overlay.className = "modal-overlay fixed inset-0 z-[200] bg-black/60 flex items-center justify-center"
      overlay.addEventListener("click", (e) => { if (e.target === overlay) overlay.remove() })
      const modalClone = document.getElementById("tpl-reactions-modal").content.cloneNode(true)
      const body = modalClone.querySelector('[data-slot="body"]')
      data.forEach(group => {
        const groupClone = document.getElementById("tpl-reaction-group").content.cloneNode(true)
        groupClone.querySelector('[data-slot="emoji"]').textContent = group.emoji
        groupClone.querySelector('[data-slot="count"]').textContent = group.users.length
        const usersContainer = groupClone.querySelector('[data-slot="users"]')
        group.users.forEach(name => {
          const userClone = document.getElementById("tpl-reaction-user").content.cloneNode(true)
          userClone.querySelector('[data-slot="name"]').textContent = name
          usersContainer.appendChild(userClone)
        })
        body.appendChild(groupClone)
      })
      modalClone.querySelector('[data-slot="close"]').addEventListener("click", () => overlay.remove())
      overlay.appendChild(modalClone)
      document.body.appendChild(overlay)
      const onKey = (e) => { if (e.key === "Escape") { overlay.remove(); document.removeEventListener("keydown", onKey) } }
      document.addEventListener("keydown", onKey)
    } catch (e) {
      console.error("Failed to fetch reactions:", e)
    }
  }

  editMessage(messageId) {
    const messageEl = document.querySelector(`[data-message-id="${messageId}"]`)
    if (!messageEl) return
    if (messageEl.dataset.isSticker === "true") return
    const contentEl = messageEl.querySelector(".message-content")
    if (!contentEl) return

    const currentText = contentEl.dataset.rawContent || contentEl.textContent.trim()
    const preview = currentText.substring(0, 80) + (currentText.length > 80 ? "..." : "")

    document.dispatchEvent(new CustomEvent("inferno:edit", {
      detail: { messageId, content: currentText, preview },
      bubbles: true
    }))
  }

  async deleteMessage(messageId, skipConfirm = false) {
    if (!skipConfirm && !(await this.showConfirm("Delete Message", "Are you sure you want to delete this message? This cannot be undone."))) return
    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    const channelId = document.querySelector("[data-current-channel-id]")?.dataset?.currentChannelId
    const conversationId = document.querySelector("[data-dm-message-form-conversation-id-value]")?.dataset?.dmMessageFormConversationIdValue

    let url
    if (channelId) {
      url = `/channels/${channelId}/messages/${messageId}`
    } else if (conversationId) {
      url = `/conversations/${conversationId}/dm_messages/${messageId}`
    } else {
      console.error("[deleteMessage] No channelId or conversationId found")
      return
    }

    try {
      const res = await fetch(url, {
        method: "DELETE",
        headers: { "X-CSRF-Token": csrf }
      })
      if (res.ok) {
        // Also remove from DOM immediately as a fallback
        const el = document.getElementById(`message_${messageId}`)
        if (el) el.remove()
      } else {
        console.error(`[deleteMessage] Failed: ${res.status} ${res.statusText}`)
      }
    } catch (err) {
      console.error("[deleteMessage] Error:", err)
    }
  }

    renderContextMenu(x, y, items) {
    const menu = document.createElement("div")
    menu.className = "fixed z-[100] bg-gray-900 border border-gray-700 rounded-lg shadow-xl py-1.5 px-1.5 min-w-[200px] context-pop"
    menu.id = "notif-context-menu"
    menu.style.left = `${x}px`
    menu.style.top = `${y}px`

    items.forEach(item => {
      if (item.separator) {
        const sep = document.createElement("div")
        sep.className = "border-t border-gray-700 my-1"
        menu.appendChild(sep)
        return
      }

      // Support raw DOM element items (e.g. volume sliders)
      if (item.customEl) {
        menu.appendChild(item.customEl)
        return
      }

      const btn = document.createElement("button")
      const baseClass = "flex items-center w-full px-2.5 py-1.5 text-sm rounded cursor-pointer"
      if (item.disabled) {
        btn.className = `${baseClass} text-gray-500 cursor-not-allowed`
      } else if (item.danger) {
        btn.className = `${baseClass} text-danger-light hover:bg-danger/20 hover:text-danger`
      } else {
        btn.className = `${baseClass} text-gray-300 hover:bg-gray-700 hover:text-white`
      }

      btn.innerHTML = `${item.icon}${item.label}${item.disabled ? '<span class="ml-auto text-xs text-gray-600">Soon</span>' : ''}`

      if (!item.disabled && item.action) {
        btn.addEventListener("click", async () => {
          this.closeMenu()
          try {
            await item.action()
          } catch (err) {
            console.error("[contextMenu] Action error:", err)
          }
        })
      }
      menu.appendChild(btn)
    })

    document.body.appendChild(menu)

    // Keep fully within viewport
    const pad = 24
    const rect = menu.getBoundingClientRect()
    let left = x
    let top = y
    if (left + rect.width > window.innerWidth - pad) left = window.innerWidth - rect.width - pad
    if (left < pad) left = pad
    if (top + rect.height > window.innerHeight - pad) top = y - rect.height
    if (top < pad) top = pad
    menu.style.left = `${left}px`
    menu.style.top = `${top}px`
  }

  closeMenu() {
    const existing = document.getElementById("notif-context-menu")
    if (existing) existing.remove()
    const moveDD = document.querySelector("[data-voice-move-dropdown]")
    if (moveDD) moveDD.remove()
  }

  // ---- Ember Volume Helpers ----

  _isDescendantOfChannel(childEl, ancestorChannelId) {
    // Walk up nested .voice-child-channels containers checking if any parent matches
    let container = childEl.closest(".voice-child-channels")
    while (container) {
      let sibling = container.previousElementSibling
      while (sibling) {
        if (sibling.dataset?.channelId === ancestorChannelId) return true
        sibling = sibling.previousElementSibling
      }
      // Go up another level
      container = container.parentElement?.closest(".voice-child-channels")
    }
    return false
  }

  _buildChildVolumeSlider(childChannelId) {
    const wrapper = document.createElement("div")
    wrapper.className = "px-2.5 py-1.5"

    const row = document.createElement("div")
    row.className = "flex items-center justify-between mb-1"

    const label = document.createElement("span")
    label.className = "text-gray-400 text-xs"
    label.textContent = "Monitor Volume"

    const volLabel = document.createElement("span")
    volLabel.className = "text-gray-500 text-[10px] shrink-0"
    const saved = localStorage.getItem(`monitor-vol-${childChannelId}`)
    volLabel.textContent = `${saved ?? 80}%`

    row.appendChild(label)
    row.appendChild(volLabel)
    wrapper.appendChild(row)

    const slider = document.createElement("input")
    slider.type = "range"
    slider.min = "0"
    slider.max = "100"
    slider.value = saved ?? "80"
    slider.className = "w-full h-1 accent-accent cursor-pointer"

    slider.addEventListener("input", (e) => {
      e.stopPropagation()
      const vol = parseInt(slider.value, 10)
      volLabel.textContent = `${vol}%`
      localStorage.setItem(`monitor-vol-${childChannelId}`, vol)
      // Update the voice channel controller's monitor volume if active
      const voiceCtrl = document.querySelector("[data-controller~='voice-channel']")
      if (voiceCtrl) {
        const controller = this.application.getControllerForElementAndIdentifier(voiceCtrl, "voice-channel")
        if (controller?._monitoredRooms?.has(childChannelId)) {
          controller.setMonitorVolume({
            target: { dataset: { monitorVolumeChannel: childChannelId }, value: String(vol) }
          })
        }
      }
    })

    // Prevent menu from closing when interacting with slider
    slider.addEventListener("click", e => e.stopPropagation())
    slider.addEventListener("mousedown", e => e.stopPropagation())

    wrapper.appendChild(slider)
    return wrapper
  }

  // ---- Actions ----

  async markAsRead({ serverId, channelId }) {
    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    const params = new URLSearchParams()
    if (serverId) params.append("server_id", serverId)
    if (channelId) params.append("channel_id", channelId)

    await fetch("/notifications/mark_read", {
      method: "POST",
      headers: { "X-CSRF-Token": csrf, "Content-Type": "application/x-www-form-urlencoded" },
      body: params.toString()
    })

    if (channelId) {
      this.removeBadge("channel", channelId)
      this.removeChannelUnread(channelId)
      if (serverId) {
        this.recountServerBadge(serverId)
        this.recountServerUnread(serverId)
      }
    } else if (serverId) {
      this.removeServerBadge(serverId)
      // Mark all channels in sidebar as read
      document.querySelectorAll("[data-channel-id]").forEach(el => {
        this.removeChannelUnread(el.dataset.channelId)
      })
      this.removeServerUnread(serverId)
    }
  }

  async deleteChannel(serverId, channelId) {
    if (!(await this.showConfirm("Delete Channel", "Are you sure? All messages in this channel will be permanently deleted."))) return
    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    const res = await fetch(`/servers/${serverId}/channels/${channelId}/quick_delete`, {
      method: "DELETE",
      headers: { "X-CSRF-Token": csrf }
    })
    if (res.ok) {
      const el = document.querySelector(`[data-channel-id="${channelId}"]`)
      if (el) el.remove()
    }
  }

  async deleteCategory(serverId, categoryId) {
    if (!(await this.showConfirm("Delete Category", "Are you sure? Channels in this category will become uncategorized."))) return
    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    const res = await fetch(`/servers/${serverId}/categories/${categoryId}/quick_delete`, {
      method: "DELETE",
      headers: { "X-CSRF-Token": csrf }
    })
    if (res.ok) {
      const el = document.querySelector(`[data-category-id="${categoryId}"]`)
      if (el) {
        const channels = el.querySelectorAll("[data-channel-id]")
        const firstCategory = document.querySelector("[data-category-id]")
        channels.forEach(ch => {
          if (firstCategory && firstCategory !== el) firstCategory.before(ch)
          else document.querySelector("[data-controller*='channel-sidebar']")?.prepend(ch)
        })
        el.remove()
      }
    }
  }

  // ---- User Card + Profile Overlay ----

  _onUserCardClick(e) {
    // Don't trigger on right-clicks
    if (e.button && e.button !== 0) return

    // Don't intercept clicks inside existing cards/overlays
    if (e.target.closest("[data-profile-card]") || e.target.closest("[data-profile-overlay]")) return

    // Find the clicked element: avatar/username with data-msg-user-id, OR a rendered mention span
    const trigger = e.target.closest("[data-msg-user-id]") || e.target.closest(".mention[data-user-id]")
    if (!trigger) return

    e.preventDefault()

    const userId = trigger.dataset.msgUserId || trigger.dataset.userId
    if (!userId) return

    // Close any existing user card or profile card
    this._closeUserCard()
    document.querySelectorAll("[data-profile-card]").forEach(el => el.remove())

    const serverId = document.querySelector("[data-current-server-id]")?.dataset?.currentServerId
    const url = `/users/${userId}/card` + (serverId ? `?server_id=${serverId}` : "")

    fetch(url, { headers: { "X-Requested-With": "XMLHttpRequest" } })
      .then(res => { if (!res.ok) throw new Error(); return res.text() })
      .then(html => {
        this._userCard = document.createElement("div")
        this._userCard.className = "fixed z-50 context-pop"
        this._userCard.setAttribute("data-profile-card", "")
        this._userCard.innerHTML = html

        document.body.appendChild(this._userCard)

        // Position relative to the clicked element
        const rect = trigger.getBoundingClientRect()
        positionPopup(this._userCard, rect, {
          preferredSide: "below",
          horizontalAlign: "left"
        })

        // Bind avatar click to open full profile overlay
        const avatarTrigger = this._userCard.querySelector("[data-profile-overlay-trigger]")
        if (avatarTrigger) {
          avatarTrigger.addEventListener("click", (evt) => {
            evt.stopPropagation()
            const uid = avatarTrigger.dataset.userId
            const sid = avatarTrigger.dataset.serverId
            this._closeUserCard()
            this._openProfileOverlay(uid, sid)
          })
        }

        // Close on outside click (delayed to not close immediately)
        this._userCardCloseHandler = (evt) => {
          if (this._userCard && !this._userCard.contains(evt.target) && !evt.target.closest("[data-msg-user-id]")) {
            this._closeUserCard()
          }
        }
        setTimeout(() => document.addEventListener("click", this._userCardCloseHandler), 10)
      })
      .catch(() => {})
  }

  _closeUserCard() {
    if (this._userCard) {
      this._userCard.remove()
      this._userCard = null
    }
    if (this._userCardCloseHandler) {
      document.removeEventListener("click", this._userCardCloseHandler)
      this._userCardCloseHandler = null
    }
  }

  _openProfileOverlay(userId, serverId) {
    this._closeProfileOverlay()
    this._closeUserCard()

    const url = `/users/${userId}/card.json` + (serverId ? `?server_id=${serverId}` : "")

    fetch(url, { headers: { "Accept": "application/json" } })
      .then(res => { if (!res.ok) throw new Error(); return res.json() })
      .then(data => {
        const tpl = document.getElementById("tpl-profile-overlay")
        if (!tpl) return
        const clone = tpl.content.cloneNode(true)
        const overlay = clone.querySelector("[data-profile-overlay]")

        // Banner
        const bannerSlot = overlay.querySelector('[data-slot="banner"]')
        if (data.banner_url) {
          bannerSlot.innerHTML = `<img src="${this._escHtml(data.banner_url)}" class="w-full h-full object-cover" style="object-position: center ${data.banner_offset_y || 0}px;">`
        }

        // Body background gradient
        const bodyBg = overlay.querySelector('[data-slot="body-bg"]')
        const c1 = data.profile_color || "#1e1c1b"
        const c2 = data.profile_color_2 || c1
        bodyBg.style.cssText = c1 === c2 ? `background-color: ${c1};` : `background: linear-gradient(135deg, ${c1}, ${c2});`

        // Avatar ring color
        const avatarRing = overlay.querySelector('[data-slot="avatar-ring"]')
        avatarRing.style.background = c2

        // Avatar
        const avatarSlot = overlay.querySelector('[data-slot="avatar"]')
        if (data.avatar_url) {
          avatarSlot.outerHTML = `<img src="${this._escHtml(data.avatar_url)}" class="w-full h-full rounded-full object-cover">`
        } else {
          avatarSlot.textContent = data.username[0].toUpperCase()
          avatarSlot.style.backgroundColor = c1
        }

        // Status dot
        const statusDot = overlay.querySelector('[data-slot="status-dot"]')
        const statusColors = { online: "bg-green-500", idle: "bg-warning", dnd: "bg-red-500" }
        statusDot.className = `absolute bottom-[3px] left-[63px] w-[22px] h-[22px] rounded-full border-[4px] ${statusColors[data.online_state] || "bg-gray-500"}`
        statusDot.style.borderColor = c2

        // Name, tag
        overlay.querySelector('[data-slot="display-name"]').textContent = data.display_name
        overlay.querySelector('[data-slot="tag"]').textContent = data.tag

        // Status
        if (data.status) {
          const statusSection = overlay.querySelector('[data-slot="status-section"]')
          statusSection.classList.remove("hidden")
          overlay.querySelector('[data-slot="status"]').textContent = `${data.status_emoji || ""} ${data.status}`.trim()
        }

        // Bio
        if (data.bio) {
          const bioSection = overlay.querySelector('[data-slot="bio-section"]')
          bioSection.classList.remove("hidden")
          overlay.querySelector('[data-slot="bio"]').textContent = data.bio
        }

        // Roles
        if (data.roles && data.roles.length > 0) {
          const rolesSection = overlay.querySelector('[data-slot="roles-section"]')
          rolesSection.classList.remove("hidden")
          const rolesContainer = overlay.querySelector('[data-slot="roles"]')
          data.roles.forEach(role => {
            const span = document.createElement("span")
            span.className = "inline-flex items-center px-1.5 py-0.5 rounded text-[11px] font-medium bg-black/30 text-white/80 border border-white/10"
            span.innerHTML = `<span class="w-2 h-2 rounded-full mr-1" style="background-color: ${this._escHtml(role.color)}"></span>${this._escHtml(role.name)}`
            rolesContainer.appendChild(span)
          })
        }

        // Member since
        if (data.member_since) {
          const memberSection = overlay.querySelector('[data-slot="member-since-section"]')
          memberSection.classList.remove("hidden")
          overlay.querySelector('[data-slot="member-since"]').textContent = data.member_since
        }

        // Account created
        overlay.querySelector('[data-slot="account-created"]').textContent = data.account_created

        // Friend actions
        if (!data.is_self && data.nostr_pubkey) {
          const friendSection = overlay.querySelector('[data-slot="friend-actions"]')
          friendSection.classList.remove("hidden")
          const btnContainer = overlay.querySelector('[data-slot="friend-buttons"]')

          if (data.friendship_status === "accepted") {
            const btn = document.createElement("button")
            btn.className = "flex-1 py-1.5 text-sm text-danger-light hover:bg-danger/20 rounded cursor-pointer"
            btn.textContent = "Remove Friend"
            btn.addEventListener("click", () => this._friendAction("DELETE", `/friendships/${data.contact_id}`, btn, friendSection))
            btnContainer.appendChild(btn)
          } else if (data.friendship_status === "pending_outgoing") {
            const span = document.createElement("span")
            span.className = "flex-1 text-center py-1.5 text-sm text-gray-500"
            span.textContent = "Friend Request Sent"
            btnContainer.appendChild(span)
          } else if (data.friendship_status === "pending_incoming") {
            const acceptBtn = document.createElement("button")
            acceptBtn.className = "flex-1 py-1.5 text-sm text-green-400 hover:bg-green-600/20 rounded cursor-pointer"
            acceptBtn.textContent = "Accept Request"
            acceptBtn.addEventListener("click", () => this._friendAction("POST", `/friendships/${data.contact_id}/accept`, acceptBtn, friendSection))
            btnContainer.appendChild(acceptBtn)

            const declineBtn = document.createElement("button")
            declineBtn.className = "flex-1 py-1.5 text-sm text-gray-400 hover:bg-gray-700 rounded cursor-pointer"
            declineBtn.textContent = "Decline"
            declineBtn.addEventListener("click", () => this._friendAction("POST", `/friendships/${data.contact_id}/decline`, declineBtn, friendSection))
            btnContainer.appendChild(declineBtn)
          } else {
            const btn = document.createElement("button")
            btn.className = "flex-1 py-1.5 text-sm text-white bg-accent hover:bg-accent-light rounded cursor-pointer font-medium"
            btn.textContent = "Add Friend"
            btn.addEventListener("click", () => this._friendAction("POST", "/friendships", btn, friendSection, { tag: data.nostr_pubkey }))
            btnContainer.appendChild(btn)
          }
        }

        // Close handlers
        const closeBtn = overlay.querySelector('[data-slot="close"]')
        closeBtn.addEventListener("click", () => this._closeProfileOverlay())
        overlay.addEventListener("click", (evt) => {
          if (evt.target === overlay) this._closeProfileOverlay()
        })

        this._profileOverlay = overlay
        document.body.appendChild(overlay)

        this._profileOverlayEscHandler = (evt) => {
          if (evt.key === "Escape") this._closeProfileOverlay()
        }
        document.addEventListener("keydown", this._profileOverlayEscHandler)
      })
      .catch(() => {})
  }

  _closeProfileOverlay() {
    if (this._profileOverlay) {
      this._profileOverlay.remove()
      this._profileOverlay = null
    }
    if (this._profileOverlayEscHandler) {
      document.removeEventListener("keydown", this._profileOverlayEscHandler)
      this._profileOverlayEscHandler = null
    }
  }

  async _friendAction(method, url, btn, section, body = {}) {
    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    btn.disabled = true
    btn.textContent = "..."
    try {
      const opts = {
        method,
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json", "Accept": "application/json" },
      }
      if (method !== "DELETE" && Object.keys(body).length) opts.body = JSON.stringify(body)
      const res = await fetch(url, opts)
      const data = await res.json()
      const container = section.querySelector('[data-slot="friend-buttons"]')
      container.innerHTML = ""
      const msg = document.createElement("span")
      msg.className = "flex-1 text-center py-1.5 text-sm text-gray-400"
      msg.textContent = data.status === "sent" ? "Request Sent" : data.status === "accepted" ? "Friends" : "Done"
      container.appendChild(msg)
    } catch {
      btn.disabled = false
      btn.textContent = "Error — try again"
    }
  }

  _updateUserPresence(data) {
    const colorMap = { online: "bg-green-500", idle: "bg-warning", dnd: "bg-red-500", offline: "bg-gray-500" }
    const cls = colorMap[data.state] || "bg-gray-500"
    const allColors = ["bg-green-500", "bg-warning", "bg-red-500", "bg-gray-500"]

    // Update sidebar/friends list presence dots
    document.querySelectorAll(`[data-user-presence="${data.user_id}"]`).forEach(dot => {
      dot.classList.remove(...allColors)
      dot.classList.add(cls)
    })

    // Update text labels (friends list "Online"/"Offline" etc.)
    document.querySelectorAll(`[data-user-presence-text="${data.user_id}"]`).forEach(el => {
      const state = data.state
      el.textContent = state && state !== "offline" ? state.charAt(0).toUpperCase() + state.slice(1) : "Offline"
    })

    // If on the Online friends tab, refresh to add/remove the user from the list
    if (this._isOnContactsTab("online")) {
      this._scheduleContactsRefresh()
    }
  }

  // Handle friend_update notifications (friendship status changed)
  _handleFriendUpdate(data) {
    // Update the pending count badge on the tab
    if (data.pending_count !== undefined) {
      this._updatePendingBadge(data.pending_count)
    }
    // Refresh the contacts page content
    this._scheduleContactsRefresh()
  }

  // Check if we're on a specific contacts tab
  _isOnContactsTab(tabName) {
    const url = new URL(window.location.href)
    const tab = url.searchParams.get("tab")
    // The contacts page is conversations#index with a tab param
    const onContactsPage = document.getElementById("main-content") && url.pathname === "/conversations"
    if (!tabName) return onContactsPage
    return onContactsPage && tab === tabName
  }

  // Debounced contacts page refresh
  _scheduleContactsRefresh() {
    if (!document.getElementById("main-content")) return
    if (this._contactsRefreshTimer) clearTimeout(this._contactsRefreshTimer)
    this._contactsRefreshTimer = setTimeout(() => {
      this._contactsRefreshTimer = null
      const frame = document.getElementById("main-content")
      if (frame) {
        frame.src = window.location.href
      }
    }, 300)
  }

  // Update the pending count badge in the tab bar
  _updatePendingBadge(count) {
    // Find the Pending tab link and update its badge
    const pendingLinks = document.querySelectorAll('a[href*="tab=pending"]')
    pendingLinks.forEach(link => {
      let badge = link.querySelector("span")
      if (count > 0) {
        if (!badge) {
          badge = document.createElement("span")
          badge.className = "ml-1 bg-accent text-white text-xs rounded-full px-1.5 min-w-[18px] inline-flex items-center justify-center"
          link.appendChild(badge)
        }
        badge.textContent = count
      } else if (badge) {
        badge.remove()
      }
    })
  }

  _escHtml(str) {
    const div = document.createElement("div")
    div.textContent = str || ""
    return div.innerHTML
  }

  // ---- Icon SVGs ----

  get icons() {
    return {
      check: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/></svg>',
      bell: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"/></svg>',
      link: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-1.102-4.243a4 4 0 015.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"/></svg>',
      copy: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>',
      edit: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"/></svg>',
      trash: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/></svg>',
      reply: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 10h10a8 8 0 018 8v2M3 10l6 6m-6-6l6-6"/></svg>',
      react: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14.828 14.828a4 4 0 01-5.656 0M9 10h.01M15 10h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>',
      plus: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/></svg>',
      pin: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 12V4h1V2H7v2h1v8l-2 2v2h5.2v6h1.6v-6H18v-2l-2-2z"/></svg>',
      leave: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"/></svg>',
      userMinus: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 7a4 4 0 11-8 0 4 4 0 018 0zM9 14a6 6 0 00-6 6v1h12v-1a6 6 0 00-6-6zM21 12h-6"/></svg>',
      decline: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>',
      block: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728A9 9 0 015.636 5.636m12.728 12.728L5.636 5.636"/></svg>'
    }
  }

  showConfirm(title, message, confirmText = "Delete", confirmClass = "bg-gradient-to-r from-danger-dark to-danger hover:from-danger hover:to-danger-light") {
    return new Promise((resolve) => {
      const overlay = document.createElement("div")
      overlay.className = "modal-overlay fixed inset-0 z-[200] bg-black/70 flex items-center justify-center"
      overlay.id = "confirm-modal"
      const tpl = document.getElementById("tpl-confirm-modal")
      const clone = tpl.content.cloneNode(true)
      clone.querySelector('[data-slot="title"]').textContent = title
      clone.querySelector('[data-slot="message"]').textContent = message
      const confirmBtn = clone.querySelector('[data-slot="confirm"]')
      confirmBtn.textContent = confirmText
      confirmBtn.className += ` ${confirmClass}`
      overlay.appendChild(clone)
      document.body.appendChild(overlay)
      const cleanup = (result) => { overlay.remove(); resolve(result) }
      overlay.querySelector('[data-slot="confirm"]').addEventListener("click", () => cleanup(true))
      overlay.querySelector('[data-slot="cancel"]').addEventListener("click", () => cleanup(false))
      overlay.addEventListener("click", (e) => { if (e.target === overlay) cleanup(false) })
      const escHandler = (e) => {
        if (e.key === "Escape") { cleanup(false); document.removeEventListener("keydown", escHandler) }
      }
      document.addEventListener("keydown", escHandler)
      overlay.querySelector('[data-slot="confirm"]').focus()
    })
  }
}
