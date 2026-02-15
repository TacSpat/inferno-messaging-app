import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

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

    // Clean up dynamic badges before Turbo caches the page snapshot
    this._beforeCache = () => this._cleanupForCache()
    document.addEventListener("turbo:before-cache", this._beforeCache)

    // Clear badges for the current channel on every Turbo render (channel switch)
    this._onRender = () => this.clearCurrentChannelBadges()
    document.addEventListener("turbo:render", this._onRender)
  }

  disconnect() {
    if (this.subscription) this.subscription.unsubscribe()
    document.removeEventListener("contextmenu", this.handleContextMenu)
    document.removeEventListener("click", this.closeMenu)
    this.closeMenu()
    if (this._beforeCache) document.removeEventListener("turbo:before-cache", this._beforeCache)
    if (this._onRender) document.removeEventListener("turbo:render", this._onRender)
    if (this.sidebarTyping) {
      this.sidebarTyping.forEach(users => users.forEach(u => clearTimeout(u.timeout)))
      this.sidebarTyping.clear()
    }
  }

  _cleanupForCache() {
    // Remove all JS-added dynamic indicators so the Turbo cache snapshot is clean
    document.querySelectorAll(".typing-indicator").forEach(el => el.remove())
    document.querySelectorAll(".server-unread-pill").forEach(el => el.remove())
    // Remove all mention badges (red notification dots) from channels and servers
    document.querySelectorAll(".mention-badge").forEach(el => el.remove())
    // Remove home badge
    document.querySelectorAll(".home-badge").forEach(el => el.remove())
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
      pill.className = "unread-pill absolute -left-2 top-1/2 -translate-y-1/2 w-1 h-2 bg-gray-300 rounded-r-full"
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
    if (serverIcon.classList.contains("bg-orange-600")) return
    const pill = document.createElement("div")
    pill.className = "server-unread-pill absolute left-0 top-1/2 -translate-x-[22px] -translate-y-1/2 w-1 h-2 bg-white rounded-r-full"
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
        html += `<img src="${u.avatar_url}" class="rounded-full object-cover shrink-0" style="width: 16px; height: 16px; ${offset} border: 1.5px solid #2b2d31; position: relative; z-index: ${maxVisible - i};" alt="${u.username}">`
      } else {
        html += `<div class="rounded-full shrink-0 flex items-center justify-center text-white" style="width: 16px; height: 16px; font-size: 8px; ${offset} border: 1.5px solid #2b2d31; position: relative; z-index: ${maxVisible - i}; background-color: ${u.avatar_color || '#5865f2'};">${u.avatar_initial || '?'}</div>`
      }
    })
    if (extra > 0) {
      html += `<span class="text-[9px] text-gray-400 font-semibold" style="margin-left: 2px;">+${extra}</span>`
    }
    html += '</div>'
    // Animated dots
    html += '<span class="typing-dots" style="margin-left: 3px; font-size: 10px; color: #9ca3af;"><span>.</span><span>.</span><span>.</span></span>'
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

    // Channel item
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

    // Image inside message (delegate to image-preview controller)
    const imgEl = event.target.closest("img[data-preview-src]")
    if (imgEl) {
      // Let image_preview_controller handle it
      return
    }

    // Message
    const messageEl = event.target.closest("[data-message-id]")
    if (messageEl) {
      event.preventDefault()
      this.closeMenu()
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
    const authorEl = messageEl.querySelector(".text-orange-400")
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
          const authorName = messageEl.querySelector(".text-orange-400")?.textContent?.trim() || ""
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
          const event = new CustomEvent("inferno:react", { detail: { messageId }, bubbles: true })
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
        icon: '🔍',
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
        action: () => this.deleteMessage(messageId)
      })
    } else if (this.canManage) {
      items.push({ separator: true })
      items.push({
        icon: this.icons.trash,
        label: "Delete Message",
        danger: true,
        action: () => this.deleteMessage(messageId)
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
      // Build modal
      const overlay = document.createElement("div")
      overlay.className = "fixed inset-0 z-[200] bg-black/60 flex items-center justify-center"
      overlay.addEventListener("click", (e) => { if (e.target === overlay) overlay.remove() })
      const modal = document.createElement("div")
      modal.className = "bg-gray-800 rounded-lg shadow-xl max-w-sm w-full mx-4 overflow-hidden"
      let html = '<div class="px-4 py-3 border-b border-gray-700 flex items-center justify-between"><h3 class="text-white font-semibold">Reactions</h3><button class="text-gray-400 hover:text-white text-xl close-reactions-btn">&times;</button></div>'
      html += '<div class="px-4 py-3 max-h-80 overflow-y-auto space-y-3">'
      data.forEach(group => {
        html += `<div><div class="text-lg mb-1">${group.emoji} <span class="text-sm text-gray-400">${group.users.length}</span></div>`
        html += '<div class="space-y-1">'
        group.users.forEach(name => {
          html += `<div class="text-sm text-gray-300 pl-2">${name}</div>`
        })
        html += '</div></div>'
      })
      html += '</div>'
      modal.innerHTML = html
      overlay.appendChild(modal)
      document.body.appendChild(overlay)
      overlay.querySelector(".close-reactions-btn")?.addEventListener("click", () => overlay.remove())
      // ESC to close
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

    // Build edit form - only replaces text content, keeps attachments visible
    contentEl.innerHTML = `
      <form class="flex gap-2 items-center" data-edit-message-id="${messageId}">
        <input type="text" value="${currentText.replace(/"/g, "&quot;")}" 
               class="flex-1 bg-gray-900 border border-gray-600 rounded px-2 py-1 text-sm text-white focus:outline-none focus:border-indigo-500"
               autofocus>
        <button type="submit" class="text-xs text-green-400 hover:text-green-300">Save</button>
        <button type="button" class="text-xs text-gray-400 hover:text-gray-200 cancel-edit-btn">Cancel</button>
      </form>
    `

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

    const input = contentEl.querySelector("input")
    input.focus()
    input.setSelectionRange(input.value.length, input.value.length)

    const form = contentEl.querySelector("form")
    form.addEventListener("submit", async (e) => {
      e.preventDefault()
      const newContent = input.value.trim()
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
    input.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        cancelBtn.click()
      }
    })
  }

  async deleteMessage(messageId, skipConfirm = false) {
    if (!skipConfirm && !(await this.showConfirm("Delete Message", "Are you sure you want to delete this message? This cannot be undone."))) return
    const channelId = document.querySelector("[data-current-channel-id]")?.dataset?.currentChannelId
    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    await fetch(`/channels/${channelId}/messages/${messageId}`, {
      method: "DELETE",
      headers: { "X-CSRF-Token": csrf }
    })
  }

    renderContextMenu(x, y, items) {
    const menu = document.createElement("div")
    menu.className = "fixed z-[100] bg-gray-900 border border-gray-700 rounded-lg shadow-xl py-1.5 px-1.5 min-w-[200px]"
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

    // Keep in viewport
    const rect = menu.getBoundingClientRect()
    if (rect.right > window.innerWidth) menu.style.left = `${window.innerWidth - rect.width - 8}px`
    if (rect.bottom > window.innerHeight) menu.style.top = `${window.innerHeight - rect.height - 8}px`
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

  showConfirm(title, message, confirmText = "Delete", confirmClass = "bg-red-600 hover:bg-red-700") {
    return new Promise((resolve) => {
      const overlay = document.createElement("div")
      overlay.className = "fixed inset-0 z-[200] bg-black/70 flex items-center justify-center"
      overlay.id = "confirm-modal"
      const esc = (s) => { const d = document.createElement("div"); d.textContent = s; return d.innerHTML }
      overlay.innerHTML = `
        <div class="bg-gray-800 rounded-lg shadow-2xl w-full max-w-md mx-4 overflow-hidden">
          <div class="p-4">
            <h3 class="text-xl font-bold text-white mb-2">${esc(title)}</h3>
            <p class="text-sm text-gray-300">${esc(message)}</p>
          </div>
          <div class="px-4 py-3 flex justify-end gap-3" style="background-color: #2b2d31;">
            <button id="confirm-cancel" class="px-4 py-2 text-sm font-medium text-white hover:underline cursor-pointer">Cancel</button>
            <button id="confirm-ok" class="px-4 py-2 text-sm font-medium text-white rounded ${confirmClass} cursor-pointer">${esc(confirmText)}</button>
          </div>
        </div>
      `
      document.body.appendChild(overlay)
      const cleanup = (result) => { overlay.remove(); resolve(result) }
      overlay.querySelector("#confirm-ok").addEventListener("click", () => cleanup(true))
      overlay.querySelector("#confirm-cancel").addEventListener("click", () => cleanup(false))
      overlay.addEventListener("click", (e) => { if (e.target === overlay) cleanup(false) })
      const escHandler = (e) => {
        if (e.key === "Escape") { cleanup(false); document.removeEventListener("keydown", escHandler) }
      }
      document.addEventListener("keydown", escHandler)
      overlay.querySelector("#confirm-ok").focus()
    })
  }
}
