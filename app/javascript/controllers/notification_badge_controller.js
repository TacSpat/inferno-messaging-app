import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"
import { positionPopup } from "../utils/popup_positioning"

export default class extends Controller {
  connect() {
    this.subscription = createConsumer().subscriptions.create(
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

  get currentServerId() {
    return document.querySelector("[data-current-server-id]")?.dataset?.currentServerId
  }

  // ---- Notification handling ----

  handleNotification(data) {
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
    } else if (data.type === "channel_message") {
      const selfId = document.body.dataset.currentUserId
      if (data.user_id && String(data.user_id) === String(selfId)) return
      const currentChannelId = document.querySelector("[data-current-channel-id]")?.dataset?.currentChannelId
      if (currentChannelId && String(data.channel_id) === String(currentChannelId)) return
      this.showChannelUnread(data.channel_id)
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
      badge.className = "home-badge mention-badge absolute -bottom-0.5 -right-0.5 min-w-[18px] h-[18px] bg-red-500 rounded-full flex items-center justify-center text-white text-xs font-bold px-1 border-2 border-gray-950"
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
      badge.className = "mention-badge ml-auto min-w-[18px] h-[18px] bg-red-500 rounded-full flex items-center justify-center text-white text-xs font-bold px-1 shrink-0"
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
      badge.className = "mention-badge absolute -bottom-0.5 -right-0.5 min-w-[18px] h-[18px] bg-red-500 rounded-full flex items-center justify-center text-white text-xs font-bold px-1 border-2 border-gray-950"
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
      badge.className = "mention-badge ml-auto min-w-[18px] h-[18px] bg-red-500 rounded-full flex items-center justify-center text-white text-xs font-bold px-1 shrink-0"
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
      pill.className = "unread-pill absolute -left-2 top-1/2 -translate-y-1/2 w-1 h-2 bg-red-500 rounded-r-full"
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
    if (serverIcon.classList.contains("from-red-700")) return
    const pill = document.createElement("div")
    pill.className = "server-unread-pill absolute -left-[10px] top-1/2 -translate-y-1/2 w-[3px] h-2 bg-red-500 rounded-r-full"
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
        html += `<img src="${u.avatar_url}" class="rounded-full object-cover shrink-0" style="width: 16px; height: 16px; ${offset} border: 1.5px solid #1e1c1b; position: relative; z-index: ${maxVisible - i};" alt="${u.username}">`
      } else {
        html += `<div class="rounded-full shrink-0 flex items-center justify-center text-white" style="width: 16px; height: 16px; font-size: 8px; ${offset} border: 1.5px solid #1e1c1b; position: relative; z-index: ${maxVisible - i}; background-color: ${u.avatar_color || '#b45309'};">${u.avatar_initial || '?'}</div>`
      }
    })
    if (extra > 0) {
      html += `<span class="text-[9px] text-gray-400 font-semibold" style="margin-left: 2px;">+${extra}</span>`
    }
    html += '</div>'
    // Animated dots
    html += '<span class="typing-dots" style="margin-left: 3px; font-size: 10px; color: #878583;"><span>.</span><span>.</span><span>.</span></span>'
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
      this.showConversationContextMenu(event.clientX, event.clientY, convEl.dataset.conversationId)
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
    if (channelEl && !event.target.closest("[data-voice-state-id]")) {
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

  showConversationContextMenu(x, y, conversationId) {
    const items = [
      {
        icon: this.icons.check,
        label: "Mark as Read",
        action: () => this.markDmsAsRead(conversationId)
      }
    ]
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

  showMessageContextMenu(x, y, messageEl, clickTarget) {
    const messageId = messageEl.dataset.messageId
    const serverId = this.currentServerId
    const currentUserId = document.body.dataset.currentUserId
    const authorEl = messageEl.querySelector(".text-red-400")
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
          const authorName = messageEl.querySelector(".text-red-400")?.textContent?.trim() || ""
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
          const sId = el ? el.dataset.currentServerId : ""
          const cId = el ? el.dataset.currentChannelId : ""
          const link = `${window.location.origin}/servers/${sId}/channels/${cId}#message-${messageId}`
          navigator.clipboard.writeText(link)
        }
      },
      {
        icon: this.icons.copy,
        label: "Copy Message ID",
        action: () => navigator.clipboard.writeText(messageId)
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

    if (isAuthor) {
      items.push({ separator: true })
      items.push({
        icon: this.icons.edit,
        label: "Edit Message",
        action: () => this.editMessage(messageId)
      })
      items.push({
        icon: this.icons.trash,
        label: "Delete Message",
        danger: true,
        action: () => this.deleteMessage(messageId, true)
      })
    } else if (this.canManage) {
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
    const contentEl = messageEl.querySelector(".message-content")
    if (!contentEl) return

    const currentText = contentEl.dataset.rawContent || contentEl.textContent.trim()
    const channelId = document.querySelector("[data-current-channel-id]")?.dataset?.currentChannelId

    contentEl.dataset.originalHtml = contentEl.innerHTML

    // Build edit form from template - only replaces text content, keeps attachments visible
    const editClone = document.getElementById("tpl-edit-form").content.cloneNode(true)
    const form = editClone.querySelector("form")
    form.dataset.editMessageId = messageId
    const input = editClone.querySelector("input")
    input.value = currentText
    input.setAttribute("autofocus", "")
    contentEl.innerHTML = ""
    contentEl.appendChild(editClone)

    // Add remove buttons to image attachments (not video/audio)
    const fileContainer = messageEl.querySelector(".flex.flex-wrap.gap-2.mt-2")
    const removeFileIds = []
    if (fileContainer) {
      fileContainer.querySelectorAll("img").forEach(img => {
        const wrapper = img.parentElement
        // Skip if already has a remove button
        if (wrapper.querySelector(".remove-attachment-btn")) return
        wrapper.style.position = "relative"
        const removeBtn = document.createElement("button")
        removeBtn.type = "button"
        removeBtn.className = "remove-attachment-btn absolute top-1 right-1 bg-red-600 hover:bg-red-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-xs font-bold z-10"
        removeBtn.innerHTML = "\u00d7"
        removeBtn.addEventListener("click", () => {
          // Find the file ID from the image src (Active Storage blob URL)
          const src = img.dataset.previewSrc || img.src
          const blobMatch = src.match(/\/blobs\/([^\/]+)/)
          if (blobMatch) {
            // Store blob signed_id to remove
            removeBtn.dataset.blobId = blobMatch[1]
          }
          // Also try to get attachment ID from data attribute
          const attachId = img.closest("[data-attachment-id]")?.dataset?.attachmentId
          if (attachId) removeFileIds.push(attachId)
          wrapper.style.opacity = "0.3"
          wrapper.style.pointerEvents = "none"
          removeBtn.remove()
        })
        wrapper.appendChild(removeBtn)
      })
    }

    const cancelBtn = contentEl.querySelector(".cancel-edit-btn")
    cancelBtn.addEventListener("click", () => {
      contentEl.innerHTML = contentEl.dataset.originalHtml
      // Restore any hidden attachments
      if (fileContainer) {
        fileContainer.querySelectorAll(".remove-attachment-btn").forEach(b => b.remove())
        fileContainer.querySelectorAll("[style]").forEach(el => {
          el.style.opacity = ""
          el.style.pointerEvents = ""
          el.style.position = ""
        })
      }
    })

    const editInput = contentEl.querySelector("input")
    editInput.focus()
    editInput.setSelectionRange(editInput.value.length, editInput.value.length)

    const editForm = contentEl.querySelector("form")
    editForm.addEventListener("submit", async (e) => {
      e.preventDefault()
      const newContent = editInput.value.trim()
      if (!newContent && removeFileIds.length === 0) {
        if (await this.showConfirm("Delete Message", "Message is empty. Delete this message?")) {
          contentEl.innerHTML = contentEl.dataset.originalHtml
          this.deleteMessage(messageId, true)
        }
        return
      }
      const csrf = document.querySelector("meta[name=csrf-token]")?.content
      const payload = { message: { content: newContent } }
      if (removeFileIds.length > 0) {
        payload.message.remove_file_ids = removeFileIds
      }
      // Also collect blob-based removals
      const blobBtns = fileContainer?.querySelectorAll("[style*=\"opacity: 0.3\"]")
      const res = await fetch(`/channels/${channelId}/messages/${messageId}`, {
        method: "PATCH",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json", "Accept": "text/html" },
        body: JSON.stringify(payload)
      })
      if (res.ok) {
        // ActionCable will broadcast the update
      }
    })

    // ESC to cancel
    editInput.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        cancelBtn.click()
      }
    })
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
      return
    }

    await fetch(url, {
      method: "DELETE",
      headers: { "X-CSRF-Token": csrf }
    })
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

      const btn = document.createElement("button")
      const baseClass = "flex items-center w-full px-2.5 py-1.5 text-sm rounded cursor-pointer"
      if (item.disabled) {
        btn.className = `${baseClass} text-gray-500 cursor-not-allowed`
      } else if (item.danger) {
        btn.className = `${baseClass} text-red-400 hover:bg-red-600/20 hover:text-red-300`
      } else {
        btn.className = `${baseClass} text-gray-300 hover:bg-gray-700 hover:text-white`
      }

      btn.innerHTML = `${item.icon}${item.label}${item.disabled ? '<span class="ml-auto text-xs text-gray-600">Soon</span>' : ''}`

      if (!item.disabled && item.action) {
        btn.addEventListener("click", () => {
          item.action()
          this.closeMenu()
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
        const statusColors = { online: "bg-green-500", idle: "bg-yellow-500", dnd: "bg-red-500" }
        statusDot.className = `absolute bottom-[3px] left-[63px] w-[22px] h-[22px] rounded-full border-[4px] ${statusColors[data.online_state] || "bg-gray-500"}`
        statusDot.style.borderColor = c2

        // Name, tag
        overlay.querySelector('[data-slot="display-name"]').textContent = data.display_name
        overlay.querySelector('[data-slot="tag"]').textContent = data.tag

        // Remote badge
        if (data.remote) {
          const remoteBadge = overlay.querySelector('[data-slot="remote-badge"]')
          remoteBadge.classList.remove("hidden")
          remoteBadge.classList.add("flex")
          overlay.querySelector('[data-slot="remote-domain"]').textContent = data.home_instance_domain
        }

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
      plus: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/></svg>'
    }
  }

  showConfirm(title, message, confirmText = "Delete", confirmClass = "bg-gradient-to-r from-red-700 to-red-500 hover:from-red-600 hover:to-red-400") {
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
