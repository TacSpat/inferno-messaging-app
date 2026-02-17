import { Controller } from "@hotwired/stimulus"

// Bottom sheet for touch message actions
// Uses the contextmenu event (fired on long-press by mobile browsers)
// to suppress the native menu and show a custom action sheet instead.
export default class extends Controller {
  connect() {
    this._onContextMenu = this._onContextMenu.bind(this)
    this._dismiss = this._dismiss.bind(this)
    this._isTouchDevice = false

    // Track whether the device supports touch
    this._onFirstTouch = () => { this._isTouchDevice = true }
    this.element.addEventListener("touchstart", this._onFirstTouch, { passive: true, once: false })

    this.element.addEventListener("contextmenu", this._onContextMenu)
  }

  disconnect() {
    this.element.removeEventListener("contextmenu", this._onContextMenu)
    this.element.removeEventListener("touchstart", this._onFirstTouch)
    this._removeSheet()
  }

  _onContextMenu(e) {
    // Only intercept on touch devices — let desktop right-click work normally
    if (!this._isTouchDevice) return

    const msgEl = e.target.closest("[data-message-id]")
    if (!msgEl || msgEl.dataset.systemMessage) return

    // Don't intercept on interactive elements
    const interactive = e.target.closest("a, button, video, audio, input, textarea")
    if (interactive) return

    e.preventDefault()

    if (navigator.vibrate) navigator.vibrate(30)
    this._showSheet(msgEl)
  }

  _showSheet(msgEl) {
    this._removeSheet()

    const messageId = msgEl.dataset.messageId
    const authorEl = msgEl.querySelector("[style*='color:']")
    const authorName = authorEl?.textContent?.trim() || "Unknown"
    const contentEl = msgEl.querySelector(".message-content")
    const rawContent = contentEl?.dataset?.rawContent || contentEl?.textContent?.trim() || ""
    const preview = rawContent.replace(/```\w*\n?/g, "").replace(/```/g, "").trim().slice(0, 80)

    // Check if we're in a DM context
    const isDM = !!document.querySelector("[data-controller*='dm-message-form']")

    // Backdrop
    const backdrop = document.createElement("div")
    backdrop.className = "modal-overlay fixed inset-0 bg-black/50 z-[100]"
    backdrop.addEventListener("click", this._dismiss)

    // Sheet
    const sheet = document.createElement("div")
    sheet.className = "fixed bottom-0 left-0 right-0 z-[101] bg-gray-800 rounded-t-2xl shadow-2xl border-t border-gray-700 context-pop"
    sheet.innerHTML = `
      <div class="w-10 h-1 bg-gray-600 rounded-full mx-auto mt-3 mb-2"></div>
      <div class="px-4 pb-2">
        <p class="text-xs text-gray-400 truncate mb-3">${this._escapeHtml(preview)}</p>
      </div>
      <div class="px-2 pb-6 space-y-1">
        <button data-sheet-action="reply" class="flex items-center w-full px-4 py-3 text-sm text-gray-200 hover:bg-gray-700 rounded-lg active:bg-gray-600 transition">
          <svg class="w-5 h-5 mr-3 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 10h10a8 8 0 018 8v2M3 10l6 6m-6-6l6-6"/></svg>
          Reply
        </button>
        ${isDM ? "" : `<button data-sheet-action="react" class="flex items-center w-full px-4 py-3 text-sm text-gray-200 hover:bg-gray-700 rounded-lg active:bg-gray-600 transition">
          <svg class="w-5 h-5 mr-3 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14.828 14.828a4 4 0 01-5.656 0M9 10h.01M15 10h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
          Add Reaction
        </button>`}
        <button data-sheet-action="copy" class="flex items-center w-full px-4 py-3 text-sm text-gray-200 hover:bg-gray-700 rounded-lg active:bg-gray-600 transition">
          <svg class="w-5 h-5 mr-3 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>
          Copy Text
        </button>
      </div>
    `

    sheet.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-sheet-action]")
      if (!btn) return

      const action = btn.dataset.sheetAction
      if (action === "reply") {
        document.dispatchEvent(new CustomEvent("inferno:reply", {
          detail: { messageId, authorName, preview },
          bubbles: true
        }))
      } else if (action === "react") {
        document.dispatchEvent(new CustomEvent("inferno:react", {
          detail: { messageId },
          bubbles: true
        }))
      } else if (action === "copy") {
        navigator.clipboard?.writeText(rawContent).catch(() => {})
      }

      this._dismiss()
    })

    document.body.appendChild(backdrop)
    document.body.appendChild(sheet)
    this._backdrop = backdrop
    this._sheet = sheet
    document.body.style.overflow = "hidden"
  }

  _dismiss() {
    this._removeSheet()
  }

  _removeSheet() {
    if (this._backdrop) {
      this._backdrop.remove()
      this._backdrop = null
    }
    if (this._sheet) {
      this._sheet.remove()
      this._sheet = null
    }
    document.body.style.overflow = ""
  }

  _escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  }
}
