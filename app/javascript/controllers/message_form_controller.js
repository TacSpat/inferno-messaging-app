import { Controller } from "@hotwired/stimulus"
import consumer from "../lib/cable"

export default class extends Controller {
  static targets = ["highlight", "input", "filePreview", "dropzone", "replyBar", "replyAuthor", "replyPreview", "parentId", "messagesContainer", "timeoutBanner", "pinButton", "pinBadge", "editBar", "editPreview", "spoilerBtn", "spoilerField", "spoilerBar"]
  static values = { channelId: String, timedOutUntil: String }

  connect() {
    this.subscription = consumer.subscriptions.create(
      { channel: "ChannelChatChannel", channel_id: this.channelIdValue },
      {
        received: (data) => this.handleReceived(data)
      }
    )
    this.pendingFiles = []
    this.typingUsers = new Map()
    this.inputTarget.dataset.originalPlaceholder = this.inputTarget.placeholder
    this.inputTarget.setAttribute("spellcheck", "false")
    this.inputTarget.spellcheck = false
    this._lastTypingSent = 0
    this._submitting = false

    // Remember last visited channel per server
    const serverId = document.querySelector("[data-current-server-id]")?.dataset?.currentServerId
    if (serverId) {
      try { localStorage.setItem(`lastChannel_${serverId}`, this.channelIdValue) } catch(e) {}
    }

    this.setupDragAndDrop()
    this.setupPaste()
    this.setupFileIntercept()

    // Listen for pin toggle from persistent header (outside this controller's scope)
    this._onTogglePinned = (e) => {
      const url = e.detail?.url
      if (url) this._togglePinnedFromHeader(url)
    }
    document.addEventListener("toggle-pinned-panel", this._onTogglePinned)

    // Listen for context menu reply/react events
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
      const { messageId, content, preview, attachments } = e.detail
      this._editMessageId = messageId
      this._editOriginalContent = this.inputTarget.value
      this._editRemoveFileIds = []
      this._editAttachments = attachments || []
      this.inputTarget.value = content
      if (this.hasEditPreviewTarget) this.editPreviewTarget.textContent = preview
      if (this.hasEditBarTarget) this.editBarTarget.classList.remove("hidden")
      this._renderEditAttachments()
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

    // Show pin badge only if there are unseen pins (badge is in persistent header)
    const pinBadge = document.getElementById("ph-pin-badge")
    if (pinBadge) {
      const currentCount = parseInt(pinBadge.textContent) || 0
      const seen = parseInt(localStorage.getItem(`seenPins_${this.channelIdValue}`)) || 0
      if (currentCount > 0 && currentCount > seen) pinBadge.classList.remove("hidden")
    }

    // Timeout awareness
    this._timeoutHandler = (e) => {
      const currentUserId = document.body.dataset.currentUserId
      if (String(e.detail.user_id) === String(currentUserId)) {
        this.timedOutUntilValue = e.detail.timed_out_until || ""
      }
    }
    document.addEventListener("inferno:member-timeout", this._timeoutHandler)
    this._checkTimeout()
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
    if (this._timeoutHandler) document.removeEventListener("inferno:member-timeout", this._timeoutHandler)
    if (this._onTogglePinned) document.removeEventListener("toggle-pinned-panel", this._onTogglePinned)
    if (this._timeoutTimer) clearTimeout(this._timeoutTimer)
    if (this.typingUsers) {
      this.typingUsers.forEach(u => clearTimeout(u.timeout))
      this.typingUsers.clear()
    }
  }

  // --- Auto-focus: redirect typing to message input ---

