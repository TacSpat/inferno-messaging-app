import { Controller } from "@hotwired/stimulus"

const DOM_CAP = 150
const TRIM_BATCH = 50

export default class extends Controller {
  static values = {
    channelId: String,
    serverId: String,
    oldestMessageId: String,
    hasOlder: Boolean,
    newestMessageId: String,
    hasNewer: Boolean
  }

  static targets = ["newMessageBar"]

  connect() {
    this.newMessageCount = 0
    this._initializing = true
    this._lastScrollTop = 0
    this._loadingOlder = false
    this._loadingNewer = false

    // Intercept clicks on internal message links
    this._onLinkClick = (e) => {
      const a = e.target.closest("a[href]")
      if (!a) return
      const href = a.getAttribute("href")
      if (!href) return
      // Match internal message links: /servers/:id/channels/:id#message-XX
      const match = href.match(/(?:https?:\/\/[^\/]+)?\/servers\/([a-zA-Z0-9]+)\/channels\/([a-zA-Z0-9]+)#message[-_]([a-zA-Z0-9]+)/)
      if (!match) return
      e.preventDefault()
      e.stopPropagation()
      const [, sId, cId, mId] = match
      const currentEl = document.querySelector("[data-current-channel-id]")
      const currentChannelId = currentEl ? currentEl.dataset.currentChannelId : null
      if (currentChannelId === cId) {
        // Same channel — just scroll
        const el = document.getElementById(`message_${mId}`)
        if (el) {
          el.scrollIntoView({ behavior: "smooth", block: "center" })
          this.highlightMessage(el, true)
        }
      } else {
        // Different channel — Turbo navigate, then scroll after load
        const url = `/servers/${sId}/channels/${cId}`
        // Store target message to scroll to after navigation
        sessionStorage.setItem("jump_to_message", mId)
        window.Turbo.visit(url)
      }
    }
    document.addEventListener("click", this._onLinkClick)

    // Check for pending message jump from cross-channel navigation
    const pendingJump = sessionStorage.getItem("jump_to_message")
    if (pendingJump) {
      sessionStorage.removeItem("jump_to_message")
      this.waitForMessage(pendingJump, (el) => {
        el.scrollIntoView({ behavior: "smooth", block: "center" })
        this.highlightMessage(el, true)
        setTimeout(() => { this._initializing = false }, 500)
      })
      return
    }
    // Check for #message-XX hash to jump to specific message
    const hash = window.location.hash
    const messageMatch = hash.match(/^#message[-_]([a-zA-Z0-9]+)$/)
    if (messageMatch) {
      history.replaceState(null, "", window.location.pathname + window.location.search)
      this.waitForMessage(messageMatch[1], (el) => {
        el.scrollIntoView({ behavior: "smooth", block: "center" })
        this.highlightMessage(el, true)
        setTimeout(() => { this._initializing = false }, 500)
      })
    } else {
      // Wait for messages to be in the DOM before restoring scroll
      this.waitForContent(() => {
        const savedAnchor = this.getSavedAnchor()
        if (savedAnchor) {
          // Check if anchor is already in the initial DOM
          const el = document.getElementById(`message_${savedAnchor}`)
          if (el) {
            el.scrollIntoView({ block: "center" })
            setTimeout(() => { this._initializing = false }, 200)
          } else {
            // Anchor is deep in history — fetch messages around it
            this.loadAroundMessage(savedAnchor)
            return
          }
        } else {
          const saved = this.getSavedPosition()
          if (saved !== null && saved > 0) {
            this.element.scrollTop = saved
            if (this.element.scrollTop < saved - 50) {
              this.scrollToBottom()
            }
          } else {
            this.scrollToBottom()
          }
          setTimeout(() => { this._initializing = false }, 200)
        }
      })
    }

    // Track scroll position continuously (so disconnect has a good value)
    this._onScroll = () => {
      this._lastScrollTop = this.element.scrollTop
      if (this.isNearBottom()) this.hideNewMessageBar()
      // Load older messages when near top
      if (this.isNearTop() && !this._initializing) {
        this.loadOlderMessages()
      }
      // Load newer messages when near bottom and bottom was trimmed
      if (this.isNearBottom() && this.hasNewerValue && !this._initializing) {
        this.loadNewerMessages()
      }
    }
    this.element.addEventListener("scroll", this._onScroll)

    // Save periodically (not on every scroll event)
    this._saveInterval = setInterval(() => {
      this.savePosition(this._lastScrollTop)
    }, 1000)

    // Bind click on the "Jump to Present" / "New message" bar button
    // (the bar is a sibling of #messages, outside this controller's element)
    const bar = this.element.parentElement?.querySelector("[data-scroll-position-target=newMessageBar]")
    if (bar) {
      const btn = bar.querySelector("button")
      if (btn) {
        this._jumpHandler = () => this.jumpToBottom()
        btn.addEventListener("click", this._jumpHandler)
        this._jumpBtn = btn
      }
    }

    this.observer = new MutationObserver((mutations) => {
      if (this._initializing || this._suppressObserver) return
      const hasNewMessages = mutations.some(m =>
        Array.from(m.addedNodes).some(n => n.nodeType === 1 && n.id?.startsWith("message_"))
      )
      if (!hasNewMessages) return

      if (this.isNearBottom()) {
        this.scrollToBottom()
      } else {
        this.showNewMessageBar()
      }
    })
    this.observer.observe(this.element, { childList: true })

    this.element.querySelectorAll("img").forEach(img => {
      if (!img.complete) {
        img.addEventListener("load", () => {
          if (!this._initializing && this.isNearBottom()) this.scrollToBottom()
        }, { once: true })
      }
    })
  }


  waitForContent(callback) {
    const tryRestore = () => {
      // Wait for images to load so scroll height is stable
      const images = Array.from(this.element.querySelectorAll("img")).filter(i => !i.complete)
      if (images.length > 0) {
        let loaded = 0
        let called = false
        const done = () => {
          if (called) return
          if (++loaded >= images.length) {
            called = true
            // Double rAF ensures layout is complete
            requestAnimationFrame(() => requestAnimationFrame(() => callback()))
          }
        }
        images.forEach(i => i.addEventListener("load", done, { once: true }))
        images.forEach(i => i.addEventListener("error", done, { once: true }))
        setTimeout(() => { if (!called) { called = true; callback() } }, 2000)
      } else {
        // Double rAF to ensure layout is settled
        requestAnimationFrame(() => requestAnimationFrame(() => callback()))
      }
    }

    // Check if messages are already in DOM
    if (this.element.querySelector("[id^='message_']")) {
      tryRestore()
      return
    }

    // Wait for messages to appear
    const obs = new MutationObserver((muts, observer) => {
      if (this.element.querySelector("[id^='message_']")) {
        observer.disconnect()
        // Small delay for remaining DOM to settle
        setTimeout(() => tryRestore(), 50)
      }
    })
    obs.observe(this.element, { childList: true, subtree: true })
    setTimeout(() => { obs.disconnect(); callback() }, 3000)
  }
  highlightMessage(el, afterScroll = false) {
    const doHighlight = () => {
      el.style.backgroundColor = "rgba(99, 102, 241, 0.3)"
      el.style.borderRadius = "4px"
      setTimeout(() => {
        el.style.transition = "background-color 0.8s ease-out"
        el.style.backgroundColor = "transparent"
        setTimeout(() => {
          el.style.backgroundColor = ""
          el.style.borderRadius = ""
          el.style.transition = ""
        }, 800)
      }, 1000)
    }
    if (afterScroll) {
      // Wait for smooth scroll to finish
      setTimeout(doHighlight, 600)
    } else {
      doHighlight()
    }
  }

  // Wait for an element to appear in the DOM, then call callback
  waitForMessage(messageId, callback, timeoutMs = 5000) {
    const tryScroll = (el) => {
      // Wait for any images in/near the message to load first
      const images = this.element.querySelectorAll("img:not([complete])")
      const pending = Array.from(images).filter(img => !img.complete)
      if (pending.length > 0) {
        let loaded = 0
        const check = () => { if (++loaded >= pending.length) setTimeout(() => callback(el), 50) }
        pending.forEach(img => img.addEventListener("load", check, { once: true }))
        setTimeout(() => callback(el), 1500) // fallback if images slow
      } else {
        setTimeout(() => callback(el), 100)
      }
    }
    const el = document.getElementById(`message_${messageId}`)
    if (el) { tryScroll(el); return }
    const obs = new MutationObserver((mutations, observer) => {
      const el = document.getElementById(`message_${messageId}`)
      if (el) {
        observer.disconnect()
        tryScroll(el)
      }
    })
    obs.observe(this.element, { childList: true, subtree: true })
    // Timeout fallback
    setTimeout(() => {
      obs.disconnect()
      const el = document.getElementById(`message_${messageId}`)
      if (el) tryScroll(el)
      else this.scrollToBottom()
    }, timeoutMs)
  }

  disconnect() {
    // Save scroll position — try live element first, fall back to cached
    try {
      const pos = this.element.scrollTop || this._lastScrollTop
      if (pos > 0) this.savePosition(pos)
    } catch {
      if (this._lastScrollTop > 0) this.savePosition(this._lastScrollTop)
    }
    document.removeEventListener("click", this._onLinkClick)
    if (this._jumpBtn && this._jumpHandler) {
      this._jumpBtn.removeEventListener("click", this._jumpHandler)
    }
    this.observer?.disconnect()
    try { this.element.removeEventListener("scroll", this._onScroll) } catch {}
    clearInterval(this._saveInterval)
  }

  scrollToBottom() {
    this.element.scrollTop = this.element.scrollHeight
    this._lastScrollTop = this.element.scrollTop
    this.hideNewMessageBar()
  }

  jumpToBottom() {
    this.clearSavedAnchor()
    if (this.hasNewerValue) {
      // Bottom was trimmed — reload the channel to get fresh latest messages
      const serverId = this.serverIdValue
      const channelId = this.channelIdValue
      window.Turbo.visit(`/servers/${serverId}/channels/${channelId}`)
    } else {
      this.scrollToBottom()
    }
  }

  isNearBottom() {
    const threshold = 150
    return (this.element.scrollHeight - this.element.scrollTop - this.element.clientHeight) < threshold
  }

  isNearTop() {
    return this.element.scrollTop < 200
  }

  // --- Anchor-based scroll preservation ---

  _findAnchorMessage() {
    const messages = this.element.querySelectorAll("[id^='message_']")
    const containerTop = this.element.getBoundingClientRect().top
    for (const msg of messages) {
      const rect = msg.getBoundingClientRect()
      // First message whose bottom is below the container top (visible or partially visible)
      if (rect.bottom > containerTop) {
        return { element: msg, offsetTop: rect.top }
      }
    }
    return null
  }

  _restoreAnchor(anchor) {
    if (!anchor || !anchor.element.isConnected) return
    const newTop = anchor.element.getBoundingClientRect().top
    const drift = newTop - anchor.offsetTop
    this.element.scrollTop += drift
  }

  // --- DOM trimming ---

  _getMessageElements() {
    return this.element.querySelectorAll("[id^='message_']")
  }

  trimBottom() {
    const messages = this._getMessageElements()
    if (messages.length <= DOM_CAP) return

    const anchor = this._findAnchorMessage()
    const toRemove = messages.length - DOM_CAP
    // Remove from the bottom (newest end)
    for (let i = messages.length - 1; i >= messages.length - toRemove; i--) {
      messages[i].remove()
    }

    // Update newestMessageId to the new last message
    const remaining = this._getMessageElements()
    if (remaining.length > 0) {
      this.newestMessageIdValue = remaining[remaining.length - 1].id.replace("message_", "")
    }
    this.hasNewerValue = true
    this._bottomTrimCount = (this._bottomTrimCount || 0) + 1
    if (this._bottomTrimCount >= 2) {
      this.showNewMessageBar("Jump to Present")
    }

    this._restoreAnchor(anchor)
  }

  trimTop() {
    const messages = this._getMessageElements()
    if (messages.length <= DOM_CAP) return

    const anchor = this._findAnchorMessage()
    const toRemove = messages.length - DOM_CAP
    // Remove from the top (oldest end)
    for (let i = 0; i < toRemove; i++) {
      messages[i].remove()
    }

    // Update oldestMessageId to the new first message
    const remaining = this._getMessageElements()
    if (remaining.length > 0) {
      this.oldestMessageIdValue = remaining[0].id.replace("message_", "")
    }
    this.hasOlderValue = true

    this._restoreAnchor(anchor)
  }

  // --- Loading messages ---

  async loadOlderMessages() {
    if (this._loadingOlder || !this.hasOlderValue || !this.oldestMessageIdValue) return
    this._loadingOlder = true

    const serverId = this.serverIdValue
    const channelId = this.channelIdValue
    const beforeId = this.oldestMessageIdValue
    const url = `/servers/${serverId}/channels/${channelId}/older_messages?before=${beforeId}`

    try {
      const response = await fetch(url, {
        headers: {
          "Accept": "text/html",
          "X-Requested-With": "XMLHttpRequest"
        }
      })
      if (!response.ok) return

      const html = await response.text()
      if (!html.trim()) {
        this.hasOlderValue = false
        return
      }

      this._suppressObserver = true

      const anchor = this._findAnchorMessage()

      // Parse and prepend messages
      const template = document.createElement("template")
      template.innerHTML = html

      const firstChild = this.element.firstChild

      // Insert all new messages at the top
      while (template.content.firstChild) {
        this.element.insertBefore(template.content.firstChild, firstChild)
      }

      this._restoreAnchor(anchor)

      // Update oldest message ID from the newly prepended messages
      const allMessages = this._getMessageElements()
      if (allMessages.length > 0) {
        this.oldestMessageIdValue = allMessages[0].id.replace("message_", "")
      }

      // Use header to determine if there are more
      const hasMore = response.headers.get("X-Has-Older")
      if (hasMore === "false") {
        this.hasOlderValue = false
      }

      // Trim bottom if over cap
      this.trimBottom()

      // Delay unsetting so queued MutationObserver callbacks still see suppress=true
      setTimeout(() => { this._suppressObserver = false }, 0)

      // Bind image load handlers for scroll correction
      this._bindImageLoadHandlers()
    } catch (e) {
      this._suppressObserver = false
      console.error("Failed to load older messages:", e)
    } finally {
      this._loadingOlder = false
    }
  }

  async loadNewerMessages() {
    if (this._loadingNewer || !this.hasNewerValue || !this.newestMessageIdValue) return
    this._loadingNewer = true

    const serverId = this.serverIdValue
    const channelId = this.channelIdValue
    const afterId = this.newestMessageIdValue
    const url = `/servers/${serverId}/channels/${channelId}/newer_messages?after=${afterId}`

    try {
      const response = await fetch(url, {
        headers: {
          "Accept": "text/html",
          "X-Requested-With": "XMLHttpRequest"
        }
      })
      if (!response.ok) return

      const html = await response.text()
      if (!html.trim()) {
        this.hasNewerValue = false
        return
      }

      this._suppressObserver = true

      const anchor = this._findAnchorMessage()

      // Parse and append messages
      const template = document.createElement("template")
      template.innerHTML = html

      while (template.content.firstChild) {
        this.element.appendChild(template.content.firstChild)
      }

      this._restoreAnchor(anchor)

      // Update newest message ID
      const allMessages = this._getMessageElements()
      if (allMessages.length > 0) {
        this.newestMessageIdValue = allMessages[allMessages.length - 1].id.replace("message_", "")
      }

      // Use header to determine if there are more
      const hasNewer = response.headers.get("X-Has-Newer")
      if (hasNewer === "false") {
        this.hasNewerValue = false
      }

      // Trim top if over cap
      this.trimTop()

      setTimeout(() => { this._suppressObserver = false }, 0)

      // Bind image load handlers for scroll correction
      this._bindImageLoadHandlers()
    } catch (e) {
      this._suppressObserver = false
      console.error("Failed to load newer messages:", e)
    } finally {
      this._loadingNewer = false
    }
  }

  _bindImageLoadHandlers() {
    this.element.querySelectorAll("img").forEach(img => {
      if (!img.complete) {
        img.addEventListener("load", () => {
          if (this.isNearBottom()) this.scrollToBottom()
        }, { once: true })
      }
    })
  }

  showNewMessageBar(text) {
    if (!text) {
      this.newMessageCount++
      text = this.newMessageCount === 1 ? "New message" : `${this.newMessageCount} new messages`
    }
    const bar = this.element.parentElement?.querySelector("[data-scroll-position-target=newMessageBar]")
    if (bar) {
      bar.classList.remove("hidden")
      const countEl = bar.querySelector("[data-count]")
      if (countEl) countEl.textContent = text
    }
  }

  hideNewMessageBar() {
    this.newMessageCount = 0

    const bar = this.element.parentElement?.querySelector("[data-scroll-position-target=newMessageBar]")
    if (bar) bar.classList.add("hidden")
  }

  getSavedPosition() {
    try {
      const positions = JSON.parse(sessionStorage.getItem("channel_scroll") || "{}")
      return positions[this.channelIdValue] ?? null
    } catch { return null }
  }

  savePosition(pos) {
    if (this._initializing) return
    try {
      const positions = JSON.parse(sessionStorage.getItem("channel_scroll") || "{}")
      positions[this.channelIdValue] = pos
      sessionStorage.setItem("channel_scroll", JSON.stringify(positions))

      // Save anchor message ID when in history (bottom trimmed)
      if (this.hasNewerValue) {
        const anchor = this._findAnchorMessage()
        if (anchor) {
          const anchorId = anchor.element.id.replace("message_", "")
          const anchors = JSON.parse(sessionStorage.getItem("channel_anchors") || "{}")
          anchors[this.channelIdValue] = anchorId
          sessionStorage.setItem("channel_anchors", JSON.stringify(anchors))
        }
      } else {
        // Clear anchor when at present
        this.clearSavedAnchor()
      }
    } catch {}
  }

  getSavedAnchor() {
    try {
      const anchors = JSON.parse(sessionStorage.getItem("channel_anchors") || "{}")
      return anchors[this.channelIdValue] ?? null
    } catch { return null }
  }

  clearSavedAnchor() {
    try {
      const anchors = JSON.parse(sessionStorage.getItem("channel_anchors") || "{}")
      delete anchors[this.channelIdValue]
      sessionStorage.setItem("channel_anchors", JSON.stringify(anchors))
    } catch {}
  }

  async loadAroundMessage(messageId) {
    const serverId = this.serverIdValue
    const channelId = this.channelIdValue
    const url = `/servers/${serverId}/channels/${channelId}/around_messages?around=${messageId}`

    try {
      const response = await fetch(url, {
        headers: {
          "Accept": "text/html",
          "X-Requested-With": "XMLHttpRequest"
        }
      })
      if (!response.ok) {
        this.clearSavedAnchor()
        this.scrollToBottom()
        this._initializing = false
        return
      }

      const html = await response.text()
      if (!html.trim()) {
        this.clearSavedAnchor()
        this.scrollToBottom()
        this._initializing = false
        return
      }

      this._suppressObserver = true

      // Replace all content
      this.element.innerHTML = html

      // Update cursors from headers
      this.hasOlderValue = response.headers.get("X-Has-Older") !== "false"
      this.hasNewerValue = response.headers.get("X-Has-Newer") !== "false"

      const allMessages = this._getMessageElements()
      if (allMessages.length > 0) {
        this.oldestMessageIdValue = allMessages[0].id.replace("message_", "")
        this.newestMessageIdValue = allMessages[allMessages.length - 1].id.replace("message_", "")
      }

      // Scroll to the anchor message
      const anchorEl = document.getElementById(`message_${messageId}`)
      if (anchorEl) {
        anchorEl.scrollIntoView({ block: "center" })
      }

      // Wait for images to load before allowing scroll-triggered loads.
      // Without this, unloaded images make content short, isNearBottom()
      // returns true, and loadNewerMessages chain-fires to the present.
      const images = Array.from(this.element.querySelectorAll("img")).filter(i => !i.complete)
      if (images.length > 0) {
        let loaded = 0
        let settled = false
        const settle = () => {
          if (settled) return
          if (++loaded >= images.length) {
            settled = true
            if (anchorEl && anchorEl.isConnected) {
              anchorEl.scrollIntoView({ block: "center" })
            }
            this._suppressObserver = false
            this._initializing = false
          }
        }
        images.forEach(i => i.addEventListener("load", settle, { once: true }))
        images.forEach(i => i.addEventListener("error", settle, { once: true }))
        setTimeout(() => {
          if (!settled) {
            settled = true
            if (anchorEl && anchorEl.isConnected) {
              anchorEl.scrollIntoView({ block: "center" })
            }
            this._suppressObserver = false
            this._initializing = false
          }
        }, 3000)
      } else {
        setTimeout(() => {
          this._suppressObserver = false
          this._initializing = false
        }, 200)
      }
    } catch (e) {
      console.error("Failed to load around message:", e)
      this._suppressObserver = false
      this.clearSavedAnchor()
      this.scrollToBottom()
      this._initializing = false
    }
  }
}
