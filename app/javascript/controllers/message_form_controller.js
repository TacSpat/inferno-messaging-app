import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

export default class extends Controller {
  static targets = ["highlight", "input", "filePreview", "dropzone", "replyBar", "replyAuthor", "replyPreview", "parentId"]
  static values = { channelId: String }

  connect() {
    this.consumer = createConsumer()
    this.subscription = this.consumer.subscriptions.create(
      { channel: "ChannelChatChannel", channel_id: this.channelIdValue },
      {
        received: (data) => this.handleReceived(data)
      }
    )
    this.fileList = new DataTransfer()
    this.typingUsers = new Map()
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
      const { messageId } = e.detail
      this.openReactionPickerForMessage(messageId)
    }
    document.addEventListener("inferno:reply", this._replyHandler)
    document.addEventListener("inferno:react", this._reactHandler)
  }

  disconnect() {
    this.subscription?.unsubscribe()
    this.consumer?.disconnect()
    this.teardownDragAndDrop()
    this.teardownPaste()
    this.teardownFileIntercept()
    if (this._replyHandler) document.removeEventListener("inferno:reply", this._replyHandler)
    if (this._reactHandler) document.removeEventListener("inferno:react", this._reactHandler)
    if (this.typingUsers) {
      this.typingUsers.forEach(u => clearTimeout(u.timeout))
      this.typingUsers.clear()
    }
  }

  // --- Paste ---

  setupPaste() {
    this._pasteHandler = (e) => {
      const items = e.clipboardData?.items
      if (!items) return
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

  // --- Intercept form submission to inject DataTransfer files ---

  setupFileIntercept() {
    const form = this.element.querySelector("form")
    if (!form) return
    this._fileInterceptHandler = (event) => {
      if (this.fileList.files.length > 0) {
        const body = event.detail.fetchOptions.body
        if (body instanceof FormData) {
          body.delete("message[files][]")
          for (const file of this.fileList.files) {
            body.append("message[files][]", file)
          }
        }
      }
    }
    form.addEventListener("turbo:before-fetch-request", this._fileInterceptHandler)
  }

  teardownFileIntercept() {
    const form = this.element.querySelector("form")
    if (form && this._fileInterceptHandler) {
      form.removeEventListener("turbo:before-fetch-request", this._fileInterceptHandler)
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
    this.syncFileInput()
  }

  addFiles(files) {
    for (const file of files) {
      this.fileList.items.add(file)
    }
    this.syncFileInput()
    this.renderPreviews()
  }

  removeFile(event) {
    const index = parseInt(event.currentTarget.dataset.index)
    this.fileList.items.remove(index)
    this.syncFileInput()
    this.renderPreviews()
  }

  syncFileInput() {
    const input = this.element.querySelector("input[type=file]")
    if (input) input.files = this.fileList.files
  }

  renderPreviews() {
    const container = this.filePreviewTarget
    container.innerHTML = ""
    if (this.fileList.files.length === 0) {
      container.classList.add("hidden")
      return
    }
    container.classList.remove("hidden")
    Array.from(this.fileList.files).forEach((file, i) => {
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
      btn.className = "absolute -top-1.5 -right-1.5 w-5 h-5 bg-red-600 hover:bg-red-500 rounded-full flex items-center justify-center text-white text-xs cursor-pointer"
      btn.innerHTML = "&times;"
      btn.dataset.index = i
      btn.dataset.action = "click->message-form#removeFile"
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
    const el = document.getElementById("typing-indicator")
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
    if (event.key === "Enter" && !event.shiftKey) {
      const content = this.inputTarget.value
      // If inside an unclosed code block (odd number of ```), insert newline instead of sending
      const backtickCount = (content.match(/`{3}/g) || []).length
      if (backtickCount % 2 === 1) {
        // Unclosed code block - let the newline through
        return
      }
      event.preventDefault()
      if (this._submitting) return
      const trimmed = content.trim()
      const fileInput = this.element.querySelector("input[type=file]")
      const hasFiles = fileInput && fileInput.files.length > 0
      if (!trimmed && !hasFiles) return
      this._submitting = true
      const form = event.target.closest("form")
      if (form) form.requestSubmit()
    }
  }

  handleSubmit(event) {
    this._submitting = false
    if (event.detail.success) {
      this.inputTarget.value = ""
      this.updateHighlight()
      this.inputTarget.style.height = "auto"
      this.inputTarget.style.fontFamily = ""
      this.inputTarget.style.fontSize = ""
      if (this.inputTarget.parentElement) this.inputTarget.parentElement.style.backgroundColor = ""
      this.fileList = new DataTransfer()
      this.syncFileInput()
      this.renderPreviews()
      this.clearReply()
    }
  }

  autoResize() {
    this.updateHighlight()
    const input = this.inputTarget
    input.style.height = "auto"
    input.style.height = Math.min(input.scrollHeight, 192) + "px"
    this.updateCodeBlockStyle()
  }

  updateCodeBlockStyle() {
    const input = this.inputTarget
    const val = input.value
    const tripleCount = (val.match(/`{3}/g) || []).length
    const inCodeBlock = tripleCount % 2 === 1
    if (inCodeBlock) {
      input.style.fontFamily = "Consolas, Monaco, 'Courier New', monospace"
      input.style.fontSize = "0.8rem"
      if (input.parentElement) input.parentElement.style.backgroundColor = "rgb(30 31 34)"
    } else {
      input.style.fontFamily = ""
      input.style.fontSize = ""
      if (input.parentElement) input.parentElement.style.backgroundColor = ""
    }
  }

  // --- ActionCable ---

  handleReceived(data) {
    const messagesDiv = document.getElementById("messages")
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

  openReactionPickerForMessage(messageId) {
    const existing = document.getElementById("reaction-picker-popup")
    if (existing) existing.remove()
    const common = ["😀","😂","❤️","👍","👎","😮","😢","😡","😍","🤔","🙏","🙌","🔥","🎉","✨","💯","💀","🤣","😎","🙄"]
    const popup = document.createElement("div")
    popup.id = "reaction-picker-popup"
    popup.className = "fixed z-50 bg-gray-800 border border-gray-700 rounded-lg shadow-xl p-2 flex flex-wrap gap-0.5 w-64"
    // Position near the message
    const msgEl = document.getElementById(`message_${messageId}`)
    if (msgEl) {
      const rect = msgEl.getBoundingClientRect()
      // Place above the message, or below if not enough room
      const popupHeight = 120
      if (rect.top > popupHeight + 10) {
        popup.style.top = (rect.top - popupHeight - 4) + "px"
      } else {
        popup.style.top = (rect.bottom + 4) + "px"
      }
      popup.style.right = "80px"
    } else {
      popup.style.top = "50%"
      popup.style.left = "50%"
      popup.style.transform = "translate(-50%, -50%)"
    }
    const channelId = this.channelIdValue
    common.forEach(emoji => {
      const b = document.createElement("button")
      b.type = "button"
      b.className = "w-8 h-8 flex items-center justify-center text-xl hover:bg-gray-700 rounded cursor-pointer"
      b.textContent = emoji
      b.onclick = () => {
        popup.remove()
        const token = document.querySelector("meta[name=csrf-token]")?.content
        const fd = new FormData()
        fd.append("emoji", emoji)
        fetch(`/channels/${channelId}/messages/${messageId}/toggle_reaction`, {
          method: "POST",
          headers: { "X-CSRF-Token": token },
          body: fd
        })
      }
      popup.appendChild(b)
    })
    document.body.appendChild(popup)
    setTimeout(() => {
      const handler = (e) => {
        if (!popup.contains(e.target)) { popup.remove(); document.removeEventListener("click", handler) }
      }
      document.addEventListener("click", handler)
    }, 0)
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
    html = html.replace(/(https?:\/\/[^\s<>]+)/gi, '<span class="text-blue-400">$1</span>')
    // Highlight bold **text**
    html = html.replace(/\*\*(.+?)\*\*/g, '<span class="text-white font-bold">**$1**</span>')
    // Highlight italic *text*
    html = html.replace(/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/g, '<span class="text-white italic">*$1*</span>')
    // Highlight ~~strikethrough~~
    html = html.replace(/~~(.+?)~~/g, '<span class="text-gray-400 line-through">~~$1~~</span>')
    // Highlight `inline code`
    html = html.replace(/`([^`]+)`/g, '<span class="text-orange-300 bg-gray-700/50 rounded px-0.5">`$1`</span>')
    // Highlight code blocks
    html = html.replace(/(```[\s\S]*?```)/g, '<span class="text-orange-300">$1</span>')
    // Add trailing newline for height sync
    if (html.endsWith("\n")) html += "&nbsp;"
    this.highlightTarget.innerHTML = html
    // Sync scroll
    this.highlightTarget.scrollTop = this.inputTarget.scrollTop
  }
}
