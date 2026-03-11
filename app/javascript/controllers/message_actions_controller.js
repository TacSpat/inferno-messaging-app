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
    const authorId = msgEl.dataset.authorId
    const currentUserId = document.body.dataset.currentUserId
    const isOwner = authorId && currentUserId && authorId === currentUserId

    const authorEl = msgEl.querySelector("[style*='color:']")
    const authorName = authorEl?.textContent?.trim() || "Unknown"
    const contentEl = msgEl.querySelector(".message-content")
    const rawContent = contentEl?.dataset?.rawContent || contentEl?.textContent?.trim() || ""
    const preview = rawContent.replace(/```\w*\n?/g, "").replace(/```/g, "").trim().slice(0, 80)

    // Backdrop
    const backdrop = document.createElement("div")
    backdrop.className = "modal-overlay fixed inset-0 bg-black/50 z-[100]"
    backdrop.addEventListener("click", this._dismiss)

    // Sheet
    const sheet = document.createElement("div")
    sheet.className = "fixed bottom-0 left-0 right-0 z-[101] bg-gray-800 rounded-t-2xl shadow-2xl border-t border-gray-700 context-pop"
    const tpl = document.getElementById("tpl-action-sheet")
    const clone = tpl.content.cloneNode(true)
    clone.querySelector('[data-slot="preview"]').textContent = preview

    // Show edit/delete buttons if the current user authored this message
    const isSticker = msgEl.dataset.isSticker === "true"
    if (isOwner) {
      clone.querySelectorAll("[data-owner-only]").forEach(btn => {
        if (isSticker && btn.dataset.sheetAction === "edit") return
        btn.classList.remove("hidden")
      })
    }

    // Show pin button if user has permission (server context) or in DM context
    const pinBtn = clone.querySelector('[data-sheet-action="pin"]')
    if (pinBtn) {
      const canPin = msgEl.closest("[data-can-pin='true']") || msgEl.closest("[data-controller~='dm-message-form']")
      if (canPin) {
        pinBtn.classList.remove("hidden")
        const pinLabel = pinBtn.querySelector("[data-pin-label]")
        if (pinLabel) {
          pinLabel.textContent = msgEl.dataset.pinned === "true" ? "Unpin Message" : "Pin Message"
        }
      }
    }

    sheet.appendChild(clone)

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
      } else if (action === "copy-link") {
        const el = document.querySelector("[data-current-server-id]")
        const sId = el ? el.dataset.currentServerId : ""
        const cId = el ? el.dataset.currentChannelId : ""
        if (sId && cId) {
          const link = `${window.location.origin}/servers/${sId}/channels/${cId}#message-${messageId}`
          navigator.clipboard?.writeText(link).catch(() => {})
        } else {
          // DM context — use conversation URL
          const convEl = msgEl.closest("[data-conversation-id]")
          const convId = convEl?.dataset?.conversationId || ""
          const link = `${window.location.origin}/conversations/${convId}#message-${messageId}`
          navigator.clipboard?.writeText(link).catch(() => {})
        }
      } else if (action === "edit") {
        const contentEl = msgEl.querySelector(".message-content")
        const editContent = contentEl?.dataset?.rawContent || contentEl?.textContent?.trim() || ""
        const editPreview = editContent.substring(0, 80) + (editContent.length > 80 ? "..." : "")
        const attachments = []
        msgEl.querySelectorAll("[data-attachment-id]").forEach(el => {
          attachments.push({ id: el.dataset.attachmentId, type: el.dataset.attachmentType || "file", name: el.dataset.attachmentName || "file", url: el.dataset.attachmentUrl })
        })
        document.dispatchEvent(new CustomEvent("inferno:edit", {
          detail: { messageId, content: editContent, preview: editPreview, attachments },
          bubbles: true
        }))
      } else if (action === "pin") {
        const pinUrl = msgEl.dataset.pinUrl
        if (pinUrl) {
          const token = document.querySelector("meta[name=csrf-token]")?.content
          fetch(pinUrl, { method: "POST", headers: { "X-CSRF-Token": token } })
        }
      } else if (action === "delete") {
        const ctrl = this.application.getControllerForElementAndIdentifier(
          document.querySelector("[data-controller~='notification-badge']"),
          "notification-badge"
        )
        if (ctrl) ctrl.deleteMessage(messageId)
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

  toggleSpoiler(e) {
    const btn = e.currentTarget
    const messageId = btn.dataset.messageId
    const msgEl = document.getElementById(`message_${messageId}`)
    if (!msgEl) return

    const media = msgEl.querySelectorAll("img[data-preview-src], video")
    media.forEach(el => {
      const wrapper = el.closest("[data-attachment-id]") || el.parentElement
      if (el.classList.contains("spoiler-blur")) {
        // Remove spoiler
        el.classList.remove("spoiler-blur", "unblurred")
        const label = wrapper.querySelector(".spoiler-label")
        if (label) label.remove()
      } else {
        // Add spoiler
        el.classList.add("spoiler-blur")
        el.classList.remove("unblurred")
        if (!wrapper.querySelector(".spoiler-label")) {
          wrapper.style.position = "relative"
          const label = document.createElement("div")
          label.className = "spoiler-label"
          label.innerHTML = '<span>SPOILER</span>'
          wrapper.appendChild(label)
        }
      }
    })
  }

  hideMessage(e) {
    const btn = e.currentTarget
    const hideUrl = btn.dataset.hideUrl
    if (!hideUrl) return

    this._showHideModal(hideUrl, btn)
  }

  _showHideModal(hideUrl, triggerBtn) {
    const overlay = document.createElement("div")
    overlay.className = "modal-overlay fixed inset-0 z-[100] flex items-center justify-center bg-black/60"
    overlay.innerHTML = `
      <div class="bg-gray-800 rounded-lg shadow-2xl border border-gray-700 w-full max-w-sm mx-4 overflow-hidden max-h-[90vh] flex flex-col">
        <div class="px-5 pt-5 pb-4 overflow-y-auto">
          <div class="flex items-center gap-2 mb-3">
            <svg class="w-5 h-5 text-gray-400 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.878 9.878L6.11 6.11m3.768 3.768l4.242 4.242m0 0l3.768 3.768M6.11 6.11L3 3m3.11 3.11l11.78 11.78M21 21l-3.11-3.11"/>
            </svg>
            <h3 class="text-lg font-semibold text-white">Hide Message</h3>
          </div>
          <p class="text-sm text-gray-400 mb-4">This message will be removed from your view. Attached media will be purged and its fingerprint shared with the network. Why are you hiding this?</p>
          <div class="space-y-2" data-hide-reasons>
            <label class="flex items-center gap-3 p-2.5 rounded-lg border border-gray-700 hover:border-gray-600 cursor-pointer transition has-[:checked]:border-accent/50 has-[:checked]:bg-accent/5">
              <input type="radio" name="hide_reason" value="other" checked class="w-4 h-4 text-accent bg-gray-900 border-gray-600 focus:ring-accent focus:ring-offset-0">
              <div>
                <span class="text-sm font-medium text-white">I don't want to see this</span>
                <p class="text-xs text-gray-500">Not relevant, annoying, or just not for me</p>
              </div>
            </label>
            <label class="flex items-center gap-3 p-2.5 rounded-lg border border-gray-700 hover:border-gray-600 cursor-pointer transition has-[:checked]:border-accent/50 has-[:checked]:bg-accent/5">
              <input type="radio" name="hide_reason" value="spam" class="w-4 h-4 text-accent bg-gray-900 border-gray-600 focus:ring-accent focus:ring-offset-0">
              <div>
                <span class="text-sm font-medium text-white">Spam or advertising</span>
                <p class="text-xs text-gray-500">Unsolicited promotion, bot messages, or repeated junk</p>
              </div>
            </label>
            <label class="flex items-center gap-3 p-2.5 rounded-lg border border-gray-700 hover:border-gray-600 cursor-pointer transition has-[:checked]:border-accent/50 has-[:checked]:bg-accent/5">
              <input type="radio" name="hide_reason" value="harassment" class="w-4 h-4 text-accent bg-gray-900 border-gray-600 focus:ring-accent focus:ring-offset-0">
              <div>
                <span class="text-sm font-medium text-white">Harassment or bullying</span>
                <p class="text-xs text-gray-500">Targeted attacks, threats, or intimidating behavior</p>
              </div>
            </label>
            <label class="flex items-center gap-3 p-2.5 rounded-lg border border-gray-700 hover:border-gray-600 cursor-pointer transition has-[:checked]:border-accent/50 has-[:checked]:bg-accent/5">
              <input type="radio" name="hide_reason" value="graphic" class="w-4 h-4 text-accent bg-gray-900 border-gray-600 focus:ring-accent focus:ring-offset-0">
              <div>
                <span class="text-sm font-medium text-white">Graphic or disturbing content</span>
                <p class="text-xs text-gray-500">Gore, violence, shocking imagery, or upsetting material</p>
              </div>
            </label>
            <label class="flex items-center gap-3 p-2.5 rounded-lg border border-gray-700 hover:border-gray-600 cursor-pointer transition has-[:checked]:border-accent/50 has-[:checked]:bg-accent/5">
              <input type="radio" name="hide_reason" value="exploitation" class="w-4 h-4 text-accent bg-gray-900 border-gray-600 focus:ring-accent focus:ring-offset-0">
              <div>
                <span class="text-sm font-medium text-white">Exploitation or abuse</span>
                <p class="text-xs text-gray-500">Content that exploits or harms vulnerable people, including minors</p>
              </div>
            </label>
            <label class="flex items-center gap-3 p-2.5 rounded-lg border border-gray-700 hover:border-gray-600 cursor-pointer transition has-[:checked]:border-accent/50 has-[:checked]:bg-accent/5">
              <input type="radio" name="hide_reason" value="illegal" class="w-4 h-4 text-accent bg-gray-900 border-gray-600 focus:ring-accent focus:ring-offset-0">
              <div>
                <span class="text-sm font-medium text-white">Illegal activity</span>
                <p class="text-xs text-gray-500">Promotes or depicts something that violates the law</p>
              </div>
            </label>
            <label class="flex items-center gap-3 p-2.5 rounded-lg border border-gray-700 hover:border-gray-600 cursor-pointer transition has-[:checked]:border-accent/50 has-[:checked]:bg-accent/5">
              <input type="radio" name="hide_reason" value="misinformation" class="w-4 h-4 text-accent bg-gray-900 border-gray-600 focus:ring-accent focus:ring-offset-0">
              <div>
                <span class="text-sm font-medium text-white">Misinformation</span>
                <p class="text-xs text-gray-500">Deliberately false or misleading claims</p>
              </div>
            </label>
          </div>
        </div>
        <div class="flex justify-end gap-3 px-5 py-4 bg-gray-900/50 border-t border-gray-700">
          <button data-action="cancel" class="px-4 py-2 text-sm font-medium text-gray-300 hover:text-white hover:underline cursor-pointer">Cancel</button>
          <button data-action="confirm" class="px-4 py-2 text-sm font-medium bg-gray-700 hover:bg-gray-600 text-white rounded transition cursor-pointer">Hide Message</button>
        </div>
      </div>
    `

    const cleanup = () => overlay.remove()

    overlay.addEventListener("click", (ev) => {
      if (ev.target === overlay) cleanup()
    })
    overlay.querySelector('[data-action="cancel"]').addEventListener("click", cleanup)
    overlay.querySelector('[data-action="confirm"]').addEventListener("click", () => {
      const checked = overlay.querySelector('input[name="hide_reason"]:checked')
      const reason = checked ? checked.value : "other"
      cleanup()

      const token = document.querySelector("meta[name=csrf-token]")?.content
      fetch(hideUrl, {
        method: "POST",
        headers: { "X-CSRF-Token": token, "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json" },
        body: `reason=${encodeURIComponent(reason)}`
      }).then(res => {
        if (res.ok) {
          const msgEl = triggerBtn.closest("[data-message-id]")
          if (msgEl) msgEl.remove()
          this._showHideFeedback()
        }
      })
    })

    document.addEventListener("keydown", function handler(ev) {
      if (ev.key === "Escape") { document.removeEventListener("keydown", handler); cleanup() }
    })

    document.body.appendChild(overlay)
    overlay.querySelector('[data-action="confirm"]').focus()
  }

  _showHideFeedback() {
    const toast = document.createElement("div")
    toast.className = "fixed bottom-6 left-1/2 -translate-x-1/2 z-50 bg-gray-800 border border-gray-700 rounded-lg shadow-xl px-4 py-3 flex items-center gap-3 max-w-sm"
    toast.innerHTML = `
      <svg class="w-5 h-5 text-green-400 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z"/>
      </svg>
      <div>
        <p class="text-sm text-white font-medium">Content hidden</p>
        <p class="text-xs text-gray-400">Its fingerprint has been shared with the network to protect other users.</p>
      </div>
    `
    document.body.appendChild(toast)
    setTimeout(() => {
      toast.style.transition = "opacity 0.5s ease-out"
      toast.style.opacity = "0"
      setTimeout(() => toast.remove(), 500)
    }, 4000)
  }

}
