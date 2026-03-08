import { Controller } from "@hotwired/stimulus"
import { positionPopup } from "../utils/popup_positioning"

// Emoji picker for text inputs with inline custom emoji rendering.
// Uses the same PUA (Private Use Area) character + highlight overlay approach
// as the message form for rendering custom emojis inside the input.
export default class extends Controller {
  static targets = ["input", "button", "highlight"]
  static values = { serverId: String }

  connect() {
    this._panel = null
    this._customEmojiCache = null
    this._onOutsideClick = (e) => {
      if (this._panel && !this._panel.contains(e.target) && !this.buttonTarget.contains(e.target)) {
        this._close()
      }
    }

    // Prefetch custom emojis so the PUA map is ready
    if (this.hasServerIdValue && this.serverIdValue) {
      this._fetchCustomEmojis()
    }

    this._measureEmojiWidth()
    this._replaceEmojisWithPUA()
    this.updateHighlight()

    // Intercept form submit to convert PUA back to :name:
    this._form = this.element.closest("form")
    if (this._form) {
      this._submitHandler = () => this._convertPUABack()
      this._form.addEventListener("submit", this._submitHandler)
    }
  }

  disconnect() {
    this._close()
    if (this._form && this._submitHandler) {
      this._form.removeEventListener("submit", this._submitHandler)
    }
  }

  // --- Picker toggle ---

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

    // Click handlers
    panel.addEventListener("click", (e) => {
      const stdBtn = e.target.closest("[data-emoji]")
      if (stdBtn) {
        this._insertText(stdBtn.dataset.emoji)
        this._close()
        return
      }
      const customBtn = e.target.closest("[data-custom-emoji]")
      if (customBtn) {
        this._insertCustomEmoji(customBtn.dataset.emojiName)
        this._close()
      }
    })

    // Search
    const searchInput = panel.querySelector("[data-emoji-search]")
    searchInput.addEventListener("input", () => this._filterEmojis(searchInput.value, panel))

    document.body.appendChild(panel)
    this._panel = panel

    positionPopup(panel, this.buttonTarget.getBoundingClientRect(), {
      preferredSide: "below",
      horizontalAlign: "right",
      gap: 6,
      viewportPadding: 12
    })
    panel.style.visibility = ""

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

  // --- Emoji insertion ---

  _insertText(text) {
    const input = this.inputTarget
    const start = input.selectionStart ?? input.value.length
    const end = input.selectionEnd ?? start
    const val = input.value
    input.value = val.slice(0, start) + text + val.slice(end)
    const cursor = start + text.length
    input.setSelectionRange(cursor, cursor)
    input.focus()
    this.updateHighlight()
    input.dispatchEvent(new Event("input", { bubbles: true }))
  }

  _insertCustomEmoji(name) {
    if (!window._emojiPUA?.[name]) return
    const pua = "\u2003" + window._emojiPUA[name]
    this._insertText(pua)
  }

  // --- Highlight overlay (renders custom emoji images over transparent input text) ---

  updateHighlight() {
    if (!this.hasHighlightTarget) return
    const text = this.inputTarget.value
    let html = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")

    // Replace PUA placeholders with inline emoji images
    if (window._emojiReverse && window._emojiMap) {
      html = html.replace(/\u2003([\uE000-\uF8FF])/g, (_, ch) => {
        const name = window._emojiReverse[ch]
        if (name && window._emojiMap[name]) {
          const w = this._emojiCharWidth || 20
          return `<img src="${window._emojiMap[name]}" style="display:inline;height:${w}px;width:${w}px;object-fit:contain;vertical-align:middle;pointer-events:none">`
        }
        return _
      })
    }

    this.highlightTarget.innerHTML = html
    this.highlightTarget.scrollLeft = this.inputTarget.scrollLeft
  }

  // Called on every input event from the view
  handleInput() {
    this._replaceEmojisWithPUA()
    this.updateHighlight()
  }

