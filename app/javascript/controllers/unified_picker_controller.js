import { Controller } from "@hotwired/stimulus"
import { positionPopup } from "../utils/popup_positioning"

const LAST_TAB_KEY = "unified_picker_last_tab"
const FREQUENTLY_USED_KEY = "unified_picker_frequently_used"
const MAX_FREQUENT = 24

export default class extends Controller {
  static targets = ["panel", "input", "content", "searchInput", "tabGifs", "tabStickers", "tabEmoji"]
  static values = {
    serverId: String,
    canSendGifs: { type: Boolean, default: true },
    canSendCustomEmojis: { type: Boolean, default: true },
    canSendCustomStickers: { type: Boolean, default: true },
    serverName: String,
    userServers: String // JSON array of {id, name}
  }

  connect() {
    this.activeTab = localStorage.getItem(LAST_TAB_KEY) || "emoji"
    this.searchQuery = ""
    this.tenorPos = ""
    this.tenorLoading = false
    this.serverEmojisCache = {}
    this.serverStickersCache = {}
    this.userCollections = []
    this.userFavoriteIds = new Set()
    this.collapsedSections = JSON.parse(localStorage.getItem("picker_collapsed") || "{}")
    this.frequentlyUsed = JSON.parse(localStorage.getItem(FREQUENTLY_USED_KEY) || "[]")
      .filter(e => e.type !== "custom" || (e.url && e.url.length > 0))

    // GIF sub-view state: null = home, "_trending", or a collection public_id
    this.gifSubView = null
    // Cached favorites for the current collection (for local search)
    this.currentCollectionFavorites = null

    this.boundClose = this.closeOnClickOutside.bind(this)
    document.addEventListener("mousedown", this.boundClose)
    this.debounceTimer = null

    // Context menu dismiss handlers
    this.boundDismissCtxOnClick = (e) => {
      const menu = document.getElementById("gif-context-menu")
      if (!menu || !menu.contains(e.target)) this.dismissContextMenu()
    }
    this.boundDismissCtxOnKey = (e) => { if (e.key === "Escape") this.dismissContextMenu() }
    this.boundDismissCtxOnScroll = () => this.dismissContextMenu()

    // Listen for favorites changes from the message stream fire icon
    this.boundOnFavoritesChanged = (e) => {
      if (e.detail.source === "picker") return // ignore our own events
      const { gifId, favorited } = e.detail
      if (favorited) {
        this.userFavoriteIds.add(gifId)
      } else {
        this.userFavoriteIds.delete(gifId)
      }
      // Invalidate collection cache so it re-fetches on next view
      this.currentCollectionFavorites = null
      this._cachedCollectionId = null
      // If currently viewing a favorites collection, refresh it
      if (this.activeTab === "gifs" && this.gifSubView && this.gifSubView !== "_trending" && !this.panelTarget.classList.contains("hidden")) {
        this.loadCollectionGifs(this.gifSubView, this.searchQuery)
      }
    }
    document.addEventListener("gif-favorites-changed", this.boundOnFavoritesChanged)

    // Reaction mode state
    this._reactionMode = null // { reactionUrl, anchorSelector, messageId }
    this._openReactionPicker = (e) => {
      const { messageId, reactionUrl, anchorSelector, clientX, clientY } = e.detail
      this._reactionMode = { messageId, reactionUrl, anchorSelector, clientX, clientY }
      this.openInReactionMode()
    }
    document.addEventListener("inferno:open-reaction-picker", this._openReactionPicker)

    // Eagerly populate window._emojiMap so input previews work without opening the picker
    this._eagerLoadEmojiMap()
  }

  async _eagerLoadEmojiMap() {
    if (window._emojiMap && Object.keys(window._emojiMap).length > 0) return

    const serverIds = []
    if (this.hasServerIdValue && this.serverIdValue) {
      serverIds.push(this.serverIdValue)
    }
    if (this.hasUserServersValue && this.userServersValue) {
      try {
        const servers = JSON.parse(this.userServersValue)
        servers.forEach(s => { if (!serverIds.includes(String(s.id))) serverIds.push(String(s.id)) })
      } catch(e) {}
    }

    for (const serverId of serverIds) {
      await this.fetchServerEmojis(serverId)
    }
    // Notify form controllers that emoji maps are ready
    document.dispatchEvent(new CustomEvent('inferno:emoji-map-ready'))
  }

  disconnect() {
    document.removeEventListener("mousedown", this.boundClose)
    document.removeEventListener("gif-favorites-changed", this.boundOnFavoritesChanged)
    if (this._openReactionPicker) document.removeEventListener("inferno:open-reaction-picker", this._openReactionPicker)
    if (this.debounceTimer) clearTimeout(this.debounceTimer)
    this.dismissContextMenu()
  }

  toggle() {
    const panel = this.panelTarget
    const wasHidden = panel.classList.contains("hidden")
    if (wasHidden) {
      panel.classList.remove("hidden")
      panel.classList.add("context-pop")
      this.updateTabStyles()
      this.renderCurrentTab()
      if (this.hasSearchInputTarget) this.searchInputTarget.focus()
    } else {
      this.close()
    }
  }

  close() {
    if (this._reactionMode) {
      this._exitReactionMode()
      return
    }
    this.panelTarget.classList.add("hidden")
    this.panelTarget.classList.remove("context-pop")
  }

  closeOnClickOutside(event) {
    // In reaction mode, check the floating reaction panel
    if (this._reactionMode) {
      const reactionPanel = document.getElementById("reaction-picker-panel")
      if (reactionPanel && reactionPanel.contains(event.target)) return
      // Clicking a reaction button should not dismiss
      if (event.target.closest(".reaction-picker-btn")) return
      this._exitReactionMode()
      return
    }
    if (this.panelTarget.contains(event.target)) return
    const toggleBtn = this.panelTarget.parentElement
    if (toggleBtn && toggleBtn.contains(event.target)) return
    const ctxMenu = document.getElementById("gif-context-menu")
    if (ctxMenu && ctxMenu.contains(event.target)) return
    if (!this.panelTarget.classList.contains("hidden")) {
      this.close()
    }
  }

  switchTab(event) {
    const tab = event.currentTarget.dataset.tab
    if (this.activeTab === tab) return
    this.activeTab = tab
    localStorage.setItem(LAST_TAB_KEY, tab)
    this.searchQuery = ""
    this.tenorPos = ""
    this.gifSubView = null
    this.currentCollectionFavorites = null
    if (this.hasSearchInputTarget) this.searchInputTarget.value = ""

    this.updateTabStyles()
    this.renderCurrentTab()
  }

