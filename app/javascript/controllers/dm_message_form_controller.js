import { Controller } from "@hotwired/stimulus"
import consumer from "../lib/cable"

export default class extends Controller {
  static targets = ["highlight", "input", "filePreview", "dropzone", "replyBar", "replyAuthor", "replyPreview", "parentId", "pinButton", "pinBadge", "editBar", "editPreview"]
  static values = { conversationId: String }

  connect() {
    this.subscription = consumer.subscriptions.create(
      { channel: "ConversationChannel", conversation_id: this.conversationIdValue },
      {
        received: (data) => this.handleReceived(data),
        typing() {
          this.perform("typing")
        }
      }
    )
    this.pendingFiles = []
    this.setupDragAndDrop()
    this.setupPaste()
    this.setupFileIntercept()

    this._replyHandler = (e) => {
      const { messageId, authorName, preview } = e.detail
      if (this.hasParentIdTarget) this.parentIdTarget.value = messageId
      if (this.hasReplyAuthorTarget) this.replyAuthorTarget.textContent = authorName
      if (this.hasReplyPreviewTarget) this.replyPreviewTarget.textContent = preview
      if (this.hasReplyBarTarget) this.replyBarTarget.classList.remove("hidden")
      this.inputTarget.focus()
    }
    this._reactHandler = (e) => {
      const { messageId, clientX, clientY } = e.detail
      this.openReactionPickerForMessage(messageId, clientX, clientY)
    }
    this._editHandler = (e) => {
      const { messageId, content, preview } = e.detail
      this._editMessageId = messageId
      this._editOriginalContent = this.inputTarget.value
      this.inputTarget.value = content
      if (this.hasEditPreviewTarget) this.editPreviewTarget.textContent = preview
      if (this.hasEditBarTarget) this.editBarTarget.classList.remove("hidden")
      this.autoResize()
      this.inputTarget.focus()
      this.inputTarget.setSelectionRange(this.inputTarget.value.length, this.inputTarget.value.length)
    }
    document.addEventListener("inferno:reply", this._replyHandler)
    document.addEventListener("inferno:react", this._reactHandler)
    document.addEventListener("inferno:edit", this._editHandler)

    // Pin click delegation
    this._pinClickHandler = (e) => {
      const btn = e.target.closest("[data-pin-toggle]")
      if (!btn) return
      e.preventDefault()
      const url = btn.dataset.pinUrl
      if (!url) return
      const token = document.querySelector("meta[name=csrf-token]")?.content
      fetch(url, { method: "POST", headers: { "X-CSRF-Token": token } })
    }
    this.element.addEventListener("click", this._pinClickHandler)

    // Auto-focus: redirect keystrokes to message input when nothing else is focused
    this._autoFocusHandler = (e) => this._handleAutoFocus(e)
    document.addEventListener("keydown", this._autoFocusHandler)

    // Measure emoji placeholder width for pixel-perfect overlay
    this._measureEmojiWidth()

    // Render any existing emoji content (e.g. after page refresh)
    this.autoResize()

    // Re-render when emoji maps load asynchronously
    this._emojiMapReady = () => {
      this._replaceEmojisWithPUA()
      this.updateHighlight()
    }
    document.addEventListener("inferno:emoji-map-ready", this._emojiMapReady)

    // Show pin badge only if there are unseen pins
    if (this.hasPinBadgeTarget) {
      const currentCount = parseInt(this.pinBadgeTarget.textContent) || 0
      const seen = parseInt(localStorage.getItem(`seenPins_dm_${this.conversationIdValue}`)) || 0
      if (currentCount > 0 && currentCount > seen) this.pinBadgeTarget.classList.remove("hidden")
    }
  }

  disconnect() {
    this.subscription?.unsubscribe()
    this.teardownDragAndDrop()
    this.teardownPaste()
    this.teardownFileIntercept()
    if (this._autoFocusHandler) document.removeEventListener("keydown", this._autoFocusHandler)
    if (this._emojiMapReady) document.removeEventListener("inferno:emoji-map-ready", this._emojiMapReady)
    if (this._pinClickHandler) this.element.removeEventListener("click", this._pinClickHandler)
    if (this._replyHandler) document.removeEventListener("inferno:reply", this._replyHandler)
    if (this._reactHandler) document.removeEventListener("inferno:react", this._reactHandler)
    if (this._editHandler) document.removeEventListener("inferno:edit", this._editHandler)
  }

  // --- Auto-focus: redirect typing to message input ---