  _handleAutoFocus(e) {
    // Skip if already focused on an input, textarea, or contenteditable
    const active = document.activeElement
    if (active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA" || active.isContentEditable)) return

    // Skip modifier combos (Ctrl+C, Cmd+V, etc.) except Shift
    if (e.ctrlKey || e.metaKey || e.altKey) return

    // Skip non-printable keys
    if (e.key.length !== 1 && e.key !== "Enter") return

    // Skip if a modal/overlay is open
    if (document.querySelector(".context-pop, [data-modal]")) return

    this.inputTarget.focus()
  }

  // --- Timeout awareness ---

  timedOutUntilValueChanged() {
    this._checkTimeout()
  }

  _checkTimeout() {
    if (this._timeoutTimer) clearTimeout(this._timeoutTimer)

    const until = this.timedOutUntilValue
    if (!until) {
      this._clearTimeoutUI()
      return
    }

    const untilDate = new Date(until)
    const remaining = untilDate - Date.now()

    if (remaining <= 0) {
      this._clearTimeoutUI()
      return
    }

    // Disable input and show banner
    this.inputTarget.disabled = true
    this.inputTarget.placeholder = "You are timed out"
    this._showTimeoutBanner(untilDate)

    // Auto-re-enable when timeout expires
    this._timeoutTimer = setTimeout(() => {
      this._clearTimeoutUI()
    }, remaining)
  }

  _showTimeoutBanner(untilDate) {
    // Remove existing banner
    this.element.querySelector(".timeout-banner")?.remove()

    const banner = document.createElement("div")
    banner.className = "timeout-banner bg-warning-dark/20 border border-warning-dark/30 rounded-lg px-4 py-2 mb-2 flex items-center gap-2"
    banner.innerHTML = `
      <svg class="w-4 h-4 text-warning-light shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
      <span class="text-sm text-warning-light">You are timed out until ${untilDate.toLocaleString()}</span>
    `
    // Insert before the form area
    const formArea = this.element.querySelector("form")?.parentElement
    if (formArea) formArea.insertBefore(banner, formArea.firstChild)
  }

  _clearTimeoutUI() {
    this.inputTarget.disabled = false
    if (this.inputTarget.dataset.originalPlaceholder) {
      this.inputTarget.placeholder = this.inputTarget.dataset.originalPlaceholder
    }
    this.element.querySelector(".timeout-banner")?.remove()
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

    // Edit mode: empty content + all attachments removed → delete the message
    if (this._editMessageId) {
      const remainingAttachments = (this._editAttachments || []).length
      if (!content && !remainingAttachments) {
        this._deleteEditedMessage()
        return
      }
    } else if (!content && !hasFiles) {
      return
    }

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
      const channelId = this.channelIdValue
      const url = `/channels/${channelId}/messages/${this._editMessageId}`
      const token = document.querySelector("meta[name=csrf-token]")?.content
      try {
        const response = await fetch(url, {
          method: "PATCH",
          headers: { "X-CSRF-Token": token, "Content-Type": "application/json", "Accept": "text/html" },
          body: JSON.stringify({ message: { content: msgContent, remove_file_ids: this._editRemoveFileIds || [] } })
        })
        if (response.ok) {
          this._editOriginalContent = null
          this._editMessageId = null
          this._editRemoveFileIds = []
          this._editAttachments = []
          this.inputTarget.value = ""
          this.updateHighlight()
          this.inputTarget.style.height = "auto"
          this.inputTarget.style.fontFamily = ""
          this.inputTarget.style.fontSize = ""
          if (this.inputTarget.parentElement) this.inputTarget.parentElement.style.backgroundColor = ""
          if (this.hasEditBarTarget) this.editBarTarget.classList.add("hidden")
          this.filePreviewTarget.innerHTML = ""
          this.filePreviewTarget.classList.add("hidden")
        }
      } catch(e) {
        console.error("Message edit failed:", e)
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
        this._resetSpoiler()
      } else if (response.status === 403) {
        const data = await response.json().catch(() => ({}))
        if (data.error === "timed_out" && data.until) {
          this.timedOutUntilValue = data.until
        }
      }
    } catch(e) {
      console.error("Message send failed:", e)
    } finally {
      this._submitting = false
    }
  }

  // --- Spoiler Toggle ---