  updateTabStyles() {
    const tabs = { gifs: this.tabGifsTarget, stickers: this.tabStickersTarget, emoji: this.tabEmojiTarget }
    Object.entries(tabs).forEach(([name, el]) => {
      if (name === this.activeTab) {
        el.classList.add("text-white", "border-accent")
        el.classList.remove("text-gray-400", "border-transparent")
      } else {
        el.classList.remove("text-white", "border-accent")
        el.classList.add("text-gray-400", "border-transparent")
      }
    })
  }

  onSearch(event) {
    const query = event.target.value.trim()
    if (this.debounceTimer) clearTimeout(this.debounceTimer)
    this.debounceTimer = setTimeout(() => {
      this.searchQuery = query
      this.tenorPos = ""
      this.renderCurrentTab()
    }, this.activeTab === "gifs" ? 400 : 150)
  }

  clearSearch() {
    this.searchQuery = ""
    if (this.hasSearchInputTarget) this.searchInputTarget.value = ""
  }

  renderCurrentTab() {
    switch (this.activeTab) {
      case "gifs": this.renderGifsTab(); break
      case "stickers": this.renderStickersTab(); break
      case "emoji": this.renderEmojiTab(); break
    }
  }

  // ─── GIFs Tab ──────────────────────────────────────────────
  async renderGifsTab() {
    const content = this.contentTarget
    if (!this.canSendGifsValue) {
      content.innerHTML = `<div class="flex items-center justify-center h-32 text-gray-500 text-sm">You don't have permission to send GIFs</div>`
      return
    }

    await this.loadUserFavoriteIds()

    // If we're inside a collection/trending sub-view
    if (this.gifSubView) {
      if (this.gifSubView === "_trending") {
        if (this.searchQuery) {
          // Search Tenor instead of filtering trending
          this.showLoading()
          await this.searchTenor(this.searchQuery)
        } else {
          this.showLoading()
          await this.loadTrending()
        }
      } else {
        // Inside a favorites collection — search locally by description
        await this.loadCollectionGifs(this.gifSubView, this.searchQuery)
      }
      return
    }

    // Top-level: search goes to Tenor
    if (this.searchQuery) {
      this.showLoading()
      await this.searchTenor(this.searchQuery)
    } else {
      await this.renderGifHome()
    }
  }

  showLoading() {
    this.contentTarget.innerHTML = `<div class="flex items-center justify-center h-32 text-gray-500 text-sm"><svg class="w-5 h-5 animate-spin mr-2" fill="none" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/></svg>Loading...</div>`
  }

  async renderGifHome() {
    const content = this.contentTarget
    try {
      const resp = await fetch("/api/gif_collections")
      if (resp.ok) {
        const data = await resp.json()
        this.userCollections = data.collections
      }
    } catch(e) {}

    let html = `<div class="grid grid-cols-2 gap-2 p-1">`
    const favCollection = this.userCollections.find(c => c.name === "Favorites")
    html += this.collectionTile("Favorites", favCollection?.favorites_count || 0, favCollection?.id || "default", "🔥")
    html += this.collectionTile("Trending GIFs", "", "_trending", "📈")

    this.userCollections.filter(c => c.name !== "Favorites").forEach(c => {
      html += this.collectionTile(c.name, c.favorites_count, c.id, c.icon || "📁", true)
    })
    html += `</div>`

    content.innerHTML = html
  }

  collectionTile(name, count, id, icon, deletable = false) {
    const actions = deletable
      ? "click->unified-picker#openCollection contextmenu->unified-picker#showCollectionContextMenu"
      : "click->unified-picker#openCollection"
    const iconHtml = icon && (icon.startsWith("http") || icon.startsWith("/"))
      ? `<img src="${this.escapeAttr(icon)}" class="w-7 h-7 object-contain mb-1" loading="lazy">`
      : `<span class="text-2xl mb-1">${icon}</span>`
    return `<button type="button" class="flex flex-col items-center justify-center bg-gray-700 hover:bg-gray-600 rounded-lg p-3 cursor-pointer transition text-center" data-action="${actions}" data-collection-id="${id}" data-collection-name="${this.escapeAttr(name)}">
      ${iconHtml}
      <span class="text-white text-xs font-medium truncate w-full">${this.escapeHtml(name)}</span>
      ${count !== "" ? `<span class="text-gray-400 text-xs">${count}</span>` : ""}
    </button>`
  }

  async openCollection(event) {
    const id = event.currentTarget.dataset.collectionId
    this.gifSubView = id
    this.clearSearch()
    this.showLoading()

    if (id === "_trending") {
      await this.loadTrending()
    } else {
      await this.loadCollectionGifs(id)
    }
  }

  goBackToGifHome() {
    this.gifSubView = null
    this.currentCollectionFavorites = null
    this.tenorPos = ""
    this.clearSearch()
    this.renderGifHome()
  }

  async loadTrending() {
    try {
      const resp = await fetch(`/api/tenor/trending?pos=${this.tenorPos}`)
      if (!resp.ok) throw new Error()
      const data = await resp.json()
      this.renderGifGrid(data.results, data.next, true)
    } catch(e) {
      this.contentTarget.innerHTML = `<div class="text-center text-gray-500 text-sm py-8">Failed to load trending GIFs</div>`
    }
  }

  async loadCollectionGifs(collectionId, filterQuery) {
    // Fetch full collection if not cached yet
    if (!this.currentCollectionFavorites || this._cachedCollectionId !== collectionId) {
      const url = collectionId === "default" ? "/api/gif_favorites" : `/api/gif_favorites?collection_id=${collectionId}`
      try {
        const resp = await fetch(url)
        if (!resp.ok) throw new Error()
        const data = await resp.json()
        this.currentCollectionFavorites = data.favorites.map(f => ({
          id: f.tenor_gif_id,
          favoriteId: f.id,
          url: f.tenor_url,
          preview_url: f.preview_url,
          gif_url: f.gif_url,
          description: f.description || ""
        }))
        this._cachedCollectionId = collectionId
      } catch(e) {
        this.contentTarget.innerHTML = `<div class="text-center text-gray-500 text-sm py-8">Failed to load favorites</div>`
        return
      }
    }

    // Filter locally if there's a search query
    let results = this.currentCollectionFavorites
    if (filterQuery) {
      const q = filterQuery.toLowerCase()
      results = results.filter(f =>
        f.description.toLowerCase().includes(q) ||
        f.url.toLowerCase().includes(q)
      )
    }

    this.renderGifGrid(results, "", true)
  }

