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
    this._lastAnchorId = null
    this._loadingOlder = false
    this._loadingNewer = false

    // Save scroll position before turbo frame replaces content (element still in DOM)
    this._onBeforeFrameRender = (e) => {
      if (e.target.id === "main-content") {
        const pos = this.element.scrollTop || this._lastScrollTop
        if (pos > 0) this._forceSave(pos)
      }
    }
    document.addEventListener("turbo:before-frame-render", this._onBeforeFrameRender)

    // Intercept clicks on internal message links
    this._onLinkClick = (e) => {
      const a = e.target.closest("a[href]")
      if (!a) return
      const href = a.getAttribute("href")
      if (!href) return
      const match = href.match(/(?:https?:\/\/[^\/]+)?\/servers\/([a-zA-Z0-9]+)\/channels\/([a-zA-Z0-9]+)#message[-_]([a-zA-Z0-9]+)/)
      if (!match) return
      e.preventDefault()
      e.stopPropagation()
      const [, sId, cId, mId] = match
      const currentEl = document.querySelector("[data-current-channel-id]")
      const currentChannelId = currentEl ? currentEl.dataset.currentChannelId : null
      if (currentChannelId === cId) {
        const el = document.getElementById(`message_${mId}`)
        if (el) {
          el.scrollIntoView({ behavior: "smooth", block: "center" })
          this.highlightMessage(el, true)
        }
      } else {
        const url = `/servers/${sId}/channels/${cId}`
        sessionStorage.setItem("jump_to_message", mId)
        window.Turbo.visit(url)
      }
    }
    document.addEventListener("click", this._onLinkClick, true)

    // --- Restore scroll position immediately (content is already in DOM) ---

    const pendingJump = sessionStorage.getItem("jump_to_message")
    if (pendingJump) {
      sessionStorage.removeItem("jump_to_message")
      this._jumpToMessage(pendingJump)
    } else {
      const hash = window.location.hash
      const messageMatch = hash.match(/^#message[-_]([a-zA-Z0-9]+)$/)
      if (messageMatch) {
        history.replaceState(null, "", window.location.pathname + window.location.search)
        this._jumpToMessage(messageMatch[1])
      } else {
        this._restoreScroll()
      }
    }

    // Track scroll position continuously
    this._onScroll = () => {
      this._lastScrollTop = this.element.scrollTop
      if (!this.isNearBottom()) this._keepingBottom = false
      if (this.isNearBottom()) this.hideNewMessageBar()
      if (this.isNearTop() && !this._initializing) {
        this.loadOlderMessages()
      }
      if (this.isNearBottom() && this.hasNewerValue && !this._initializing) {
        this.loadNewerMessages()
      }
    }
    this.element.addEventListener("scroll", this._onScroll)

    // Save periodically
    this._saveInterval = setInterval(() => {
      this.savePosition(this._lastScrollTop)
    }, 1000)

    // Bind "Jump to Present" / "New message" bar
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
      const newMessages = []
      for (const m of mutations) {
        for (const n of m.addedNodes) {
          if (n.nodeType === 1 && n.id?.startsWith("message_")) newMessages.push(n)
        }
      }
      if (!newMessages.length) return

      const wasNearBottom = this.isNearBottom()

      if (wasNearBottom) {
        this.scrollToBottom()
        // Bind image load handlers on new messages so we stay at bottom as images load
        for (const msg of newMessages) {
          msg.querySelectorAll("img").forEach(img => {
            if (!img.complete) {
              img.addEventListener("load", () => {
                if (this.isNearBottom()) this.scrollToBottom()
              }, { once: true })
            }
          })
        }
      } else {
        this.showNewMessageBar()
      }
    })
    this.observer.observe(this.element, { childList: true })

    this.element.querySelectorAll("img").forEach(img => {
      if (!img.complete) {
        img.addEventListener("load", () => {
          if (this._initializing) return
          if (this.isNearBottom()) {
            this.scrollToBottom()
          } else if (this._restoredAnchorEl?.isConnected) {
            // Re-anchor after image loads to prevent drift
            this._restoredAnchorEl.scrollIntoView({ block: "center" })
            this._lastScrollTop = this.element.scrollTop
          }
        }, { once: true })
      }
    })
  }

  // --- Immediate scroll restoration ---

  _restoreScroll() {
    const savedAnchor = this.getSavedAnchor()

    // Was at bottom — go straight to bottom and stay there as media loads
    if (savedAnchor === "__bottom__") {
      this.scrollToBottom()
      this._lastAnchorId = "__bottom__"
      this._keepAtBottom()
      this._finishInit()
      return
    }

    if (savedAnchor) {
      const el = document.getElementById(`message_${savedAnchor}`)
      if (el) {
        this._restoredAnchorEl = el
        el.scrollIntoView({ block: "center" })
        this._lastScrollTop = this.element.scrollTop
        this._finishInit()
        return
      }
      // Anchor not in DOM — clear stale anchor, fall through to pixel position
      this.clearSavedAnchor()
      this._lastAnchorId = null
    }

    const saved = this.getSavedPosition()
    if (saved !== null && saved > 0) {
      this.element.scrollTop = saved
      this._lastScrollTop = saved
      if (this.isNearBottom()) {
        this.scrollToBottom()
        this._lastAnchorId = "__bottom__"
      }
    } else {
      this.scrollToBottom()
      this._lastAnchorId = "__bottom__"
    }
    this._finishInit()
  }

  _jumpToMessage(messageId) {
    const el = document.getElementById(`message_${messageId}`)
    if (el) {
      el.scrollIntoView({ behavior: "smooth", block: "center" })
      this._lastScrollTop = this.element.scrollTop
      this.highlightMessage(el, true)
      this._finishInit()
    } else {
      this.waitForMessage(messageId, (msgEl) => {
        msgEl.scrollIntoView({ behavior: "smooth", block: "center" })
        this._lastScrollTop = this.element.scrollTop
        this.highlightMessage(msgEl, true)
        this._finishInit()
      })
    }
  }

  _finishInit() {
    // Single rAF — enough to prevent scroll handler from firing during initial set
    requestAnimationFrame(() => {
      this._initializing = false
      // Force lazy images in viewport to load (Turbo Frame swap can skip them)
      this._eagerLoadVisibleImages()
    })
  }

  _eagerLoadVisibleImages() {
    const rect = this.element.getBoundingClientRect()
    this.element.querySelectorAll('img[loading="lazy"]').forEach(img => {
      if (img.complete) return
      const imgRect = img.getBoundingClientRect()
      // If image is within or near the visible scroll area, force it to load
      if (imgRect.bottom >= rect.top - 200 && imgRect.top <= rect.bottom + 200) {
        img.loading = "eager"
      }
    })
  }

  highlightMessage(el, afterScroll = false) {
    const doHighlight = () => {
      el.style.backgroundColor = "rgba(220, 38, 38, 0.3)"
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
      setTimeout(doHighlight, 600)
    } else {
      doHighlight()
    }
  }

  waitForMessage(messageId, callback, timeoutMs = 5000) {
    const el = document.getElementById(`message_${messageId}`)
    if (el) { callback(el); return }
    const obs = new MutationObserver((mutations, observer) => {
      const el = document.getElementById(`message_${messageId}`)
      if (el) {
        observer.disconnect()
        callback(el)
      }
    })
    obs.observe(this.element, { childList: true, subtree: true })
    setTimeout(() => {
      obs.disconnect()
      const el = document.getElementById(`message_${messageId}`)
      if (el) callback(el)
      else this.scrollToBottom()
    }, timeoutMs)
  }

  // --- Save helpers ---

  // Force save without _initializing guard (for disconnect / frame swap)
  _forceSave(pos) {
    try {
      const positions = JSON.parse(sessionStorage.getItem("channel_scroll") || "{}")
      positions[this.channelIdValue] = pos
      sessionStorage.setItem("channel_scroll", JSON.stringify(positions))

      // Use cached anchor ID (DOM may be detached at disconnect time)
      if (this._lastAnchorId) {
        sessionStorage.setItem("channel_anchor_" + this.channelIdValue, this._lastAnchorId)
      }
    } catch {}
  }

  disconnect() {
    // Always save — use cached value since element may be detached from DOM
    if (this._lastScrollTop > 0) this._forceSave(this._lastScrollTop)
    document.removeEventListener("turbo:before-frame-render", this._onBeforeFrameRender)
    document.removeEventListener("click", this._onLinkClick, true)
    if (this._jumpBtn && this._jumpHandler) {
      this._jumpBtn.removeEventListener("click", this._jumpHandler)
    }
    this.observer?.disconnect()
    try { this.element.removeEventListener("scroll", this._onScroll) } catch {}
    clearInterval(this._saveInterval)
  }

  // Keep snapping to bottom as media (images, iframes, videos) loads.
  // Cancelled immediately if the user scrolls away from bottom.
  _keepAtBottom() {
    this._keepingBottom = true
    const snap = () => { if (this._keepingBottom) this.scrollToBottom() }
    this.element.querySelectorAll("img, iframe, video").forEach(el => {
      if (el.tagName === "IMG" && !el.complete) {
        el.addEventListener("load", snap, { once: true })
      } else if (el.tagName === "IFRAME") {
        el.addEventListener("load", snap, { once: true })
      } else if (el.tagName === "VIDEO") {
        el.addEventListener("loadedmetadata", snap, { once: true })
      }
    })
    // Fallback: periodic re-snap for 2 seconds to catch any layout shifts
    let count = 0
    const tick = () => {
      if (!this._keepingBottom || count++ >= 8) return
      this.scrollToBottom()
      setTimeout(tick, 250)
    }
    setTimeout(tick, 250)
  }

  scrollToBottom() {
    this.element.scrollTop = this.element.scrollHeight
    this._lastScrollTop = this.element.scrollTop
    this.hideNewMessageBar()
  }

  jumpToBottom() {
    this.clearSavedAnchor()
    if (this.hasNewerValue) {
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
    const containerRect = this.element.getBoundingClientRect()
    const centerY = containerRect.top + containerRect.height / 2
    let closest = null
    let closestDist = Infinity
    for (const msg of messages) {
      const rect = msg.getBoundingClientRect()
      if (rect.bottom < containerRect.top || rect.top > containerRect.bottom) continue
      const msgCenter = rect.top + rect.height / 2
      const dist = Math.abs(msgCenter - centerY)
      if (dist < closestDist) {
        closestDist = dist
        closest = { element: msg, offsetTop: rect.top }
      }
    }
    return closest
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
    for (let i = messages.length - 1; i >= messages.length - toRemove; i--) {
      messages[i].remove()
    }

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
    for (let i = 0; i < toRemove; i++) {
      messages[i].remove()
    }

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

      const template = document.createElement("template")
      template.innerHTML = html

      const firstChild = this.element.firstChild

      while (template.content.firstChild) {
        this.element.insertBefore(template.content.firstChild, firstChild)
      }

      this._restoreAnchor(anchor)

      const allMessages = this._getMessageElements()
      if (allMessages.length > 0) {
        this.oldestMessageIdValue = allMessages[0].id.replace("message_", "")
      }

      const hasMore = response.headers.get("X-Has-Older")
      if (hasMore === "false") {
        this.hasOlderValue = false
      }

      this.trimBottom()

      setTimeout(() => { this._suppressObserver = false }, 0)

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

      const template = document.createElement("template")
      template.innerHTML = html

      while (template.content.firstChild) {
        this.element.appendChild(template.content.firstChild)
      }

      this._restoreAnchor(anchor)

      const allMessages = this._getMessageElements()
      if (allMessages.length > 0) {
        this.newestMessageIdValue = allMessages[allMessages.length - 1].id.replace("message_", "")
      }

      const hasNewer = response.headers.get("X-Has-Newer")
      if (hasNewer === "false") {
        this.hasNewerValue = false
      }

      this.trimTop()

      setTimeout(() => { this._suppressObserver = false }, 0)

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
      bar.classList.remove("hidden", "new-msg-bar-exit")
      bar.classList.add("new-msg-bar-enter")
      const countEl = bar.querySelector("[data-count]")
      if (countEl) countEl.textContent = text
    }
  }

  hideNewMessageBar() {
    this.newMessageCount = 0

    const bar = this.element.parentElement?.querySelector("[data-scroll-position-target=newMessageBar]")
    if (bar && !bar.classList.contains("hidden")) {
      bar.classList.remove("new-msg-bar-enter")
      bar.classList.add("new-msg-bar-exit")
      bar.addEventListener("animationend", () => {
        bar.classList.add("hidden")
        bar.classList.remove("new-msg-bar-exit")
      }, { once: true })
    }
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

      // Save single anchor per channel — replaces any previous anchor
      if (this.isNearBottom() && !this.hasNewerValue) {
        this._lastAnchorId = "__bottom__"
        sessionStorage.setItem("channel_anchor_" + this.channelIdValue, "__bottom__")
      } else {
        const anchor = this._findAnchorMessage()
        if (anchor) {
          this._lastAnchorId = anchor.element.id.replace("message_", "")
          sessionStorage.setItem("channel_anchor_" + this.channelIdValue, this._lastAnchorId)
        }
      }
    } catch {}
  }

  getSavedAnchor() {
    try {
      return sessionStorage.getItem("channel_anchor_" + this.channelIdValue) || null
    } catch { return null }
  }

  clearSavedAnchor() {
    try {
      sessionStorage.removeItem("channel_anchor_" + this.channelIdValue)
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

      this.element.innerHTML = html

      this.hasOlderValue = response.headers.get("X-Has-Older") !== "false"
      this.hasNewerValue = response.headers.get("X-Has-Newer") !== "false"

      const allMessages = this._getMessageElements()
      if (allMessages.length > 0) {
        this.oldestMessageIdValue = allMessages[0].id.replace("message_", "")
        this.newestMessageIdValue = allMessages[allMessages.length - 1].id.replace("message_", "")
      }

      const anchorEl = document.getElementById(`message_${messageId}`)
      if (anchorEl) {
        anchorEl.scrollIntoView({ block: "center" })
      }

      // Brief guard to prevent scroll-triggered loads while images settle
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
        this._suppressObserver = false
        this._initializing = false
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
