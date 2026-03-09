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

}
