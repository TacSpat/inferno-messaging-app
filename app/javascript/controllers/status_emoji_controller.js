import { Controller } from "@hotwired/stimulus"
import { positionPopup } from "../utils/popup_positioning"

// Simple emoji picker for the status emoji field.
// Opens the same emoji grid (with custom server emojis) but writes
// the selected emoji into a hidden field and shows it on the button.
export default class extends Controller {
  static targets = ["button", "field", "display"]
  static values = { serverId: String }

  connect() {
    this._panel = null
    this._customEmojiCache = null
    this._onOutsideClick = (e) => {
      if (this._panel && !this._panel.contains(e.target) && !this.buttonTarget.contains(e.target)) {
        this._close()
      }
    }
  }

  disconnect() {
    this._close()
  }

  toggle() {
    if (this._panel) { this._close(); return }
    this._open()
  }

  async _open() {
    const panel = document.createElement("div")
    panel.className = "fixed z-[260] bg-gray-900 border border-gray-700 rounded-xl shadow-2xl flex flex-col context-pop"
    panel.style.cssText = "width: 320px; max-height: 380px;"
    panel.innerHTML = `
      <div class="px-2 pt-2 pb-1">
        <input type="text" placeholder="Search emoji..." class="w-full bg-gray-800 text-gray-200 text-sm rounded-lg px-3 py-1.5 outline-none focus:ring-1 focus:ring-accent border border-gray-700" data-emoji-search>
      </div>
      <div class="flex-1 overflow-y-auto px-2 pb-2" data-emoji-content></div>`

    const content = panel.querySelector("[data-emoji-content]")

    // Custom server emojis
    if (this.hasServerIdValue && this.serverIdValue) {
      const emojis = await this._fetchCustomEmojis()
      if (emojis.length > 0) {
        const section = document.createElement("div")
        section.className = "mb-2"
        section.setAttribute("data-emoji-category", "custom")
        section.innerHTML = `
          <div class="text-xs font-semibold text-gray-400 uppercase px-1 py-1">Server Emojis</div>
          <div class="flex flex-wrap gap-0.5">${emojis.map(e =>
            `<button type="button" class="w-9 h-9 sm:w-8 sm:h-8 flex items-center justify-center hover:bg-gray-700 rounded cursor-pointer"
               data-custom-emoji data-emoji-name="${this._esc(e.name)}" data-emoji-url="${this._esc(e.image_url)}"
               title=":${this._esc(e.name)}:">
              <img src="${this._esc(e.image_url)}" class="w-6 h-6 object-contain" loading="lazy">
            </button>`
          ).join("")}</div>`
        content.appendChild(section)
      }
    }

    // Standard emoji grid
    const grid = document.getElementById("tpl-emoji-grid")
    if (grid) content.appendChild(grid.content.cloneNode(true))

    // Click handler — select emoji
    panel.addEventListener("click", (e) => {
      const stdBtn = e.target.closest("[data-emoji]")
      if (stdBtn) {
        this._select(stdBtn.dataset.emoji)
        return
      }
      const customBtn = e.target.closest("[data-custom-emoji]")
      if (customBtn) {
        // For custom emojis, store as :name: and show the image
        this._selectCustom(customBtn.dataset.emojiName, customBtn.dataset.emojiUrl)
      }
    })

    // Search
    const searchInput = panel.querySelector("[data-emoji-search]")
    searchInput.addEventListener("input", () => this._filterEmojis(searchInput.value, panel))

    document.body.appendChild(panel)
    this._panel = panel

    positionPopup(panel, this.buttonTarget.getBoundingClientRect(), {
      preferredSide: "below",
      horizontalAlign: "left",
      gap: 6,
      viewportPadding: 12
    })

    searchInput.focus()
    setTimeout(() => document.addEventListener("click", this._onOutsideClick, true), 0)
  }

  _close() {
    if (this._panel) {
      this._panel.remove()
      this._panel = null
    }
    document.removeEventListener("click", this._onOutsideClick, true)
  }

  _select(emoji) {
    this.fieldTarget.value = emoji
    this.displayTarget.textContent = emoji
    this._close()
  }

  _selectCustom(name, url) {
    this.fieldTarget.value = `:${name}:`
    this.displayTarget.innerHTML = `<img src="${this._esc(url)}" class="w-5 h-5 object-contain">`
    this._close()
  }

  async _fetchCustomEmojis() {
    if (this._customEmojiCache) return this._customEmojiCache
    try {
      const resp = await fetch(`/servers/${this.serverIdValue}/emojis`, {
        headers: { Accept: "application/json" }
      })
      if (resp.ok) {
        const data = await resp.json()
        this._customEmojiCache = data.emojis || []
        return this._customEmojiCache
      }
    } catch (e) {
      console.warn("[StatusEmoji] Failed to fetch custom emojis:", e)
    }
    return []
  }

  _filterEmojis(query, panel) {
    const q = query.toLowerCase().trim()
    panel.querySelectorAll("[data-emoji-category]").forEach(cat => {
      const isCustom = cat.getAttribute("data-emoji-category") === "custom"
      const buttons = cat.querySelectorAll(isCustom ? "[data-custom-emoji]" : "[data-emoji]")
      let visibleCount = 0
      buttons.forEach(btn => {
        const match = !q ||
          (btn.dataset.emoji || "").includes(q) ||
          (btn.dataset.emojiName || "").toLowerCase().includes(q) ||
          (btn.title || "").toLowerCase().includes(q)
        btn.style.display = match ? "" : "none"
        if (match) visibleCount++
      })
      cat.style.display = visibleCount > 0 ? "" : "none"
    })
  }

  _esc(str) {
    const d = document.createElement("div")
    d.textContent = str || ""
    return d.innerHTML
  }
}