  toggleSpoiler() {
    if (!this.hasSpoilerFieldTarget) return
    const active = this.spoilerFieldTarget.value === "1"
    this.spoilerFieldTarget.value = active ? "0" : "1"
    this.spoilerBtnTarget.classList.toggle("text-accent-light", !active)
    this.spoilerBtnTarget.classList.toggle("text-gray-400", active)
    if (this.hasSpoilerBarTarget) {
      this.spoilerBarTarget.classList.toggle("hidden", active)
    }
  }

  _resetSpoiler() {
    if (!this.hasSpoilerFieldTarget) return
    this.spoilerFieldTarget.value = "0"
    this.spoilerBtnTarget.classList.remove("text-accent-light")
    this.spoilerBtnTarget.classList.add("text-gray-400")
    if (this.hasSpoilerBarTarget) this.spoilerBarTarget.classList.add("hidden")
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
      btn.dataset.action = "click->message-form#removeFile"
      wrapper.appendChild(btn)

      container.appendChild(wrapper)
    })
  }

  _renderEditAttachments() {
    const container = this.filePreviewTarget
    container.innerHTML = ""
    if (!this._editAttachments || this._editAttachments.length === 0) {
      container.classList.add("hidden")
      return
    }
    container.classList.remove("hidden")
    this._editAttachments.forEach((att, i) => {
      const wrapper = document.createElement("div")
      wrapper.className = "relative inline-flex items-center bg-gray-700 rounded-lg p-2 mr-2 mb-2"

      if (att.type === "image" && att.url) {
        const img = document.createElement("img")
        img.className = "w-16 h-16 object-cover rounded"
        img.src = att.url
        wrapper.appendChild(img)
      } else {
        const icon = att.type === "video" ? "\u{1F3AC}" : att.type === "audio" ? "\u{1F3B5}" : "\u{1F4CE}"
        const name = document.createElement("span")
        name.className = "text-xs text-gray-200 max-w-[100px] truncate"
        name.textContent = `${icon} ${att.name}`
        wrapper.appendChild(name)
      }

      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "absolute -top-1.5 -right-1.5 w-5 h-5 bg-danger hover:bg-danger-light rounded-full flex items-center justify-center text-white text-xs cursor-pointer"
      btn.innerHTML = "&times;"
      btn.addEventListener("click", () => this._removeEditAttachment(i))
      wrapper.appendChild(btn)

      container.appendChild(wrapper)
    })
  }

  _removeEditAttachment(index) {
    const removed = this._editAttachments.splice(index, 1)[0]
    if (removed) this._editRemoveFileIds.push(removed.id)
    this._renderEditAttachments()
  }

  async _deleteEditedMessage() {
    const channelId = this.channelIdValue
    const messageId = this._editMessageId
    const token = document.querySelector("meta[name=csrf-token]")?.content
    try {
      await fetch(`/channels/${channelId}/messages/${messageId}`, {
        method: "DELETE",
        headers: { "X-CSRF-Token": token }
      })
    } catch (e) {
      console.error("Delete edited message failed:", e)
    }
    this.clearEdit()
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
    this._editRemoveFileIds = []
    this._editAttachments = []
    if (this.hasEditBarTarget) this.editBarTarget.classList.add("hidden")
    this.inputTarget.value = this._editOriginalContent || ""
    this._editOriginalContent = null
    this.filePreviewTarget.innerHTML = ""
    this.filePreviewTarget.classList.add("hidden")
    this.autoResize()
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

    // Header
    const header = document.createElement("div")
    header.className = "flex items-center justify-between px-3 py-2 border-b border-gray-700 sticky top-0 bg-gray-900 z-10"
    header.innerHTML = `
      <span class="text-sm font-semibold text-white">Pinned Messages</span>
      <button type="button" class="text-gray-400 hover:text-white cursor-pointer">
        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>
      </button>
    `
    header.querySelector("button").addEventListener("click", (e) => { e.stopPropagation(); panel.remove() })
    panel.appendChild(header)

    // Content
    const content = document.createElement("div")
    content.innerHTML = html
    panel.appendChild(content)

    // Jump-to-message handling
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

    // Position relative to the button's parent
    btn.closest(".relative").appendChild(panel)

    // Hide the badge — user has seen the pins, persist in localStorage
    const phBadge = document.getElementById("ph-pin-badge")
    if (phBadge) {
      phBadge.classList.add("hidden")
      const count = parseInt(phBadge.textContent) || 0
      try { localStorage.setItem(`seenPins_${this.channelIdValue}`, count) } catch {}
    }

    // Dismiss on outside click
    const dismiss = (e) => {
      if (!panel.contains(e.target) && !btn.contains(e.target)) {
        panel.remove()
        document.removeEventListener("click", dismiss)
      }
    }
    setTimeout(() => document.addEventListener("click", dismiss), 0)
  }

  async _togglePinnedFromHeader(url) {
    // Reuse togglePinnedPanel logic but with the persistent header pin button
    const existing = this.element.querySelector(".pinned-panel") || document.querySelector("#ph-pin-wrap .pinned-panel")
    if (existing) { existing.remove(); return }
    const btn = document.getElementById("ph-pin-btn")
    if (!btn || !url) return
    // Synthesize a fake event for togglePinnedPanel
    const fakeEvent = { currentTarget: btn }
    btn.dataset.pinnedUrl = url
    this.togglePinnedPanel(fakeEvent)
  }

  async _refreshPinnedPanel() {
    const panel = this.element.querySelector(".pinned-panel")
    if (!panel) return
    const btn = this.element.querySelector("[data-pinned-url]")
    if (!btn) return
    const resp = await fetch(btn.dataset.pinnedUrl, { headers: { "Accept": "text/html" } })
    if (!resp.ok) return
    const html = await resp.text()
    // Replace content (everything after the sticky header)
    const contentDiv = panel.querySelector(":scope > div:last-child")
    if (contentDiv) contentDiv.innerHTML = html
  }

  // --- Typing indicator ---

  sendTyping() {
    if (!this.inputTarget.value.trim()) return
    const now = Date.now()
    if (now - this._lastTypingSent < 2000) return
    this._lastTypingSent = now
    this.subscription.perform("typing")
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

  _renderTypingIndicator() {
    const el = this.element.querySelector("#typing-indicator, #sidechat-typing-indicator")
    if (!el) return
    const users = Array.from(this.typingUsers.values()).map(v => v.username)
    if (users.length === 0) {
      el.innerHTML = ""
      return
    }
    this._ensureTypingStyles()
    const dots = '<span class="typing-dots"><span>.</span><span>.</span><span>.</span></span>'
    let text
    if (users.length === 1) {
      text = `<strong>${users[0]}</strong> is typing${dots}`
    } else if (users.length === 2) {
      text = `<strong>${users[0]}</strong> and <strong>${users[1]}</strong> are typing${dots}`
    } else if (users.length === 3) {
      text = `<strong>${users[0]}</strong>, <strong>${users[1]}</strong>, and <strong>${users[2]}</strong> are typing${dots}`
    } else {
      text = `Several people are typing${dots}`
    }
    el.innerHTML = text
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
      // If inside an unclosed code block (odd number of ```), insert newline instead of sending
      const backtickCount = (content.match(/`{3}/g) || []).length
      if (backtickCount % 2 === 1) {
        // Unclosed code block - let the newline through
        return
      }
      event.preventDefault()
      this.submitMessage()
    }
  }

  handleSubmit(event) {
    // Legacy handler for turbo:submit-end — no longer used since we submit via fetch directly
    // Kept for backwards compatibility if the form is submitted via other means
    this._submitting = false
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
    const messagesDiv = this.hasMessagesContainerTarget
      ? this.messagesContainerTarget
      : document.getElementById("messages")
    if (!messagesDiv) return

    switch (data.type) {
      case "new_message": {
        const welcome = messagesDiv.querySelector(".text-center")
        if (welcome) welcome.remove()

        // Check if the scroll controller has trimmed the bottom (user is scrolled up in history)
        const scrollCtrl = this.application.getControllerForElementAndIdentifier(messagesDiv, "scroll-position")
        if (scrollCtrl && scrollCtrl.hasNewerValue) {
          // Bottom is trimmed — don't append, just show the new message bar
          scrollCtrl.showNewMessageBar()
        } else {
          messagesDiv.insertAdjacentHTML("beforeend", data.html)
          // Animate new message in
          const newEl = messagesDiv.lastElementChild
          if (newEl) {
            newEl.classList.add("message-appear")
            newEl.addEventListener("animationend", () => newEl.classList.remove("message-appear"), { once: true })
          }
          // Apply grouping to the newly inserted message
          const allMsgs = messagesDiv.querySelectorAll("[data-message-id]")
          if (allMsgs.length > 0) {
            this.applyGrouping(allMsgs[allMsgs.length - 1])
          }
          // Update newestMessageId on the scroll controller
          if (scrollCtrl) {
            const allMsgIds = messagesDiv.querySelectorAll("[id^='message_']")
            if (allMsgIds.length > 0) {
              scrollCtrl.newestMessageIdValue = allMsgIds[allMsgIds.length - 1].id.replace("message_", "")
            }
          }
        }
        break
      }
      case "update_message":
        const existing = document.getElementById(`message_${data.message_id}`)
        if (existing) existing.outerHTML = data.html
        break
      case "update_message_content":
        const target = document.getElementById(`message_${data.message_id}`)
        if (target) {
          const contentDiv = target.querySelector(".message-content")
          if (contentDiv) contentDiv.innerHTML = data.html
        }
        break
      case "delete_message":
        const toDelete = document.getElementById(`message_${data.message_id}`)
        if (toDelete) toDelete.remove()
        break
      case "update_reactions":
        const msgEl = document.getElementById(`message_${data.message_id}`)
        if (msgEl) {
          const reactionsContainer = msgEl.querySelector(".reactions-container")
          if (reactionsContainer) reactionsContainer.outerHTML = data.html
        }
        break
      case "pin_update":
        {
          const pinBadge = document.getElementById("ph-pin-badge")
          if (pinBadge) {
            const count = data.pin_count || 0
            const seen = parseInt(localStorage.getItem(`seenPins_${this.channelIdValue}`)) || 0
            const hasNew = count > seen
            pinBadge.textContent = count
            pinBadge.classList.toggle("hidden", !hasNew)
          }
        }
        this._refreshPinnedPanel()
        break
      case "backfill_complete": {
        // Backfill imported messages server-side — fetch them via HTTP
        const scrollCtrl = this.application.getControllerForElementAndIdentifier(messagesDiv, "scroll-position")
        if (scrollCtrl && scrollCtrl.newestMessageIdValue) {
          scrollCtrl.hasNewerValue = true
          scrollCtrl.loadNewerMessages()
        }
        break
      }
      case "typing": {
        const selfId = document.body.dataset.currentUserId
        if (String(data.user_id) === String(selfId)) break
        const existing = this.typingUsers.get(data.user_id)
        if (existing) clearTimeout(existing.timeout)
        const timeout = setTimeout(() => {
          this.typingUsers.delete(data.user_id)
          this._renderTypingIndicator()
        }, 3000)
        this.typingUsers.set(data.user_id, { username: data.username, timeout })
        this._renderTypingIndicator()
        break
      }
    }
  }

  // --- Message grouping ---

  applyGrouping(messageEl) {
    const prev = messageEl.previousElementSibling
    if (!prev || !prev.dataset.messageId) return

    const sameAuthor = messageEl.dataset.authorId === prev.dataset.authorId
    const isSystem = messageEl.dataset.systemMessage === "true"
    const prevIsSystem = prev.dataset.systemMessage === "true"
    const isReply = messageEl.dataset.isReply === "true"
    const prevIsReply = prev.dataset.isReply === "true"

    if (!sameAuthor || isSystem || prevIsSystem || isReply || prevIsReply) return

    const ts = new Date(messageEl.dataset.timestamp)
    const prevTs = new Date(prev.dataset.timestamp)
    if ((ts - prevTs) >= 300000) return // 5 minutes

    // Apply grouped styling
    messageEl.classList.add("message-grouped")

    // Replace avatar with hover timestamp spacer
    const avatarDiv = messageEl.querySelector(":scope > .shrink-0")
    if (avatarDiv) {
      const time = ts.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
      avatarDiv.innerHTML = `<span class="text-[10px] text-gray-500 opacity-0 group-hover:opacity-100">${time}</span>`
      avatarDiv.className = "shrink-0 mt-0.5 mr-4 w-10 flex items-center justify-center"
    }

    // Hide the username/timestamp header line
    const contentDiv = messageEl.querySelector(":scope > .flex-1")
    if (contentDiv) {
      const header = contentDiv.querySelector(":scope > .flex.items-baseline")
      if (header) header.style.display = "none"
    }
  }

  // --- Reactions ---

  toggleReaction(event) {
    const btn = event.currentTarget
    const messageId = btn.dataset.messageId
    const emoji = btn.dataset.emoji
    const token = document.querySelector("meta[name=csrf-token]")?.content
    const formData = new FormData()
    formData.append("emoji", emoji)
    fetch(`/channels/${this.channelIdValue}/messages/${messageId}/toggle_reaction`, {
      method: "POST",
      headers: { "X-CSRF-Token": token },
      body: formData
    })
  }

  openReactionPickerForMessage(messageId, clientX, clientY) {
    document.getElementById("reaction-picker-panel")?.remove()
    document.dispatchEvent(new CustomEvent("inferno:open-reaction-picker", {
      detail: {
        messageId,
        reactionUrl: `/channels/${this.channelIdValue}/messages/${messageId}/toggle_reaction`,
        anchorSelector: `#message_${messageId}`,
        clientX,
        clientY
      }
    }))
  }

  openReactionPicker(event) {
    const messageId = event.currentTarget.dataset.messageId
    this.openReactionPickerForMessage(messageId)
  }

  updateHighlight() {
    if (!this.hasHighlightTarget) return
    const text = this.inputTarget.value
    // Escape HTML
    let html = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    // Highlight URLs
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
    html = html.replace(/`([^`]+)`/g, '<span class="text-accent bg-gray-700/50 rounded">`$1`</span>')
    // Highlight @mentions (no padding — must match textarea character widths for cursor alignment)
    html = html.replace(/(^|[\s])(@\w+)/g, '$1<span class="text-accent-light bg-accent-light/15 rounded">$2</span>')
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
    // Add trailing newline for height sync
    if (html.endsWith("\n")) html += "&nbsp;"
    this.highlightTarget.innerHTML = html
    // Sync scroll
    this.highlightTarget.scrollTop = this.inputTarget.scrollTop
  }

  // Syntax-aware code block highlighting
  _highlightCodeBlock(block) {
    // Parse language tag from opening ```
    const langMatch = block.match(/^```(\w*)/)
    const lang = langMatch ? langMatch[1].toLowerCase() : ""
    // Split into opening fence, body, and optional closing fence
    const firstNewline = block.indexOf("\n")
    if (firstNewline === -1) {
      // Single line like ```js — just show the fence
      return `<span style="color:#7c8899">${block}</span>`
    }
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
    // Tokenize into strings, comments, and code — process only code portions
    const tokens = []
    let i = 0
    while (i < code.length) {
      // Line comments
      if (code[i] === "/" && code[i + 1] === "/") {
        const end = code.indexOf("\n", i)
        const slice = end === -1 ? code.substring(i) : code.substring(i, end)
        tokens.push({ type: "comment", text: slice })
        i += slice.length
        continue
      }
      // Hash comments (ruby, python, shell)
      if (code[i] === "#" && (lang === "ruby" || lang === "rb" || lang === "python" || lang === "py" || lang === "sh" || lang === "bash" || lang === "shell" || lang === "yml" || lang === "yaml")) {
        const end = code.indexOf("\n", i)
        const slice = end === -1 ? code.substring(i) : code.substring(i, end)
        tokens.push({ type: "comment", text: slice })
        i += slice.length
        continue
      }
      // Block comments
      if (code[i] === "/" && code[i + 1] === "*") {
        const end = code.indexOf("*/", i + 2)
        const slice = end === -1 ? code.substring(i) : code.substring(i, end + 2)
        tokens.push({ type: "comment", text: slice })
        i += slice.length
        continue
      }
      // Strings (double and single quotes)
      if (code[i] === '"' || code[i] === "'") {
        const quote = code[i]
        let j = i + 1
        while (j < code.length && code[j] !== quote && code[j] !== "\n") {
          if (code[j] === "\\") j++
          j++
        }
        if (j < code.length && code[j] === quote) j++
        tokens.push({ type: "string", text: code.substring(i, j) })
        i = j
        continue
      }
      // Template literals
      if (code[i] === "`" && (lang === "js" || lang === "javascript" || lang === "ts" || lang === "typescript" || lang === "jsx" || lang === "tsx")) {
        let j = i + 1
        while (j < code.length && code[j] !== "`") {
          if (code[j] === "\\") j++
          j++
        }
        if (j < code.length) j++
        tokens.push({ type: "string", text: code.substring(i, j) })
        i = j
        continue
      }
      // Code text
      let j = i
      while (j < code.length) {
        if (code[j] === "/" && (code[j + 1] === "/" || code[j + 1] === "*")) break
        if (code[j] === "#" && (lang === "ruby" || lang === "rb" || lang === "python" || lang === "py" || lang === "sh" || lang === "bash" || lang === "shell" || lang === "yml" || lang === "yaml")) break
        if (code[j] === '"' || code[j] === "'") break
        if (code[j] === "`" && (lang === "js" || lang === "javascript" || lang === "ts" || lang === "typescript" || lang === "jsx" || lang === "tsx")) break
        j++
      }
      if (j > i) {
        tokens.push({ type: "code", text: code.substring(i, j) })
        i = j
      } else {
        tokens.push({ type: "code", text: code[i] })
        i++
      }
    }

    const keywords = this._keywordsFor(lang)
    return tokens.map(t => {
      if (t.type === "comment") return `<span style="color:#6a737d;font-style:italic">${t.text}</span>`
      if (t.type === "string") return `<span style="color:#98c379">${t.text}</span>`
      if (t.type === "code") {
        let text = t.text
        // Numbers
        text = text.replace(/\b(\d+\.?\d*)\b/g, '<span style="color:#d19a66">$1</span>')
        // Keywords
        if (keywords) {
          text = text.replace(new RegExp(`\\b(${keywords})\\b`, "g"), '<span style="color:#c678dd">$1</span>')
        }
        // Constants (true/false/null/nil/undefined/NaN)
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
      case "html": case "erb": case "xml": return null // HTML needs different parsing
      case "json": return null // just strings/numbers
      case "sh": case "bash": case "shell": case "zsh":
        return "if|then|else|elif|fi|for|while|do|done|case|esac|function|return|exit|echo|export|source|local|readonly|unset|shift|eval|exec|trap|cd|pwd|test"
      default: return JS // default to JS-like keywords
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
      // Snap out if between em-space and PUA
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
      // Snap out if between em-space and PUA
      if (pos > 0 && val[pos - 1] === '\u2003' && pos < val.length && window._emojiReverse[val[pos]]) {
        event.preventDefault()
        input.selectionStart = input.selectionEnd = pos + 1
        return true
      }
    }
    return false
  }
}