  _handleAutoFocus(e) {
    const active = document.activeElement
    if (active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA" || active.isContentEditable)) return
    if (e.ctrlKey || e.metaKey || e.altKey) return
    if (e.key.length !== 1 && e.key !== "Enter") return
    if (document.querySelector(".context-pop, [data-modal]")) return
    this.inputTarget.focus()
  }

  // --- Paste ---

  setupPaste() {
    this._pasteHandler = (e) => {
      const items = e.clipboardData?.items
      if (!items) return
      // If clipboard has text, it's a copy-paste (not a screenshot) — let browser handle it
      if (e.clipboardData.types.includes("text/plain") || e.clipboardData.types.includes("text/html")) return
      const files = []
      for (const item of items) {
        if (item.kind === "file" && item.type.startsWith("image/")) {
          const file = item.getAsFile()
          if (file) files.push(file)
        }
      }
      if (files.length > 0) {
        e.preventDefault()
        this.addFiles(files)
      }
    }
    this.element.addEventListener("paste", this._pasteHandler)
  }

  teardownPaste() {
    if (this._pasteHandler) {
      this.element.removeEventListener("paste", this._pasteHandler)
    }
  }

  // --- Direct form submission (bypasses Turbo for reliable file uploads) ---

  setupFileIntercept() {
    const form = this.element.querySelector("form")
    if (!form) return
    this._formSubmitHandler = (event) => {
      event.preventDefault()
      this.submitMessage()
    }
    form.addEventListener("submit", this._formSubmitHandler)
  }

  teardownFileIntercept() {
    const form = this.element.querySelector("form")
    if (form && this._formSubmitHandler) {
      form.removeEventListener("submit", this._formSubmitHandler)
    }
  }

  async submitMessage() {
    if (this._submitting) return
    const form = this.element.querySelector("form")
    if (!form) return

    const content = this.inputTarget.value.trim()
    const hasFiles = this.pendingFiles.length > 0
    if (!content && !hasFiles) return

    // Convert emoji placeholders back to :name: before sending
    let msgContent = content
    if (msgContent && window._emojiReverse) {
      msgContent = msgContent.replace(/\u2003([\uE000-\uF8FF])/g, (m, ch, offset, str) => {
        const name = window._emojiReverse[ch]
        if (!name) return m
        const next = str[offset + m.length]
        return `:${name}:` + (next === '\u2003' ? ' ' : '')
      })
    }

    this._submitting = true

    // Edit mode: PATCH the existing message
    if (this._editMessageId) {
      const conversationId = this.conversationIdValue
      const url = `/conversations/${conversationId}/dm_messages/${this._editMessageId}`
      const token = document.querySelector("meta[name=csrf-token]")?.content
      try {
        const response = await fetch(url, {
          method: "PATCH",
          headers: { "X-CSRF-Token": token, "Content-Type": "application/json", "Accept": "text/html" },
          body: JSON.stringify({ message: { content: msgContent } })
        })
        if (response.ok) {
          this._editOriginalContent = null
          this._editMessageId = null
          this.inputTarget.value = ""
          this.updateHighlight()
          this.inputTarget.style.height = "auto"
          this.inputTarget.style.fontFamily = ""
          this.inputTarget.style.fontSize = ""
          if (this.inputTarget.parentElement) this.inputTarget.parentElement.style.backgroundColor = ""
          if (this.hasEditBarTarget) this.editBarTarget.classList.add("hidden")
        }
      } catch(e) {
        console.error("DM message edit failed:", e)
      } finally {
        this._submitting = false
      }
      return
    }

    const formData = new FormData(form)

    // Remove empty file input entries and inject real files from array
    formData.delete("message[files][]")
    if (hasFiles) {
      for (const file of this.pendingFiles) {
        formData.append("message[files][]", file)
      }
    }

    // Set the emoji-converted content
    formData.set("message[content]", msgContent)

    const token = document.querySelector("meta[name=csrf-token]")?.content
    try {
      const response = await fetch(form.action, {
        method: "POST",
        headers: {
          "Accept": "text/vnd.turbo-stream.html, text/html, application/xhtml+xml",
          "X-CSRF-Token": token,
        },
        body: formData
      })

      if (response.ok) {
        this.inputTarget.value = ""
        this.updateHighlight()
        this.inputTarget.style.height = "auto"
        this.inputTarget.style.fontFamily = ""
        this.inputTarget.style.fontSize = ""
        if (this.inputTarget.parentElement) this.inputTarget.parentElement.style.backgroundColor = ""
        this.pendingFiles = []
        this.renderPreviews()
        this.clearReply()
      }
    } catch(e) {
      console.error("DM message send failed:", e)
    } finally {
      this._submitting = false
    }
  }

  // --- File Preview + Remove + Drag-and-Drop ---

  setupDragAndDrop() {
    this._dragCounter = 0
    this._dragEnter = (e) => {
      e.preventDefault()
      if (!e.dataTransfer?.types?.includes("Files")) return
      this._dragCounter++
      if (this._dragCounter === 1) this.dropzoneTarget.classList.remove("hidden")
    }
    this._dragOver = (e) => { e.preventDefault() }
    this._dragLeave = (e) => {
      e.preventDefault()
      if (!e.dataTransfer?.types?.includes("Files")) return
      this._dragCounter--
      if (this._dragCounter <= 0) {
        this._dragCounter = 0
        this.dropzoneTarget.classList.add("hidden")
      }
    }
    this._drop = (e) => {
      e.preventDefault()
      this._dragCounter = 0
      this.dropzoneTarget.classList.add("hidden")
      if (e.dataTransfer.files.length) {
        this.addFiles(e.dataTransfer.files)
      }
    }
    document.addEventListener("dragenter", this._dragEnter)
    document.addEventListener("dragover", this._dragOver)
    document.addEventListener("dragleave", this._dragLeave)
    document.addEventListener("drop", this._drop)
  }

  teardownDragAndDrop() {
    document.removeEventListener("dragenter", this._dragEnter)
    document.removeEventListener("dragover", this._dragOver)
    document.removeEventListener("dragleave", this._dragLeave)
    document.removeEventListener("drop", this._drop)
  }

  handleFileSelect(event) {
    this.addFiles(event.target.files)
    event.target.value = ""
  }

  addFiles(files) {
    for (const file of files) {
      this.pendingFiles.push(file)
    }
    this.renderPreviews()
  }

  removeFile(event) {
    const index = parseInt(event.currentTarget.dataset.index)
    this.pendingFiles.splice(index, 1)
    this.renderPreviews()
  }

  renderPreviews() {
    const container = this.filePreviewTarget
    container.innerHTML = ""
    if (this.pendingFiles.length === 0) {
      container.classList.add("hidden")
      return
    }
    container.classList.remove("hidden")
    this.pendingFiles.forEach((file, i) => {
      const wrapper = document.createElement("div")
      wrapper.className = "relative inline-flex items-center bg-gray-700 rounded-lg p-2 mr-2 mb-2"

      if (file.type.startsWith("image/")) {
        const img = document.createElement("img")
        img.className = "w-16 h-16 object-cover rounded"
        img.src = URL.createObjectURL(file)
        wrapper.appendChild(img)
      } else {
        const name = document.createElement("span")
        name.className = "text-xs text-gray-200 max-w-[100px] truncate"
        name.textContent = file.name
        wrapper.appendChild(name)
      }

      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "absolute -top-1.5 -right-1.5 w-5 h-5 bg-danger hover:bg-danger-light rounded-full flex items-center justify-center text-white text-xs cursor-pointer"
      btn.innerHTML = "&times;"
      btn.dataset.index = i
      btn.dataset.action = "click->dm-message-form#removeFile"
      wrapper.appendChild(btn)

      container.appendChild(wrapper)
    })
  }

  // --- Replies ---

  setReply(event) {
    const btn = event.currentTarget
    const messageId = btn.dataset.messageId
    const authorName = btn.dataset.authorName
    const preview = btn.dataset.preview
    this.parentIdTarget.value = messageId
    this.replyAuthorTarget.textContent = authorName
    this.replyPreviewTarget.textContent = preview
    this.replyBarTarget.classList.remove("hidden")
    this.inputTarget.focus()
  }

  clearReply() {
    this.parentIdTarget.value = ""
    this.replyBarTarget.classList.add("hidden")
  }

  clearEdit() {
    this._editMessageId = null
    if (this.hasEditBarTarget) this.editBarTarget.classList.add("hidden")
    this.inputTarget.value = this._editOriginalContent || ""
    this._editOriginalContent = null
    this.autoResize()
  }

  // --- Reactions ---

  openReactionPicker(event) {
    const messageId = event.currentTarget.dataset.messageId
    this.openReactionPickerForMessage(messageId)
  }

  openReactionPickerForMessage(messageId, clientX, clientY) {
    document.getElementById("reaction-picker-panel")?.remove()
    document.dispatchEvent(new CustomEvent("inferno:open-reaction-picker", {
      detail: {
        messageId,
        reactionUrl: `/conversations/${this.conversationIdValue}/dm_messages/${messageId}/toggle_reaction`,
        anchorSelector: `#message_${messageId}`,
        clientX,
        clientY
      }
    }))
  }

  toggleReaction(event) {
    const btn = event.currentTarget
    const messageId = btn.dataset.messageId
    const emoji = btn.dataset.emoji
    const token = document.querySelector("meta[name=csrf-token]")?.content
    const formData = new FormData()
    formData.append("emoji", emoji)
    fetch(`/conversations/${this.conversationIdValue}/dm_messages/${messageId}/toggle_reaction`, {
      method: "POST",
      headers: { "X-CSRF-Token": token },
      body: formData
    })
  }

  // --- Input handling ---

  handleKeydown(event) {
    if (this._handleEmojiKeydown(event)) return
    if (event.key === "Escape" && this._editMessageId) {
      event.preventDefault()
      this.clearEdit()
      return
    }
    if (event.key === "Enter" && !event.shiftKey) {
      const content = this.inputTarget.value
      const backtickCount = (content.match(/`{3}/g) || []).length
      if (backtickCount % 2 === 1) return
      event.preventDefault()
      this.submitMessage()
    }
  }

  handleSubmit(event) {
    // Legacy handler for turbo:submit-end — no longer used since we submit via fetch directly
    if (event.detail?.success) {
      this.inputTarget.value = ""
      this.updateHighlight()
      this.inputTarget.style.height = "auto"
      this.inputTarget.style.fontFamily = ""
      this.inputTarget.style.fontSize = ""
      if (this.inputTarget.parentElement) this.inputTarget.parentElement.style.backgroundColor = ""
      this.pendingFiles = []
      this.renderPreviews()
      this.clearReply()
    }
  }

  autoResize() {
    this._replaceEmojisWithPUA()
    this.updateHighlight()
    const input = this.inputTarget
    input.style.height = "auto"
    input.style.height = Math.min(input.scrollHeight, 192) + "px"
    this.updateCodeBlockStyle()
  }

  updateCodeBlockStyle() {
    const input = this.inputTarget
    const highlight = this.hasHighlightTarget ? this.highlightTarget : null
    const val = input.value
    const tripleCount = (val.match(/`{3}/g) || []).length
    const inCodeBlock = tripleCount % 2 === 1
    if (inCodeBlock) {
      const mono = "Consolas, Monaco, 'Courier New', monospace"
      input.style.fontFamily = mono
      input.style.fontSize = "0.8rem"
      input.setAttribute("spellcheck", "false")
      if (highlight) { highlight.style.fontFamily = mono; highlight.style.fontSize = "0.8rem" }
      if (input.parentElement) input.parentElement.style.backgroundColor = "var(--color-gray-950)"
    } else {
      input.style.fontFamily = ""
      input.style.fontSize = ""
      input.removeAttribute("spellcheck")
      if (highlight) { highlight.style.fontFamily = ""; highlight.style.fontSize = "" }
      if (input.parentElement) input.parentElement.style.backgroundColor = ""
    }
  }

  // --- ActionCable ---

  handleReceived(data) {
    if (data.type === "presence") {
      const currentUserId = document.body.dataset.currentUserId
      if (String(data.user_id) !== String(currentUserId)) {
        this._updatePresenceDots(data.state)
      }
      return
    }

    const messagesDiv = document.getElementById("messages")
    if (!messagesDiv) return

    switch (data.type) {
      case "new_message":
        const welcome = messagesDiv.querySelector(".text-center")
        if (welcome) welcome.remove()
        const nearBottom = (messagesDiv.scrollHeight - messagesDiv.scrollTop - messagesDiv.clientHeight) < 150
        messagesDiv.insertAdjacentHTML("beforeend", data.html)
        const dmNewEl = messagesDiv.lastElementChild
        if (dmNewEl) {
          dmNewEl.classList.add("message-appear")
          dmNewEl.addEventListener("animationend", () => dmNewEl.classList.remove("message-appear"), { once: true })
        }
        if (nearBottom) messagesDiv.scrollTop = messagesDiv.scrollHeight
        break
      case "update_message":
        const existing = document.getElementById(`message_${data.message_id}`)
        if (existing) existing.outerHTML = data.html
        break
      case "update_message_content":
        const contentTarget = document.getElementById(`message_${data.message_id}`)
        if (contentTarget) {
          const contentDiv = contentTarget.querySelector(".message-content")
          if (contentDiv) contentDiv.innerHTML = data.html
        }
        break
      case "delete_message":
        const toDelete = document.getElementById(`message_${data.message_id}`)
        if (toDelete) toDelete.remove()
        break
      case "update_reactions":
        const reactMsg = document.getElementById(`message_${data.message_id}`)
        if (reactMsg) {
          const rc = reactMsg.querySelector(".reactions-container")
          if (rc) rc.outerHTML = data.html
        }
        break
      case "pin_update":
        if (this.hasPinBadgeTarget) {
          const count = data.pin_count || 0
          const seen = parseInt(localStorage.getItem(`seenPins_dm_${this.conversationIdValue}`)) || 0
          const hasNew = count > seen
          this.pinBadgeTargets.forEach(badge => {
            badge.textContent = count
            badge.classList.toggle("hidden", !hasNew)
          })
        }
        this._refreshPinnedPanel()
        break
      case "typing":
        this.showTypingIndicator(data.username, data.user_id)
        break
      default:
        // Forward call events and other unknown types to DOM for other controllers
        document.dispatchEvent(new CustomEvent("cable:conversation_message", { detail: data }))
        break
    }
  }

  _updatePresenceDots(state) {
    const colorMap = { online: "bg-green-500", idle: "bg-warning", dnd: "bg-red-500", offline: "bg-gray-500" }
    const cls = colorMap[state] || "bg-gray-500"
    document.querySelectorAll("[data-dm-presence-dot]").forEach(dot => {
      dot.classList.remove("bg-green-500", "bg-warning", "bg-red-500", "bg-gray-500")
      dot.classList.add(cls)
    })
  }

  // --- Pinned messages panel ---

  async togglePinnedPanel(event) {
    const existing = this.element.querySelector(".pinned-panel")
    if (existing) { existing.remove(); return }

    const btn = event.currentTarget
    const url = btn.dataset.pinnedUrl
    if (!url) return

    const resp = await fetch(url, { headers: { "Accept": "text/html" } })
    if (!resp.ok) return
    const html = await resp.text()

    const panel = document.createElement("div")
    panel.className = "pinned-panel absolute z-50 bg-gray-900 border border-gray-700 rounded-lg shadow-2xl w-80 max-h-96 overflow-y-auto context-pop"
    panel.style.top = "100%"
    panel.style.right = "0"
    panel.style.marginTop = "4px"

    const header = document.createElement("div")
    header.className = "flex items-center justify-between px-3 py-2 border-b border-gray-700 sticky top-0 bg-gray-900 z-10"
    header.innerHTML = `
      <span class="text-sm font-semibold text-white">Pinned Messages</span>
      <button type="button" class="text-gray-400 hover:text-white cursor-pointer">
        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>
      </button>
    `
    header.querySelector("button").addEventListener("click", () => panel.remove())
    panel.appendChild(header)

    const content = document.createElement("div")
    content.innerHTML = html
    panel.appendChild(content)

    panel.addEventListener("click", (e) => {
      const row = e.target.closest("[data-jump-to-message]")
      if (!row) return
      const msgId = row.dataset.jumpToMessage
      const el = document.getElementById(`message_${msgId}`)
      if (el) {
        el.scrollIntoView({ behavior: "smooth", block: "center" })
        el.style.backgroundColor = "rgb(var(--accent) / 0.3)"
        el.style.borderRadius = "4px"
        setTimeout(() => {
          el.style.transition = "background-color 0.8s ease-out"
          el.style.backgroundColor = "transparent"
          setTimeout(() => { el.style.backgroundColor = ""; el.style.borderRadius = ""; el.style.transition = "" }, 800)
        }, 1000)
      }
      panel.remove()
    })

    btn.closest(".relative").appendChild(panel)

    // Hide the badge — user has seen the pins, persist in localStorage
    if (this.hasPinBadgeTarget) {
      this.pinBadgeTarget.classList.add("hidden")
      const count = parseInt(this.pinBadgeTarget.textContent) || 0
      try { localStorage.setItem(`seenPins_dm_${this.conversationIdValue}`, count) } catch {}
    }

    const dismiss = (e) => {
      if (!panel.contains(e.target) && !btn.contains(e.target)) {
        panel.remove()
        document.removeEventListener("click", dismiss)
      }
    }
    setTimeout(() => document.addEventListener("click", dismiss), 0)
  }

  async _refreshPinnedPanel() {
    const panel = this.element.querySelector(".pinned-panel")
    if (!panel) return
    const btn = this.element.querySelector("[data-pinned-url]")
    if (!btn) return
    const resp = await fetch(btn.dataset.pinnedUrl, { headers: { "Accept": "text/html" } })
    if (!resp.ok) return
    const html = await resp.text()
    const contentDiv = panel.querySelector(":scope > div:last-child")
    if (contentDiv) contentDiv.innerHTML = html
  }

  showTypingIndicator(username, userId) {
    const currentUserId = document.body.dataset.currentUserId
    if (String(userId) === String(currentUserId)) return
    const indicator = document.getElementById("typing-indicator")
    if (!indicator) return
    indicator.textContent = `${username} is typing...`
    clearTimeout(this._typingTimeout)
    this._typingTimeout = setTimeout(() => {
      indicator.textContent = ""
    }, 3000)
  }

  // --- Markdown highlighting ---

  updateHighlight() {
    if (!this.hasHighlightTarget) return
    const text = this.inputTarget.value
    let html = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    html = html.replace(/(https?:\/\/[^\s<>]+)/gi, '<span class="text-accent-light">$1</span>')
    // Highlight nostr: URIs
    html = html.replace(/(nostr:naddr1[a-z0-9]+)/gi, '<span class="text-accent-light">$1</span>')
    // Extract code blocks first (complete and unclosed) to protect from other formatters
    const codeBlocks = []
    html = html.replace(/(```[\s\S]*?```|```[\s\S]*$)/g, (match) => {
      const idx = codeBlocks.length
      codeBlocks.push(this._highlightCodeBlock(match))
      return `\x00CB${idx}\x00`
    })
    // Highlight bold **text**
    html = html.replace(/\*\*(.+?)\*\*/g, '<span class="text-white font-bold">**$1**</span>')
    // Highlight italic *text*
    html = html.replace(/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/g, '<span class="text-white italic">*$1*</span>')
    // Highlight ~~strikethrough~~
    html = html.replace(/~~(.+?)~~/g, '<span class="text-gray-400 line-through">~~$1~~</span>')
    // Highlight `inline code` (safe now — code blocks are extracted)
    html = html.replace(/`([^`]+)`/g, '<span class="text-accent bg-gray-700/50 rounded px-0.5">`$1`</span>')
    // Restore code blocks
    html = html.replace(/\x00CB(\d+)\x00/g, (_, idx) => codeBlocks[parseInt(idx)])
    // Replace emoji placeholders (em-space + PUA char) with inline images
    if (window._emojiReverse && window._emojiMap) {
      html = html.replace(/\u2003([\uE000-\uF8FF])/g, (_, ch) => {
        const name = window._emojiReverse[ch]
        if (name && window._emojiMap[name]) {
          const w = this._emojiCharWidth || 20
          return `<img src="${window._emojiMap[name]}" style="display:inline-block;height:${w}px;width:${w}px;object-fit:contain;vertical-align:text-bottom;pointer-events:none">`
        }
        return _
      })
    }
    if (html.endsWith("\n")) html += "&nbsp;"
    this.highlightTarget.innerHTML = html
    this.highlightTarget.scrollTop = this.inputTarget.scrollTop
  }

  // Syntax-aware code block highlighting
  _highlightCodeBlock(block) {
    const langMatch = block.match(/^```(\w*)/)
    const lang = langMatch ? langMatch[1].toLowerCase() : ""
    const firstNewline = block.indexOf("\n")
    if (firstNewline === -1) return `<span style="color:#7c8899">${block}</span>`
    const fence = block.substring(0, firstNewline)
    const hasClose = block.endsWith("```") && block.length > fence.length + 3
    const body = hasClose ? block.substring(firstNewline + 1, block.length - 3) : block.substring(firstNewline + 1)
    const closeFence = hasClose ? "```" : ""
    const highlighted = this._syntaxHighlight(body, lang)
    if (hasClose) {
      return `<span style="display:block;background:rgba(0,0,0,0.35);border-radius:4px"><span style="color:#7c8899">${fence}</span>\n${highlighted}<span style="color:#7c8899">${closeFence}</span></span>`
    }
    return `<span style="color:#7c8899">${fence}</span>\n${highlighted}`
  }

  _syntaxHighlight(code, lang) {
    const tokens = []
    let i = 0
    while (i < code.length) {
      if (code[i] === "/" && code[i + 1] === "/") {
        const end = code.indexOf("\n", i)
        const slice = end === -1 ? code.substring(i) : code.substring(i, end)
        tokens.push({ type: "comment", text: slice }); i += slice.length; continue
      }
      if (code[i] === "#" && (lang === "ruby" || lang === "rb" || lang === "python" || lang === "py" || lang === "sh" || lang === "bash" || lang === "shell" || lang === "yml" || lang === "yaml")) {
        const end = code.indexOf("\n", i)
        const slice = end === -1 ? code.substring(i) : code.substring(i, end)
        tokens.push({ type: "comment", text: slice }); i += slice.length; continue
      }
      if (code[i] === "/" && code[i + 1] === "*") {
        const end = code.indexOf("*/", i + 2)
        const slice = end === -1 ? code.substring(i) : code.substring(i, end + 2)
        tokens.push({ type: "comment", text: slice }); i += slice.length; continue
      }
      if (code[i] === '"' || code[i] === "'") {
        const quote = code[i]; let j = i + 1
        while (j < code.length && code[j] !== quote && code[j] !== "\n") { if (code[j] === "\\") j++; j++ }
        if (j < code.length && code[j] === quote) j++
        tokens.push({ type: "string", text: code.substring(i, j) }); i = j; continue
      }
      if (code[i] === "`" && (lang === "js" || lang === "javascript" || lang === "ts" || lang === "typescript" || lang === "jsx" || lang === "tsx")) {
        let j = i + 1
        while (j < code.length && code[j] !== "`") { if (code[j] === "\\") j++; j++ }
        if (j < code.length) j++
        tokens.push({ type: "string", text: code.substring(i, j) }); i = j; continue
      }
      let j = i
      while (j < code.length) {
        if (code[j] === "/" && (code[j + 1] === "/" || code[j + 1] === "*")) break
        if (code[j] === "#" && (lang === "ruby" || lang === "rb" || lang === "python" || lang === "py" || lang === "sh" || lang === "bash" || lang === "shell" || lang === "yml" || lang === "yaml")) break
        if (code[j] === '"' || code[j] === "'") break
        if (code[j] === "`" && (lang === "js" || lang === "javascript" || lang === "ts" || lang === "typescript" || lang === "jsx" || lang === "tsx")) break
        j++
      }
      if (j > i) { tokens.push({ type: "code", text: code.substring(i, j) }); i = j }
      else { tokens.push({ type: "code", text: code[i] }); i++ }
    }
    const keywords = this._keywordsFor(lang)
    return tokens.map(t => {
      if (t.type === "comment") return `<span style="color:#6a737d;font-style:italic">${t.text}</span>`
      if (t.type === "string") return `<span style="color:#98c379">${t.text}</span>`
      if (t.type === "code") {
        let text = t.text
        text = text.replace(/\b(\d+\.?\d*)\b/g, '<span style="color:#d19a66">$1</span>')
        if (keywords) text = text.replace(new RegExp(`\\b(${keywords})\\b`, "g"), '<span style="color:#c678dd">$1</span>')
        text = text.replace(/\b(true|false|null|nil|undefined|NaN|None|True|False)\b/g, '<span style="color:#d19a66">$1</span>')
        return text
      }
      return t.text
    }).join("")
  }

  _keywordsFor(lang) {
    const JS = "const|let|var|function|return|if|else|for|while|do|switch|case|break|continue|new|this|class|extends|import|export|from|default|async|await|try|catch|finally|throw|typeof|instanceof|in|of|yield|delete|void|super|static|get|set"
    const TS = JS + "|type|interface|enum|implements|declare|as|is|keyof|readonly|abstract|override|satisfies"
    const RB = "def|end|class|module|do|if|else|elsif|unless|while|until|for|in|return|yield|begin|rescue|ensure|raise|require|require_relative|include|extend|attr_reader|attr_writer|attr_accessor|self|super|then|when|case|nil|puts|print|lambda|proc|block_given\\?"
    const PY = "def|class|if|elif|else|for|while|return|import|from|as|try|except|finally|raise|with|yield|lambda|pass|break|continue|and|or|not|in|is|global|nonlocal|assert|del|print|self|async|await"
    const CSS = "color|background|border|margin|padding|display|flex|grid|position|width|height|font|text|align|justify|overflow|opacity|transition|transform|animation|z-index|top|left|right|bottom|content|cursor|outline|box-shadow|border-radius"
    const SQL = "SELECT|FROM|WHERE|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|TABLE|ALTER|DROP|JOIN|LEFT|RIGHT|INNER|OUTER|ON|AND|OR|NOT|NULL|ORDER|BY|GROUP|HAVING|LIMIT|OFFSET|AS|DISTINCT|COUNT|SUM|AVG|MIN|MAX|UNION|INDEX|PRIMARY|KEY|FOREIGN|REFERENCES|EXISTS|IN|LIKE|BETWEEN|CASE|WHEN|THEN|ELSE|END|IS"
    const GO = "func|return|if|else|for|range|switch|case|break|continue|go|defer|select|chan|map|struct|interface|type|package|import|var|const|nil|true|false|make|len|append|cap|copy|delete|new|panic|recover|fallthrough"
    const RUST = "fn|let|mut|if|else|for|while|loop|match|return|struct|enum|impl|trait|pub|use|mod|crate|super|self|where|type|const|static|ref|move|async|await|unsafe|extern|dyn|as|in|break|continue|true|false|Some|None|Ok|Err"
    switch (lang) {
      case "js": case "javascript": case "jsx": return JS
      case "ts": case "typescript": case "tsx": return TS
      case "ruby": case "rb": return RB
      case "python": case "py": return PY
      case "css": case "scss": case "sass": return CSS
      case "sql": return SQL
      case "go": case "golang": return GO
      case "rust": case "rs": return RUST
      case "sh": case "bash": case "shell": case "zsh":
        return "if|then|else|elif|fi|for|while|do|done|case|esac|function|return|exit|echo|export|source|local|readonly|unset|shift|eval|exec|trap|cd|pwd|test"
      default: return JS
    }
  }

  // Measure exact pixel width of emoji placeholder chars in the textarea font
  _measureEmojiWidth() {
    const canvas = document.createElement('canvas')
    const ctx = canvas.getContext('2d')
    const cs = getComputedStyle(this.inputTarget)
    ctx.font = `${cs.fontSize} ${cs.fontFamily}`
    this._emojiCharWidth = ctx.measureText('\u2003\uE000').width
  }

  // Replace :emoji_name: with em-space + PUA char (2 chars ≈ 1em width)
  _replaceEmojisWithPUA() {
    if (!window._emojiPUA || !window._emojiMap) return
    const input = this.inputTarget
    const val = input.value
    if (!val.includes(':')) return

    const selStart = input.selectionStart
    const selEnd = input.selectionEnd
    let newVal = ''
    let i = 0
    let newStart = selStart
    let newEnd = selEnd

    while (i < val.length) {
      if (val[i] === ':') {
        const rest = val.substring(i + 1)
        const match = rest.match(/^([a-z0-9_]+):/)
        if (match && window._emojiPUA[match[1]]) {
          const fullLen = match[0].length + 1
          const mEnd = i + fullLen
          const replacement = '\u2003' + window._emojiPUA[match[1]]
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

  // Treat em-space + PUA pairs as atomic units for navigation
  _handleEmojiKeydown(event) {
    if (!window._emojiReverse) return false
    const input = this.inputTarget
    const val = input.value
    const pos = input.selectionStart
    if (pos !== input.selectionEnd) return false

    if (event.key === 'Backspace') {
      if (pos >= 2 && val[pos - 2] === '\u2003' && window._emojiReverse[val[pos - 1]]) {
        event.preventDefault()
        input.value = val.substring(0, pos - 2) + val.substring(pos)
        input.selectionStart = input.selectionEnd = pos - 2
        input.dispatchEvent(new Event('input', { bubbles: true }))
        return true
      }
    } else if (event.key === 'Delete') {
      if (pos <= val.length - 2 && val[pos] === '\u2003' && window._emojiReverse[val[pos + 1]]) {
        event.preventDefault()
        input.value = val.substring(0, pos) + val.substring(pos + 2)
        input.selectionStart = input.selectionEnd = pos
        input.dispatchEvent(new Event('input', { bubbles: true }))
        return true
      }
    } else if (event.key === 'ArrowLeft' && !event.shiftKey) {
      if (pos >= 2 && val[pos - 2] === '\u2003' && window._emojiReverse[val[pos - 1]]) {
        event.preventDefault()
        input.selectionStart = input.selectionEnd = pos - 2
        return true
      }
      if (pos >= 1 && val[pos - 1] === '\u2003' && pos < val.length && window._emojiReverse[val[pos]]) {
        event.preventDefault()
        input.selectionStart = input.selectionEnd = pos - 1
        return true
      }
    } else if (event.key === 'ArrowRight' && !event.shiftKey) {
      if (pos <= val.length - 2 && val[pos] === '\u2003' && window._emojiReverse[val[pos + 1]]) {
        event.preventDefault()
        input.selectionStart = input.selectionEnd = pos + 2
        return true
      }
      if (pos > 0 && val[pos - 1] === '\u2003' && pos < val.length && window._emojiReverse[val[pos]]) {
        event.preventDefault()
        input.selectionStart = input.selectionEnd = pos + 1
        return true
      }
    }
    return false
  }
}