  async searchTenor(query) {
    if (this.tenorLoading) return
    this.tenorLoading = true
    try {
      const resp = await fetch(`/api/tenor/search?q=${encodeURIComponent(query)}&pos=${this.tenorPos}`)
      if (!resp.ok) throw new Error()
      const data = await resp.json()
      this.renderGifGrid(data.results, data.next, !this.tenorPos)
      this.tenorLoading = false
    } catch(e) {
      this.contentTarget.innerHTML = `<div class="text-center text-gray-500 text-sm py-8">Failed to search GIFs</div>`
      this.tenorLoading = false
    }
  }

  renderGifGrid(results, nextPos, replace = false) {
    const content = this.contentTarget
    let backBtn = `<button type="button" class="flex items-center gap-1 text-gray-400 hover:text-white text-xs mb-2 px-1 cursor-pointer" data-action="click->unified-picker#goBackToGifHome"><svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/></svg> Back</button>`

    let html = results.map(gif => {
      const previewUrl = gif.preview_url || gif.gif_url
      const favAttr = gif.favoriteId ? ` data-favorite-id="${this.escapeAttr(gif.favoriteId)}"` : ""
      const actions = gif.favoriteId
        ? "click->unified-picker#selectGif contextmenu->unified-picker#showContextMenu"
        : "click->unified-picker#selectGif"

      // Fire icon save button — shown on all GIF items, reflects default Favorites state
      const isFav = this.userFavoriteIds.has(gif.id)
      const iconClass = isFav ? "text-accent-light" : "text-white/80"
      const fillAttr = isFav ? 'fill="currentColor"' : 'fill="none" stroke="currentColor" stroke-width="2"'
      const saveBtn = `<button type="button" class="gif-picker-save absolute top-1 left-1 z-10 w-6 h-6 rounded-full bg-black/60 hover:bg-black/80 flex items-center justify-center cursor-pointer" data-action="click->unified-picker#togglePickerFavorite:stop:prevent" data-tenor-gif-id="${this.escapeAttr(gif.id)}"><svg class="w-3.5 h-3.5 ${iconClass}" ${fillAttr} viewBox="0 0 24 24"><path ${isFav ? "" : 'stroke-linecap="round" stroke-linejoin="round" '}d="M12 23c-4.97 0-9-2.69-9-6 0-2.4 1.68-4.47 2.64-5.27.32-.27.8-.04.8.39v.51c0 1.28.49 2.52 1.38 3.46.09.1.25.1.34 0 .37-.4.65-.87.82-1.39.09-.27.42-.37.63-.18C11.4 16.18 12.5 17.88 12.5 20c0 .28.22.5.5.5s.5-.22.5-.5c0-2.98-1.63-5.58-4.07-6.97a.249.249 0 01-.01-.43C11.26 11.45 13 9.13 13 6.5c0-.99-.16-1.94-.47-2.83a.252.252 0 01.34-.31C16.68 5.38 21 9.49 21 14c0 5.38-4.03 9-9 9z"/></svg></button>`

      return `<div class="gif-grid-item relative cursor-pointer rounded overflow-hidden hover:ring-2 hover:ring-accent transition" data-action="${actions}" data-gif-url="${this.escapeAttr(gif.url)}" data-tenor-gif-id="${this.escapeAttr(gif.id)}"${favAttr} data-preview-url="${this.escapeAttr(gif.preview_url || "")}" data-full-gif-url="${this.escapeAttr(gif.gif_url || "")}"><img src="${this.escapeAttr(previewUrl)}" alt="${this.escapeAttr(gif.description || "GIF")}" class="w-full h-auto" loading="lazy">${saveBtn}</div>`
    }).join("")

    if (results.length === 0) {
      html = `<div class="text-center text-gray-500 text-sm py-8">No GIFs found</div>`
    }

    if (replace) {
      // Show back button if we're in a sub-view or a Tenor search from top-level
      const showBack = this.gifSubView || this.searchQuery
      content.innerHTML = (showBack ? backBtn : "") + `<div class="grid grid-cols-2 gap-1 p-1">${html}</div>`
    } else {
      const grid = content.querySelector(".grid")
      if (grid) grid.insertAdjacentHTML("beforeend", html)
    }

    if (nextPos && results.length > 0) {
      this.tenorPos = nextPos
      const loadMore = document.createElement("button")
      loadMore.type = "button"
      loadMore.className = "w-full py-2 text-center text-gray-400 hover:text-white text-xs cursor-pointer"
      loadMore.textContent = "Load more..."
      loadMore.addEventListener("click", () => {
        loadMore.remove()
        if (this.searchQuery) {
          this.searchTenor(this.searchQuery)
        } else {
          this.loadTrending()
        }
      })
      content.appendChild(loadMore)
    }
  }

  selectGif(event) {
    const el = event.currentTarget
    const gifUrl = el.dataset.gifUrl
    if (!gifUrl) return

    const input = this.inputTarget
    input.value = gifUrl
    input.dispatchEvent(new Event("input", { bubbles: true }))

    const form = input.closest("form")
    if (form) form.requestSubmit()

    this.close()
  }

  async togglePickerFavorite(event) {
    const btn = event.currentTarget
    const gifId = btn.dataset.tenorGifId
    if (!gifId) return

    const gifEl = btn.closest(".gif-grid-item")
    const tenorUrl = gifEl?.dataset.gifUrl || ""
    const gifUrl = gifEl?.dataset.fullGifUrl || ""
    const previewUrl = gifEl?.dataset.previewUrl || ""

    try {
      const resp = await fetch("/api/gif_favorites/toggle", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this.csrfToken() },
        body: JSON.stringify({
          tenor_gif_id: gifId,
          tenor_url: tenorUrl,
          gif_url: gifUrl,
          preview_url: previewUrl,
          description: ""
        })
      })
      if (!resp.ok) throw new Error()
      const data = await resp.json()

      if (data.favorited) {
        this.userFavoriteIds.add(gifId)
      } else {
        this.userFavoriteIds.delete(gifId)
      }