  // Keyboard: treat PUA pairs as atomic units
  handleKeydown(event) {
    if (!window._emojiReverse) return
    const input = this.inputTarget
    const val = input.value
    const pos = input.selectionStart
    if (pos !== input.selectionEnd) return

    if (event.key === "Backspace") {
      if (pos >= 2 && val[pos - 2] === "\u2003" && window._emojiReverse[val[pos - 1]]) {
        event.preventDefault()
        input.value = val.substring(0, pos - 2) + val.substring(pos)
        input.selectionStart = input.selectionEnd = pos - 2
        this.updateHighlight()
        input.dispatchEvent(new Event("input", { bubbles: true }))
      }
    } else if (event.key === "Delete") {
      if (pos <= val.length - 2 && val[pos] === "\u2003" && window._emojiReverse[val[pos + 1]]) {
        event.preventDefault()
        input.value = val.substring(0, pos) + val.substring(pos + 2)
        input.selectionStart = input.selectionEnd = pos
        this.updateHighlight()
        input.dispatchEvent(new Event("input", { bubbles: true }))
      }
    } else if (event.key === "ArrowLeft" && !event.shiftKey) {
      if (pos >= 2 && val[pos - 2] === "\u2003" && window._emojiReverse[val[pos - 1]]) {
        event.preventDefault()
        input.selectionStart = input.selectionEnd = pos - 2
      } else if (pos >= 1 && val[pos - 1] === "\u2003" && pos < val.length && window._emojiReverse[val[pos]]) {
        event.preventDefault()
        input.selectionStart = input.selectionEnd = pos - 1
      }
    } else if (event.key === "ArrowRight" && !event.shiftKey) {
      if (pos <= val.length - 2 && val[pos] === "\u2003" && window._emojiReverse[val[pos + 1]]) {
        event.preventDefault()
        input.selectionStart = input.selectionEnd = pos + 2
      } else if (pos > 0 && val[pos - 1] === "\u2003" && pos < val.length && window._emojiReverse[val[pos]]) {
        event.preventDefault()
        input.selectionStart = input.selectionEnd = pos + 1
      }
    }
  }

  // --- PUA conversion ---

  _replaceEmojisWithPUA() {
    if (!window._emojiPUA || !window._emojiMap) return
    const input = this.inputTarget
    const val = input.value
    if (!val.includes(":")) return

    const selStart = input.selectionStart
    const selEnd = input.selectionEnd
    let newVal = ""
    let i = 0
    let newStart = selStart
    let newEnd = selEnd

    while (i < val.length) {
      if (val[i] === ":") {
        const rest = val.substring(i + 1)
        const match = rest.match(/^([a-z0-9_]+):/)
        if (match && window._emojiPUA[match[1]]) {
          const fullLen = match[0].length + 1
          const mEnd = i + fullLen
          const replacement = "\u2003" + window._emojiPUA[match[1]]
          const reduction = fullLen - 2
          newVal += replacement
          if (selStart >= mEnd) newStart -= reduction
          else if (selStart > i) newStart = newVal.length
          if (selEnd >= mEnd) newEnd -= reduction
          else if (selEnd > i) newEnd = newVal.length
          i = mEnd
          continue
        }
      }
      newVal += val[i]
      i++
    }

    if (newVal === val) return
    input.value = newVal
    input.selectionStart = Math.max(0, newStart)
    input.selectionEnd = Math.max(0, newEnd)
  }

  _convertPUABack() {
    if (!window._emojiReverse) return
    const input = this.inputTarget
    input.value = input.value.replace(/\u2003([\uE000-\uF8FF])/g, (_, ch) => {
      const name = window._emojiReverse[ch]
      return name ? `:${name}:` : _
    })
  }

  _measureEmojiWidth() {
    if (!this.hasInputTarget) return
    const canvas = document.createElement("canvas")
    const ctx = canvas.getContext("2d")
    const cs = getComputedStyle(this.inputTarget)
    ctx.font = `${cs.fontSize} ${cs.fontFamily}`
    this._emojiCharWidth = ctx.measureText("\u2003\uE000").width
  }

  // --- Custom emoji fetching ---

  async _fetchCustomEmojis() {
    if (this._customEmojiCache) return this._customEmojiCache
    try {
      const resp = await fetch(`/servers/${this.serverIdValue}/emojis`, {
        headers: { Accept: "application/json" }
      })
      if (resp.ok) {
        const data = await resp.json()
        const emojis = data.emojis || []
        this._customEmojiCache = emojis

        // Populate global PUA maps (same as unified picker)
        if (!window._emojiMap) window._emojiMap = {}
        if (!window._emojiPUA) { window._emojiPUA = {}; window._emojiReverse = {}; window._nextPUA = 0xE000 }
        emojis.forEach(e => {
          window._emojiMap[e.name] = e.image_url
          if (!window._emojiPUA[e.name]) {
            const ch = String.fromCodePoint(window._nextPUA++)
            window._emojiPUA[e.name] = ch
            window._emojiReverse[ch] = e.name
          }
        })
        try {
          localStorage.setItem("_emojiMap", JSON.stringify(window._emojiMap))
          localStorage.setItem("_emojiPUA", JSON.stringify(window._emojiPUA))
          localStorage.setItem("_emojiReverse", JSON.stringify(window._emojiReverse))
          localStorage.setItem("_nextPUA", String(window._nextPUA))
        } catch {}

        return emojis
      }
    } catch (e) {
      console.warn("[EmojiInput] Failed to fetch custom emojis:", e)
    }
    return []
  }

  // --- Search ---

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
