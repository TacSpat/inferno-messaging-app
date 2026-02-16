import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

export default class extends Controller {
  static targets = ["highlight", "input", "filePreview", "dropzone", "replyBar", "replyAuthor", "replyPreview", "parentId"]
  static values = { conversationId: String }

  connect() {
    this.consumer = createConsumer()
    this.subscription = this.consumer.subscriptions.create(
      { channel: "ConversationChannel", conversation_id: this.conversationIdValue },
      {
        received: (data) => this.handleReceived(data),
        typing() {
          this.perform("typing")
        }
      }
    )
    this.fileList = new DataTransfer()
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
    document.addEventListener("inferno:reply", this._replyHandler)

    // Measure emoji placeholder width for pixel-perfect overlay
    this._measureEmojiWidth()

    // Render any existing emoji content (e.g. after page refresh)
    this._replaceEmojisWithPUA()
    this.updateHighlight()

    // Re-render when emoji maps load asynchronously
    this._emojiMapReady = () => {
      this._replaceEmojisWithPUA()
      this.updateHighlight()
    }
    document.addEventListener("inferno:emoji-map-ready", this._emojiMapReady)
  }

  disconnect() {
    this.subscription?.unsubscribe()
    this.consumer?.disconnect()
    this.teardownDragAndDrop()
    this.teardownPaste()
    this.teardownFileIntercept()
    if (this._emojiMapReady) document.removeEventListener("inferno:emoji-map-ready", this._emojiMapReady)
    if (this._replyHandler) document.removeEventListener("inferno:reply", this._replyHandler)
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

  // --- Intercept form submission to inject DataTransfer files ---

  setupFileIntercept() {
    const form = this.element.querySelector("form")
    if (!form) return
    this._fileInterceptHandler = (event) => {
      const body = event.detail.fetchOptions.body
      if (body instanceof FormData) {
        // Convert emoji placeholders (em-space + PUA) back to :name: before sending
        const content = body.get("message[content]")
        if (content && window._emojiReverse) {
          body.set("message[content]", content.replace(/\u2003([\uE000-\uF8FF])/g, (m, ch, offset, str) => {
            const name = window._emojiReverse[ch]
            if (!name) return m
            const next = str[offset + m.length]
            return `:${name}:` + (next === '\u2003' ? ' ' : '')
          }))
        }
        // Inject DataTransfer files
        if (this.fileList.files.length > 0) {
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

  // --- Input handling ---

  handleKeydown(event) {
    if (this._handleEmojiKeydown(event)) return
    if (event.key === "Enter" && !event.shiftKey) {
      const content = this.inputTarget.value
      const backtickCount = (content.match(/`{3}/g) || []).length
      if (backtickCount % 2 === 1) return
      event.preventDefault()
      const trimmed = content.trim()
      const fileInput = this.element.querySelector("input[type=file]")
      const hasFiles = fileInput && fileInput.files.length > 0
      if (!trimmed && !hasFiles) return
      const form = event.target.closest("form")
      if (form) form.requestSubmit()
    }
  }

  handleSubmit(event) {
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
    this._replaceEmojisWithPUA()
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
      case "new_message":
        const welcome = messagesDiv.querySelector(".text-center")
        if (welcome) welcome.remove()
        const nearBottom = (messagesDiv.scrollHeight - messagesDiv.scrollTop - messagesDiv.clientHeight) < 150
        messagesDiv.insertAdjacentHTML("beforeend", data.html)
        if (nearBottom) messagesDiv.scrollTop = messagesDiv.scrollHeight
        break
      case "update_message":
        const existing = document.getElementById(`message_${data.message_id}`)
        if (existing) existing.outerHTML = data.html
        break
      case "delete_message":
        const toDelete = document.getElementById(`message_${data.message_id}`)
        if (toDelete) toDelete.remove()
        break
      case "typing":
        this.showTypingIndicator(data.username, data.user_id)
        break
    }
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
    html = html.replace(/(https?:\/\/[^\s<>]+)/gi, '<span class="text-blue-400">$1</span>')
    html = html.replace(/\*\*(.+?)\*\*/g, '<span class="text-white font-bold">**$1**</span>')
    html = html.replace(/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/g, '<span class="text-white italic">*$1*</span>')
    html = html.replace(/~~(.+?)~~/g, '<span class="text-gray-400 line-through">~~$1~~</span>')
    html = html.replace(/`([^`]+)`/g, '<span class="text-orange-300 bg-gray-700/50 rounded px-0.5">`$1`</span>')
    html = html.replace(/(```[\s\S]*?```)/g, '<span class="text-orange-300">$1</span>')
    // Replace emoji placeholders (em-space + PUA char) with inline images
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
    if (html.endsWith("\n")) html += "&nbsp;"
    this.highlightTarget.innerHTML = html
    this.highlightTarget.scrollTop = this.inputTarget.scrollTop
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
