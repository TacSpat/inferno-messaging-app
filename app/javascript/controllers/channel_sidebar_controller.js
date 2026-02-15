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

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