      // Update the button icon
      const isFav = data.favorited
      const iconClass = isFav ? "text-accent-light" : "text-white/80"
      const fillAttr = isFav ? 'fill="currentColor"' : 'fill="none" stroke="currentColor" stroke-width="2"'
      btn.innerHTML = `<svg class="w-3.5 h-3.5 ${iconClass}" ${fillAttr} viewBox="0 0 24 24"><path ${isFav ? "" : 'stroke-linecap="round" stroke-linejoin="round" '}d="M12 23c-4.97 0-9-2.69-9-6 0-2.4 1.68-4.47 2.64-5.27.32-.27.8-.04.8.39v.51c0 1.28.49 2.52 1.38 3.46.09.1.25.1.34 0 .37-.4.65-.87.82-1.39.09-.27.42-.37.63-.18C11.4 16.18 12.5 17.88 12.5 20c0 .28.22.5.5.5s.5-.22.5-.5c0-2.98-1.63-5.58-4.07-6.97a.249.249 0 01-.01-.43C11.26 11.45 13 9.13 13 6.5c0-.99-.16-1.94-.47-2.83a.252.252 0 01.34-.31C16.68 5.38 21 9.49 21 14c0 5.38-4.03 9-9 9z"/></svg>`

      // Invalidate favorites cache so collection views refresh
      this.currentCollectionFavorites = null
      this._cachedCollectionId = null

      // Notify message stream fire icons to sync
      document.dispatchEvent(new CustomEvent("gif-favorites-changed", { detail: { gifId, favorited: data.favorited, source: "picker" } }))

      // If viewing the default Favorites collection and we just unfavorited, refresh the list
      if (!data.favorited) {
        const isDefaultFavorites = this.gifSubView === "default" ||
          this.userCollections.find(c => c.id === this.gifSubView)?.name === "Favorites"
        if (isDefaultFavorites) this.renderCurrentTab()
      }
    } catch(e) {
      console.error("Failed to toggle favorite:", e)
    }
  }

  // ─── Stickers Tab ──────────────────────────────────────────
  async renderStickersTab() {
    const content = this.contentTarget
    if (!this.canSendGifsValue || !this.canSendCustomStickersValue) {
      content.innerHTML = `<div class="flex items-center justify-center h-32 text-gray-500 text-sm">You don't have permission to send stickers</div>`
      return
    }

    const servers = this.getUserServers()
    let html = ""

    for (const server of servers) {
      const stickers = await this.fetchServerStickers(server.id)
      const filtered = this.searchQuery
        ? stickers.filter(s => s.name.toLowerCase().includes(this.searchQuery.toLowerCase()))
        : stickers
      if (filtered.length === 0 && this.searchQuery) continue

      const collapsed = this.collapsedSections[`sticker_${server.id}`]
      html += this.collapsibleSection(`sticker_${server.id}`, this.escapeHtml(server.name), collapsed, () => {
        if (filtered.length === 0) return `<div class="text-gray-500 text-xs px-2 py-1">No stickers yet</div>`
        return `<div class="grid grid-cols-3 gap-1">${filtered.map(s =>
          `<div class="cursor-pointer rounded-lg overflow-hidden hover:ring-2 hover:ring-accent transition p-1 bg-gray-700" data-action="click->unified-picker#selectSticker" data-sticker-url="${this.escapeAttr(s.image_url)}" data-sticker-name="${this.escapeAttr(s.name)}" title="${this.escapeAttr(s.name)}"><img src="${this.escapeAttr(s.image_url)}" alt="${this.escapeAttr(s.name)}" class="w-full h-auto" loading="lazy"></div>`
        ).join("")}</div>`
      })
    }

    if (!html) {
      html = `<div class="text-center text-gray-500 text-sm py-8">No stickers available</div>`
    }

    content.innerHTML = html
  }

  selectSticker(event) {
    const el = event.currentTarget
    const url = el.dataset.stickerUrl
    if (!url) return

    const input = this.inputTarget
    input.value = url
    input.dispatchEvent(new Event("input", { bubbles: true }))

    const form = input.closest("form")
    if (form) form.requestSubmit()

    this.close()
  }

  // ─── Emoji Tab ─────────────────────────────────────────────
  async renderEmojiTab() {
    const content = this.contentTarget
    let html = ""

    // Frequently Used section
    if (this.frequentlyUsed.length > 0 && !this.searchQuery) {
      const collapsed = this.collapsedSections["freq_emoji"]
      html += this.collapsibleSection("freq_emoji", "🕐 Frequently Used", collapsed, () => {
        return `<div class="flex flex-wrap gap-0.5">${this.frequentlyUsed.map(e => {
          if (e.type === "custom") {
            return `<button type="button" class="w-9 h-9 sm:w-8 sm:h-8 flex items-center justify-center hover:bg-gray-700 rounded cursor-pointer" data-action="click->unified-picker#selectCustomEmoji" data-emoji-name="${this.escapeAttr(e.name)}" data-emoji-url="${this.escapeAttr(e.url || "")}" title=":${this.escapeAttr(e.name)}:"><img src="${this.escapeAttr(e.url)}" class="w-6 h-6 object-contain" loading="lazy" onerror="this.parentElement.remove()"></button>`
          }
          return `<button type="button" class="w-9 h-9 sm:w-8 sm:h-8 flex items-center justify-center text-xl hover:bg-gray-700 rounded cursor-pointer" data-action="click->unified-picker#selectEmoji" data-emoji="${e.emoji}">${e.emoji}</button>`
        }).join("")}</div>`
      })
    }

    // Server custom emojis (organized by server, in server order)
    if (this.canSendCustomEmojisValue) {
      const servers = this.getUserServers()
      for (const server of servers) {
        const emojis = await this.fetchServerEmojis(server.id)
        const filtered = this.searchQuery
          ? emojis.filter(e => e.name.toLowerCase().includes(this.searchQuery.toLowerCase()))
          : emojis
        if (filtered.length === 0) continue

        const collapsed = this.collapsedSections[`emoji_${server.id}`]
        html += this.collapsibleSection(`emoji_${server.id}`, this.escapeHtml(server.name), collapsed, () => {
          return `<div class="flex flex-wrap gap-0.5">${filtered.map(e =>
            `<button type="button" class="w-9 h-9 sm:w-8 sm:h-8 flex items-center justify-center hover:bg-gray-700 rounded cursor-pointer" data-action="click->unified-picker#selectCustomEmoji" data-emoji-name="${this.escapeAttr(e.name)}" data-emoji-url="${this.escapeAttr(e.image_url)}" title=":${this.escapeAttr(e.name)}:"><img src="${this.escapeAttr(e.image_url)}" class="w-6 h-6 object-contain" loading="lazy" onerror="this.parentElement.remove()"></button>`
          ).join("")}</div>`
        })
      }
    }

    // Standard emoji categories from server-rendered template
    const emojiGrid = document.getElementById("tpl-emoji-grid").content.cloneNode(true)
    emojiGrid.querySelectorAll("[data-emoji-category]").forEach(catDiv => {
      const category = catDiv.dataset.emojiCategory
      const buttonsWrap = catDiv.querySelector(".flex.flex-wrap")
      const buttons = buttonsWrap.querySelectorAll("[data-emoji]")

      // Add Stimulus action to all buttons
      buttons.forEach(btn => { btn.dataset.action = "click->unified-picker#selectEmoji" })

      if (this.searchQuery) {
        let visibleCount = 0
        buttons.forEach(btn => {
          if (btn.dataset.emoji.includes(this.searchQuery)) { visibleCount++ } else { btn.remove() }
        })
        if (visibleCount === 0) return
      }

      const collapsed = this.collapsedSections[`cat_${category}`]
      html += this.collapsibleSection(`cat_${category}`, category, collapsed, () => buttonsWrap.outerHTML)
    })

    if (!html) {
      html = `<div class="text-center text-gray-500 text-sm py-8">No matches found</div>`
    }

    content.innerHTML = html
  }

  selectEmoji(event) {
    const emoji = event.currentTarget.dataset.emoji
    this.trackFrequentlyUsed({ type: "standard", emoji })
    if (this._reactionMode) {
      this._submitReaction(emoji)
      return
    }
    const input = this.inputTarget
    const start = input.selectionStart
    const end = input.selectionEnd
    input.value = input.value.substring(0, start) + emoji + input.value.substring(end)
    input.selectionStart = input.selectionEnd = start + emoji.length
    input.focus()
    input.dispatchEvent(new Event("input", { bubbles: true }))
    this.close()
  }

  selectCustomEmoji(event) {
    const name = event.currentTarget.dataset.emojiName
    const url = event.currentTarget.dataset.emojiUrl
    this.trackFrequentlyUsed({ type: "custom", name, url })
    if (this._reactionMode) {
      this._submitReaction(`:${name}:`)
      return
    }
    const input = this.inputTarget
    const text = `:${name}:`
    const start = input.selectionStart
    const end = input.selectionEnd
    input.value = input.value.substring(0, start) + text + input.value.substring(end)
    input.selectionStart = input.selectionEnd = start + text.length
    input.focus()
    input.dispatchEvent(new Event("input", { bubbles: true }))
    this.close()
  }

  // ─── Collapsible sections ──────────────────────────────────
  collapsibleSection(key, title, collapsed, contentFn) {
    const chevron = collapsed
      ? `<svg class="w-3 h-3 transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7"/></svg>`
      : `<svg class="w-3 h-3 transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/></svg>`

    return `<div class="mb-2">
      <button type="button" class="flex items-center gap-1 w-full px-1 py-1 text-xs font-semibold text-gray-400 uppercase hover:text-gray-200 cursor-pointer" data-action="click->unified-picker#toggleSection" data-section-key="${key}">
        ${chevron}
        <span>${title}</span>
      </button>
      <div class="${collapsed ? "hidden" : ""}" data-section-content="${key}">
        ${collapsed ? "" : contentFn()}
      </div>
    </div>`
  }

  toggleSection(event) {
    const key = event.currentTarget.dataset.sectionKey
    this.collapsedSections[key] = !this.collapsedSections[key]
    localStorage.setItem("picker_collapsed", JSON.stringify(this.collapsedSections))
    this.renderCurrentTab()
  }

  // ─── Frequently Used tracking ──────────────────────────────
  trackFrequentlyUsed(entry) {
    this.frequentlyUsed = this.frequentlyUsed.filter(e => {
      if (entry.type === "standard") return e.emoji !== entry.emoji
      return e.name !== entry.name
    })
    this.frequentlyUsed.unshift(entry)
    this.frequentlyUsed = this.frequentlyUsed.slice(0, MAX_FREQUENT)
    localStorage.setItem(FREQUENTLY_USED_KEY, JSON.stringify(this.frequentlyUsed))
  }

  // ─── Data fetching helpers ─────────────────────────────────
  getUserServers() {
    try {
      return JSON.parse(this.userServersValue || "[]")
    } catch(e) {
      return []
    }
  }

  async fetchServerEmojis(serverId) {
    if (this.serverEmojisCache[serverId]) return this.serverEmojisCache[serverId]
    try {
      const resp = await fetch(`/servers/${serverId}/emojis`, { headers: { Accept: "application/json" } })
      if (resp.ok) {
        const data = await resp.json()
        this.serverEmojisCache[serverId] = data.emojis
        // Populate global emoji map + PUA char mapping for input preview
        if (!window._emojiMap) window._emojiMap = {}
        if (!window._emojiPUA) { window._emojiPUA = {}; window._emojiReverse = {}; window._nextPUA = 0xE000 }
        data.emojis.forEach(e => {
          window._emojiMap[e.name] = e.image_url
          if (!window._emojiPUA[e.name]) {
            const ch = String.fromCodePoint(window._nextPUA++)
            window._emojiPUA[e.name] = ch
            window._emojiReverse[ch] = e.name
          }
        })
        // Persist to localStorage for page refresh resilience
        try {
          localStorage.setItem('_emojiMap', JSON.stringify(window._emojiMap))
          localStorage.setItem('_emojiPUA', JSON.stringify(window._emojiPUA))
          localStorage.setItem('_emojiReverse', JSON.stringify(window._emojiReverse))
          localStorage.setItem('_nextPUA', String(window._nextPUA))
        } catch(e) {}
        return data.emojis
      }
    } catch(e) {}
    return []
  }

  async fetchServerStickers(serverId) {
    if (this.serverStickersCache[serverId]) return this.serverStickersCache[serverId]
    try {
      const resp = await fetch(`/servers/${serverId}/stickers`, { headers: { Accept: "application/json" } })
      if (resp.ok) {
        const data = await resp.json()
        this.serverStickersCache[serverId] = data.stickers
        return data.stickers
      }
    } catch(e) {}
    return []
  }

  async loadUserFavoriteIds() {
    if (this.userFavoriteIds.size > 0) return
    try {
      const resp = await fetch("/api/gif_favorites?default=1")
      if (resp.ok) {
        const data = await resp.json()
        this.userFavoriteIds = new Set(data.favorites.map(f => f.tenor_gif_id))
      }
    } catch(e) {}
  }

  // ─── GIF Context Menu ────────────────────────────────────
  showContextMenu(event) {
    event.preventDefault()
    event.stopPropagation()

    const gifEl = event.currentTarget
    const favoriteId = gifEl.dataset.favoriteId
    if (!favoriteId) return

    // Look up full GIF data from cached collection
    const gifData = (this.currentCollectionFavorites || []).find(f => f.favoriteId === favoriteId)
    if (!gifData) return

    this.dismissContextMenu()

    const menu = document.createElement("div")
    menu.id = "gif-context-menu"
    menu.className = "fixed bg-gray-800 border border-gray-600 rounded-lg shadow-xl py-1 z-[9999] min-w-[180px] text-sm context-pop"
    menu.style.left = `${event.clientX}px`
    menu.style.top = `${event.clientY}px`

    // "Add to" section — exclude current collection and Favorites if already favorited
    const otherCollections = this.userCollections.filter(c => {
      if (c.id === this.gifSubView) return false
      if (c.name === "Favorites" && this.userFavoriteIds.has(gifData.id)) return false
      return true
    })
    if (otherCollections.length > 0) {
      const header = document.createElement("div")
      header.className = "px-3 py-1.5 text-gray-400 text-xs uppercase font-semibold"
      header.textContent = "Add to"
      menu.appendChild(header)

      otherCollections.forEach(c => {
        const item = document.createElement("button")
        item.type = "button"
        item.className = "w-full text-left px-3 py-1.5 text-gray-200 hover:bg-gray-700 cursor-pointer flex items-center gap-2"
        item.innerHTML = `<span>${c.name === "Favorites" ? "🔥" : "📁"}</span> ${this.escapeHtml(c.name)}`
        item.addEventListener("click", () => this.addToCollection(gifData, c.id))
        menu.appendChild(item)
      })
    }

    // Divider
    const divider = document.createElement("div")
    divider.className = "border-t border-gray-600 my-1"
    menu.appendChild(divider)

    // New Collection
    const newCollBtn = document.createElement("button")
    newCollBtn.type = "button"
    newCollBtn.className = "w-full text-left px-3 py-1.5 text-gray-200 hover:bg-gray-700 cursor-pointer flex items-center gap-2"
    newCollBtn.innerHTML = `<span>➕</span> New Collection...`
    newCollBtn.addEventListener("click", () => this.showNewCollectionInput(menu, gifData))
    menu.appendChild(newCollBtn)

    // Remove from this collection
    const removeBtn = document.createElement("button")
    removeBtn.type = "button"
    removeBtn.className = "w-full text-left px-3 py-1.5 text-accent-light hover:bg-gray-700 cursor-pointer flex items-center gap-2"
    removeBtn.innerHTML = `<span>🗑️</span> Remove`
    removeBtn.addEventListener("click", () => this.removeFromFavorites(favoriteId, gifData.id))
    menu.appendChild(removeBtn)

    document.body.appendChild(menu)
    positionPopup(menu, { x: event.clientX, y: event.clientY }, {
      preferredSide: "below",
      horizontalAlign: "left"
    })

    // Attach dismiss listeners (deferred so the current event doesn't trigger them)
    setTimeout(() => {
      document.addEventListener("mousedown", this.boundDismissCtxOnClick)
      document.addEventListener("keydown", this.boundDismissCtxOnKey)
      this.contentTarget.addEventListener("scroll", this.boundDismissCtxOnScroll)
    }, 0)
  }

  dismissContextMenu() {
    const menu = document.getElementById("gif-context-menu")
    if (menu) menu.remove()
    document.removeEventListener("mousedown", this.boundDismissCtxOnClick)
    document.removeEventListener("keydown", this.boundDismissCtxOnKey)
    if (this.hasContentTarget) {
      this.contentTarget.removeEventListener("scroll", this.boundDismissCtxOnScroll)
    }
  }

  async showNewCollectionInput(menu, gifData) {
    menu.innerHTML = ""
    let selectedIcon = "📁"

    const wrapper = document.createElement("div")
    wrapper.className = "p-2 w-[220px]"

    // Icon + name row
    const row = document.createElement("div")
    row.className = "flex items-center gap-1.5 mb-2"

    const iconBtn = document.createElement("button")
    iconBtn.type = "button"
    iconBtn.className = "w-8 h-8 rounded bg-gray-700 hover:bg-gray-600 flex items-center justify-center text-lg cursor-pointer shrink-0 border border-gray-600"
    iconBtn.innerHTML = selectedIcon
    row.appendChild(iconBtn)

    const input = document.createElement("input")
    input.type = "text"
    input.className = "flex-1 min-w-0 bg-gray-700 text-white text-sm rounded px-2 py-1.5 outline-none focus:ring-1 focus:ring-accent"
    input.placeholder = "Collection name"
    row.appendChild(input)
    wrapper.appendChild(row)

    // Icon label
    const gridLabel = document.createElement("div")
    gridLabel.className = "text-gray-400 text-xs mb-1"
    gridLabel.textContent = "Icon"
    wrapper.appendChild(gridLabel)

    // Scrollable emoji grid
    const grid = document.createElement("div")
    grid.className = "max-h-[140px] overflow-y-auto rounded bg-gray-900/50 p-1"

    const selectIcon = (icon, html) => {
      selectedIcon = icon
      iconBtn.innerHTML = html
    }

    const makeEmojiBtn = (emoji) => {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "w-7 h-7 flex items-center justify-center hover:bg-gray-600 rounded cursor-pointer text-base"
      btn.textContent = emoji
      btn.addEventListener("click", (ev) => { ev.stopPropagation(); selectIcon(emoji, emoji) })
      return btn
    }

    const makeCustomBtn = (url, name) => {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "w-7 h-7 flex items-center justify-center hover:bg-gray-600 rounded cursor-pointer"
      btn.title = `:${name}:`
      btn.innerHTML = `<img src="${this.escapeAttr(url)}" class="w-5 h-5 object-contain" loading="lazy">`
      btn.addEventListener("click", (ev) => {
        ev.stopPropagation()
        selectIcon(url, `<img src="${this.escapeAttr(url)}" class="w-5 h-5 object-contain">`)
      })
      return btn
    }

    // Custom server emojis grouped by server (loaded async, shown first)
    const servers = this.getUserServers()
    for (const server of servers) {
      const emojis = await this.fetchServerEmojis(server.id)
      if (emojis.length === 0) continue

      const label = document.createElement("div")
      label.className = "text-gray-500 text-[10px] uppercase font-semibold px-0.5 pt-1 pb-0.5"
      label.textContent = server.name
      grid.appendChild(label)

      const serverGrid = document.createElement("div")
      serverGrid.className = "flex flex-wrap gap-0.5"
      emojis.forEach(e => serverGrid.appendChild(makeCustomBtn(e.image_url, e.name)))
      grid.appendChild(serverGrid)
    }

    // Standard emoji categories from server-rendered template
    const emojiGridClone = document.getElementById("tpl-emoji-grid").content.cloneNode(true)
    emojiGridClone.querySelectorAll("[data-emoji-category]").forEach(catDiv => {
      const label = document.createElement("div")
      label.className = "text-gray-500 text-[10px] uppercase font-semibold px-0.5 pt-1 pb-0.5"
      label.textContent = catDiv.dataset.emojiCategory
      grid.appendChild(label)

      const catGrid = document.createElement("div")
      catGrid.className = "flex flex-wrap gap-0.5"
      catDiv.querySelectorAll("[data-emoji]").forEach(btn => catGrid.appendChild(makeEmojiBtn(btn.dataset.emoji)))
      grid.appendChild(catGrid)
    })

    wrapper.appendChild(grid)

    // Submit handler
    const submit = async () => {
      const name = input.value.trim()
      if (!name) return
      input.disabled = true
      await this.createCollectionAndAdd(name, gifData, selectedIcon)
    }

    input.addEventListener("keydown", async (e) => {
      if (e.key === "Enter") await submit()
      if (e.key === "Escape") this.dismissContextMenu()
    })

    // Create button
    const createBtn = document.createElement("button")
    createBtn.type = "button"
    createBtn.className = "w-full mt-2 py-1.5 bg-confirm hover:bg-confirm-light text-white text-xs font-medium rounded cursor-pointer transition"
    createBtn.textContent = "Create"
    createBtn.addEventListener("click", submit)
    wrapper.appendChild(createBtn)

    menu.appendChild(wrapper)
    requestAnimationFrame(() => input.focus())
  }

  async addToCollection(gifData, collectionId) {
    this.dismissContextMenu()
    try {
      const resp = await fetch("/api/gif_favorites", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this.csrfToken() },
        body: JSON.stringify({ gif_favorite: {
          collection_id: collectionId,
          tenor_gif_id: gifData.id,
          tenor_url: gifData.url,
          preview_url: gifData.preview_url,
          gif_url: gifData.gif_url,
          description: gifData.description
        }})
      })
      if (!resp.ok) throw new Error()
    } catch(e) {
      console.error("Failed to add GIF to collection:", e)
    }
  }

  async removeFromFavorites(favoriteId, tenorGifId) {
    this.dismissContextMenu()
    try {
      const resp = await fetch(`/api/gif_favorites/${favoriteId}`, {
        method: "DELETE",
        headers: { "X-CSRF-Token": this.csrfToken() }
      })
      if (!resp.ok) throw new Error()

      // If removing from the default Favorites collection, sync fire icon state
      const isDefaultFavorites = this.gifSubView === "default" ||
        this.userCollections.find(c => c.id === this.gifSubView)?.name === "Favorites"
      if (isDefaultFavorites && tenorGifId) {
        this.userFavoriteIds.delete(tenorGifId)
        document.dispatchEvent(new CustomEvent("gif-favorites-changed", {
          detail: { gifId: tenorGifId, favorited: false, source: "picker" }
        }))
      }

      this.invalidateAndRefresh()
    } catch(e) {
      console.error("Failed to remove GIF:", e)
    }
  }

  async createCollectionAndAdd(name, gifData, icon) {
    this.dismissContextMenu()
    try {
      const createResp = await fetch("/api/gif_collections", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this.csrfToken() },
        body: JSON.stringify({ gif_collection: { name, icon } })
      })
      if (!createResp.ok) throw new Error()
      const { id: newCollectionId } = await createResp.json()

      // Add the GIF to the new collection
      const addResp = await fetch("/api/gif_favorites", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this.csrfToken() },
        body: JSON.stringify({ gif_favorite: {
          collection_id: newCollectionId,
          tenor_gif_id: gifData.id,
          tenor_url: gifData.url,
          preview_url: gifData.preview_url,
          gif_url: gifData.gif_url,
          description: gifData.description
        }})
      })
      if (!addResp.ok) throw new Error()

      // Add to local collections list so it appears in future menus
      this.userCollections.push({ id: newCollectionId, name, icon, favorites_count: 1 })
    } catch(e) {
      console.error("Failed to create collection:", e)
    }
  }

  showCollectionContextMenu(event) {
    event.preventDefault()
    event.stopPropagation()

    const tileEl = event.currentTarget
    const collectionId = tileEl.dataset.collectionId
    const collectionName = tileEl.dataset.collectionName
    if (!collectionId) return

    this.dismissContextMenu()

    const menu = document.createElement("div")
    menu.id = "gif-context-menu"
    menu.className = "fixed bg-gray-800 border border-gray-600 rounded-lg shadow-xl py-1 z-[9999] min-w-[160px] text-sm context-pop"
    menu.style.left = `${event.clientX}px`
    menu.style.top = `${event.clientY}px`

    const deleteBtn = document.createElement("button")
    deleteBtn.type = "button"
    deleteBtn.className = "w-full text-left px-3 py-1.5 text-accent-light hover:bg-gray-700 cursor-pointer flex items-center gap-2"
    deleteBtn.innerHTML = `<span>🗑️</span> Delete Collection`
    deleteBtn.addEventListener("click", () => this.deleteCollection(collectionId))
    menu.appendChild(deleteBtn)

    document.body.appendChild(menu)
    positionPopup(menu, { x: event.clientX, y: event.clientY }, {
      preferredSide: "below",
      horizontalAlign: "left"
    })

    setTimeout(() => {
      document.addEventListener("mousedown", this.boundDismissCtxOnClick)
      document.addEventListener("keydown", this.boundDismissCtxOnKey)
    }, 0)
  }

  async deleteCollection(collectionId) {
    this.dismissContextMenu()
    try {
      const resp = await fetch(`/api/gif_collections/${collectionId}`, {
        method: "DELETE",
        headers: { "X-CSRF-Token": this.csrfToken() }
      })
      if (!resp.ok) throw new Error()
      this.userCollections = this.userCollections.filter(c => c.id !== collectionId)
      this.renderGifHome()
    } catch(e) {
      console.error("Failed to delete collection:", e)
    }
  }

  invalidateAndRefresh() {
    this.currentCollectionFavorites = null
    this._cachedCollectionId = null
    this.renderCurrentTab()
  }

  csrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.content : ""
  }

  // ─── Helpers ───────────────────────────────────────────────
  escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  }

  escapeAttr(str) {
    return (str || "").replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  // ─── Reaction Mode ──────────────────────────────────────────

  openInReactionMode() {
    // Remove any old reaction panel
    document.getElementById("reaction-picker-panel")?.remove()

    // Force emoji tab
    this.activeTab = "emoji"
    this.searchQuery = ""
    if (this.hasSearchInputTarget) this.searchInputTarget.value = ""

    // Clone floating panel from template
    const tpl = document.getElementById("tpl-reaction-picker").content.cloneNode(true)
    const panel = tpl.querySelector("div")
    panel.id = "reaction-picker-panel"

    const searchInput = panel.querySelector("input")
    const contentDiv = panel.querySelector('[data-slot="content"]')

    searchInput.addEventListener("input", () => {
      if (this._reactionDebounce) clearTimeout(this._reactionDebounce)
      this._reactionDebounce = setTimeout(() => {
        this.searchQuery = searchInput.value.trim()
        this._renderReactionEmojiContent(contentDiv)
      }, 150)
    })

    document.body.appendChild(panel)

    // Position: prefer click coordinates (from context menu), fall back to message element
    const { clientX, clientY, anchorSelector } = this._reactionMode
    if (clientX != null && clientY != null) {
      positionPopup(panel, { x: clientX, y: clientY }, {
        preferredSide: "below",
        gap: 4,
        horizontalAlign: "left"
      })
    } else {
      const anchor = document.querySelector(anchorSelector)
      if (anchor) {
        positionPopup(panel, anchor.getBoundingClientRect(), {
          preferredSide: "above",
          gap: 8,
          horizontalAlign: "right"
        })
      }
    }

    panel.style.visibility = ""

    // Render emoji content
    this._renderReactionEmojiContent(contentDiv)

    requestAnimationFrame(() => searchInput.focus())
  }

  async _renderReactionEmojiContent(container) {
    let html = ""

    // Frequently Used section
    if (this.frequentlyUsed.length > 0 && !this.searchQuery) {
      html += `<div class="mb-2"><div class="text-xs font-semibold text-gray-400 uppercase px-1 py-1">🕐 Frequently Used</div><div class="flex flex-wrap gap-0.5">`
      this.frequentlyUsed.forEach(e => {
        if (e.type === "custom") {
          html += `<button type="button" class="w-9 h-9 sm:w-8 sm:h-8 flex items-center justify-center hover:bg-gray-700 rounded cursor-pointer" data-reaction-custom="${this.escapeAttr(e.name)}" title=":${this.escapeAttr(e.name)}:"><img src="${this.escapeAttr(e.url)}" class="w-6 h-6 object-contain" loading="lazy" onerror="this.parentElement.remove()"></button>`
        } else {
          html += `<button type="button" class="w-9 h-9 sm:w-8 sm:h-8 flex items-center justify-center text-xl hover:bg-gray-700 rounded cursor-pointer" data-reaction-emoji="${e.emoji}">${e.emoji}</button>`
        }
      })
      html += `</div></div>`
    }

    // Custom emojis
    if (this.canSendCustomEmojisValue) {
      const servers = this.getUserServers()
      for (const server of servers) {
        const emojis = await this.fetchServerEmojis(server.id)
        const filtered = this.searchQuery
          ? emojis.filter(e => e.name.toLowerCase().includes(this.searchQuery.toLowerCase()))
          : emojis
        if (filtered.length === 0) continue

        html += `<div class="mb-2"><div class="text-xs font-semibold text-gray-400 uppercase px-1 py-1">${this.escapeHtml(server.name)}</div><div class="flex flex-wrap gap-0.5">`
        filtered.forEach(e => {
          html += `<button type="button" class="w-9 h-9 sm:w-8 sm:h-8 flex items-center justify-center hover:bg-gray-700 rounded cursor-pointer" data-reaction-custom="${this.escapeAttr(e.name)}" data-reaction-custom-url="${this.escapeAttr(e.image_url)}" title=":${this.escapeAttr(e.name)}:"><img src="${this.escapeAttr(e.image_url)}" class="w-6 h-6 object-contain" loading="lazy" onerror="this.parentElement.remove()"></button>`
        })
        html += `</div></div>`
      }
    }

    // Standard categories from server-rendered template
    const emojiGrid = document.getElementById("tpl-emoji-grid").content.cloneNode(true)
    emojiGrid.querySelectorAll("[data-emoji-category]").forEach(catDiv => {
      const category = catDiv.dataset.emojiCategory
      const buttons = catDiv.querySelectorAll("[data-emoji]")

      // Convert data-emoji to data-reaction-emoji for reaction click handling
      buttons.forEach(btn => {
        btn.dataset.reactionEmoji = btn.dataset.emoji
        delete btn.dataset.emoji
      })

      if (this.searchQuery) {
        let visibleCount = 0
        buttons.forEach(btn => {
          if (btn.dataset.reactionEmoji.includes(this.searchQuery)) { visibleCount++ } else { btn.remove() }
        })
        if (visibleCount === 0) return
      }

      html += `<div class="mb-2"><div class="text-xs font-semibold text-gray-400 uppercase px-1 py-1">${category}</div>${catDiv.querySelector(".flex.flex-wrap").outerHTML}</div>`
    })

    if (!html) {
      html = `<div class="text-center text-gray-500 text-sm py-8">No matches found</div>`
    }

    container.innerHTML = html

    // Bind click handlers
    container.querySelectorAll("[data-reaction-emoji]").forEach(btn => {
      btn.addEventListener("click", () => {
        const emoji = btn.dataset.reactionEmoji
        this.trackFrequentlyUsed({ type: "standard", emoji })
        this._submitReaction(emoji)
      })
    })
    container.querySelectorAll("[data-reaction-custom]").forEach(btn => {
      btn.addEventListener("click", () => {
        const name = btn.dataset.reactionCustom
        const url = btn.dataset.reactionCustomUrl || ""
        this.trackFrequentlyUsed({ type: "custom", name, url })
        this._submitReaction(`:${name}:`)
      })
    })
  }

  async _submitReaction(emoji) {
    if (!this._reactionMode) return
    const { reactionUrl } = this._reactionMode
    const token = this.csrfToken()
    const formData = new FormData()
    formData.append("emoji", emoji)
    try {
      await fetch(reactionUrl, {
        method: "POST",
        headers: { "X-CSRF-Token": token },
        body: formData
      })
    } catch(e) {
      console.error("Failed to toggle reaction:", e)
    }
    this._exitReactionMode()
  }

  _exitReactionMode() {
    this._reactionMode = null
    document.getElementById("reaction-picker-panel")?.remove()
    if (this._reactionDebounce) clearTimeout(this._reactionDebounce)
    this.searchQuery = ""
  }
}
