import { Controller } from "@hotwired/stimulus"

// Hint definitions — each key maps to tooltip content and preferred dot position.
// position: where the dot sits relative to the element
// anchor: "start" | "center" | "end" — where along the edge to place the dot
const HINT_DEFS = {
  // Main app hints
  server_rail:    { title: "Your Servers",     text: "Servers you join or create appear here. Click one to enter it.", position: "right", anchor: "start" },
  add_server:     { title: "Add a Server",     text: "Create your own server or join an existing one with an invite link.", position: "right", anchor: "center" },
  home_button:    { title: "Home",             text: "Go here to see your direct messages and friends list.", position: "right", anchor: "center" },
  channel_list:   { title: "Channels",         text: "Text and voice channels in this server. Click to switch between them.", position: "right", anchor: "start" },
  message_input:  { title: "Send a Message",   text: "Type here and press Enter to send. You can drag & drop files or use the emoji picker.", position: "top", anchor: "center" },
  voice_controls: { title: "Voice Controls",   text: "Mute, deafen, toggle camera, or adjust voice settings while in a voice channel.", position: "top", anchor: "center" },
  user_panel:     { title: "Your Profile",     text: "Click your avatar to change status. The gear icon opens settings.", position: "top", anchor: "center" },
  member_list:    { title: "Members",          text: "Toggle the member list to see who's in this channel.", position: "left", anchor: "center" },
  dm_friends:     { title: "Friends",          text: "View your friends list, pending requests, and add new friends.", position: "right", anchor: "center" },
  pin_messages:   { title: "Pinned Messages",  text: "Important messages pinned in this channel. You can pin messages from the context menu.", position: "bottom", anchor: "center" },

  // Profile settings hints — use "inline" so dots sit inside section corners, not overlapping fields
  settings_banner:     { title: "Banner & Avatar",     text: "Click to upload a banner image. Drag to reposition it. Click your avatar to change it.", position: "inline" },
  settings_theme:      { title: "Profile Theme",       text: "Pick two colors for a gradient background on your profile card.", position: "inline" },
  settings_display:    { title: "Display Name",        text: "Your display name shows everywhere. You can use server emoji in it!", position: "inline" },
  settings_status:     { title: "Custom Status",       text: "Set an emoji and text to show under your name. Others can see this.", position: "inline" },
  settings_preview:    { title: "Live Preview",        text: "See how your profile card will look to other users as you make changes.", position: "inline" },

  // Server settings hints
  ss_name:        { title: "Server Name",      text: "The name shown in the server rail and invite links. Keep it short and memorable.", position: "inline" },
  ss_icon:        { title: "Server Icon",      text: "Upload a square image (512x512 recommended). Shows in the server rail.", position: "inline" },
  ss_config:      { title: "Server Options",   text: "Make your server public so anyone can find it, or require an invite link.", position: "inline" },
  ss_welcome:     { title: "Welcome Message",  text: "Automatically greet new members. Use {user} to mention them by name.", position: "inline" },
  ss_preview:     { title: "Invite Preview",   text: "This is how your server appears in invite links and the server directory.", position: "inline" },
}

const ALL_KEYS = Object.keys(HINT_DEFS)

export default class extends Controller {
  static values = {
    seen: { type: Array, default: [] },
    dismissUrl: String,
    debug: { type: Boolean, default: false },
  }

  connect() {
    this.activeDots = new Map()
    this.activeTooltip = null

    // In debug mode, show all hints regardless of seen state
    if (this.debugValue) {
      this.seenValue = []
    }

    // Delay initial scan to let layout settle after connect
    setTimeout(() => this._scanHints(), 200)

    this._onFrameLoad = () => {
      setTimeout(() => {
        this._scanHints()
        this._repositionDots()
      }, 200)
    }
    this._onResize = () => this._repositionDots()
    this._onClickOutside = (e) => this._handleOutsideClick(e)
    this._onScroll = () => this._repositionDots()

    this._onOverlayClosed = () => {
      this._clearAll()
      this._scanHints()
    }
    this._onDismissAll = () => this._dismissAll()

    document.addEventListener("turbo:frame-load", this._onFrameLoad)
    document.addEventListener("turbo:load", this._onFrameLoad)
    document.addEventListener("turbo:before-render", this._onFrameLoad)
    window.addEventListener("resize", this._onResize)
    document.addEventListener("mousedown", this._onClickOutside)
    document.addEventListener("settings-overlay:closed", this._onOverlayClosed)
    document.addEventListener("hints:dismiss-all", this._onDismissAll)
    // Reposition on scroll in any container
    document.addEventListener("scroll", this._onScroll, true)
  }

  disconnect() {
    document.removeEventListener("turbo:frame-load", this._onFrameLoad)
    document.removeEventListener("turbo:load", this._onFrameLoad)
    document.removeEventListener("turbo:before-render", this._onFrameLoad)
    window.removeEventListener("resize", this._onResize)
    document.removeEventListener("mousedown", this._onClickOutside)
    document.removeEventListener("settings-overlay:closed", this._onOverlayClosed)
    document.removeEventListener("hints:dismiss-all", this._onDismissAll)
    document.removeEventListener("scroll", this._onScroll, true)
    this._clearAll()
  }

  _csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content
  }

  _scanHints() {
    const els = document.querySelectorAll("[data-hint]")
    els.forEach(el => {
      const key = el.dataset.hint
      if (!HINT_DEFS[key]) return
      if (this.activeDots.has(key)) return
      if (!this.debugValue && this.seenValue.includes(key)) return

      // Skip elements that are not visible
      if (!this._isVisible(el)) return

      this._createDot(el, key)
    })

    // Remove dots whose elements are gone or hidden
    for (const [key, dot] of this.activeDots) {
      if (!dot._targetEl || !document.body.contains(dot._targetEl) || !this._isVisible(dot._targetEl)) {
        dot.remove()
        this.activeDots.delete(key)
      }
    }
  }

  _isVisible(el) {
    // Check if element or ancestor is hidden
    if (el.offsetParent === null && getComputedStyle(el).position !== "fixed") return false
    const rect = el.getBoundingClientRect()
    // Element has no dimensions
    if (rect.width === 0 && rect.height === 0) return false
    // Element is completely off-screen
    if (rect.bottom < 0 || rect.top > window.innerHeight) return false
    if (rect.right < 0 || rect.left > window.innerWidth) return false
    // Check for "hidden" class (Tailwind)
    if (el.classList.contains("hidden")) return false
    // If the settings overlay is open, only show hints for elements inside it
    const overlay = document.getElementById("settings-overlay")
    if (overlay && !overlay.classList.contains("hidden")) {
      if (!overlay.contains(el)) return false
    }
    return true
  }

  _createDot(el, key) {
    const def = HINT_DEFS[key]
    const dot = document.createElement("div")
    dot.className = "hint-dot"
    dot._targetEl = el
    dot._hintKey = key
    dot._position = def.position
    dot._anchor = def.anchor || "center"
    dot._inline = def.position === "inline"

    // Set arrow direction — arrow points TOWARD the element
    const directionMap = { right: "left", left: "right", top: "down", bottom: "up", inline: "inline" }
    dot.dataset.direction = directionMap[def.position] || "left"

    dot.addEventListener("click", (e) => {
      e.stopPropagation()
      e.preventDefault()
      this._showTooltip(el, key)
    })

    if (dot._inline) {
      const computed = getComputedStyle(el)
      if (computed.position === "static") {
        el.style.position = "relative"
      }
      dot.style.position = "absolute"
      dot.style.top = "6px"
      dot.style.right = "6px"
      dot.style.zIndex = "5"
      el.appendChild(dot)
    } else {
      document.body.appendChild(dot)
      this._positionDot(dot, el, def.position, dot._anchor)
    }
    this.activeDots.set(key, dot)
  }

  _getZoomFactor() {
    // CSS zoom on <html> shifts getBoundingClientRect() relative to fixed positioning
    const z = parseFloat(getComputedStyle(document.documentElement).zoom)
    return (z && isFinite(z)) ? z : 1
  }

  _positionDot(dot, el, position, anchor = "center") {
    // Inline dots are positioned via CSS, skip
    if (dot._inline) return

    const rect = el.getBoundingClientRect()
    if (rect.width === 0 && rect.height === 0) return

    const z = this._getZoomFactor()
    // Convert zoomed viewport coords to fixed-position coords
    const r = { top: rect.top / z, left: rect.left / z, right: rect.right / z, bottom: rect.bottom / z, width: rect.width / z, height: rect.height / z }

    let top, left
    const dotSize = 10
    const offset = 6 // gap from element edge
    const vpW = window.innerWidth / z
    const vpH = window.innerHeight / z

    // Calculate cross-axis position based on anchor
    const crossPos = (start, size) => {
      switch (anchor) {
        case "start": return start + Math.min(16, size * 0.15)
        case "end": return start + size - Math.min(16, size * 0.15) - dotSize
        default: return start + size / 2 - dotSize / 2
      }
    }

    switch (position) {
      case "right":
        top = crossPos(r.top, r.height)
        left = r.right + offset
        break
      case "left":
        top = crossPos(r.top, r.height)
        left = r.left - offset - dotSize
        break
      case "top":
        top = r.top - offset - dotSize
        left = crossPos(r.left, r.width)
        break
      case "bottom":
        top = r.bottom + offset
        left = crossPos(r.left, r.width)
        break
    }

    // Clamp to viewport
    top = Math.max(4, Math.min(top, vpH - dotSize - 4))
    left = Math.max(4, Math.min(left, vpW - dotSize - 4))

    dot.style.top = `${Math.round(top)}px`
    dot.style.left = `${Math.round(left)}px`
  }

  _showTooltip(el, key) {
    this._closeTooltip()

    const def = HINT_DEFS[key]
    // Count only visible hints for the counter
    const visibleKeys = ALL_KEYS.filter(k => {
      const marker = document.querySelector(`[data-hint="${k}"]`)
      return marker && this._isVisible(marker)
    })
    const visibleSeen = this.seenValue.filter(k => visibleKeys.includes(k))
    const currentIndex = visibleSeen.length + 1
    const totalVisible = visibleKeys.length

    const tooltip = document.createElement("div")
    tooltip.className = "hint-tooltip"
    tooltip.innerHTML = `
      <h4 class="text-sm font-semibold text-white mb-1">${def.title}</h4>
      <p class="text-xs text-gray-400 leading-relaxed">${def.text}</p>
      <div class="flex items-center justify-between mt-3">
        <span class="text-[11px] text-gray-500">${currentIndex} of ${totalVisible} tips</span>
        <button class="hint-got-it text-xs text-white px-3 py-1 rounded cursor-pointer" style="background: var(--color-accent);">Got it</button>
      </div>
    `

    const arrow = document.createElement("div")
    arrow.className = "hint-tooltip-arrow"
    tooltip.appendChild(arrow)

    document.body.appendChild(tooltip)
    // For inline dots, position tooltip below the element; otherwise use the hint's preferred position
    this._positionTooltip(tooltip, arrow, el, def.position === "inline" ? "bottom" : def.position)

    tooltip.querySelector(".hint-got-it").addEventListener("click", (e) => {
      e.stopPropagation()
      this._dismiss(key)
    })

    tooltip.addEventListener("mousedown", (e) => e.stopPropagation())

    this.activeTooltip = { el: tooltip, key }
  }

  _positionTooltip(tooltip, arrow, el, preferredPos) {
    const rawRect = el.getBoundingClientRect()
    const z = this._getZoomFactor()
    const rect = { top: rawRect.top / z, left: rawRect.left / z, right: rawRect.right / z, bottom: rawRect.bottom / z, width: rawRect.width / z, height: rawRect.height / z }
    const tw = tooltip.offsetWidth
    const th = tooltip.offsetHeight
    const gap = 14
    const vw = window.innerWidth / z
    const vh = window.innerHeight / z

    let top, left, arrowSide

    const tryPosition = (pos) => {
      switch (pos) {
        case "top":
          if (rect.top - th - gap >= 0) {
            top = rect.top - th - gap
            left = rect.left + rect.width / 2 - tw / 2
            arrowSide = "bottom"
            return true
          }
          return false
        case "bottom":
          if (rect.bottom + th + gap <= vh) {
            top = rect.bottom + gap
            left = rect.left + rect.width / 2 - tw / 2
            arrowSide = "top"
            return true
          }
          return false
        case "left":
          if (rect.left - tw - gap >= 0) {
            top = rect.top + rect.height / 2 - th / 2
            left = rect.left - tw - gap
            arrowSide = "right"
            return true
          }
          return false
        case "right":
          if (rect.right + tw + gap <= vw) {
            top = rect.top + rect.height / 2 - th / 2
            left = rect.right + gap
            arrowSide = "left"
            return true
          }
          return false
      }
      return false
    }

    // Try preferred, then fallbacks
    const fallbacks = ["bottom", "top", "right", "left"].filter(p => p !== preferredPos)
    if (!tryPosition(preferredPos)) {
      let placed = false
      for (const pos of fallbacks) {
        if (tryPosition(pos)) { placed = true; break }
      }
      // If nothing fits, force the preferred position
      if (!placed) {
        switch (preferredPos) {
          case "top":    top = rect.top - th - gap; left = rect.left + rect.width / 2 - tw / 2; arrowSide = "bottom"; break
          case "bottom": top = rect.bottom + gap; left = rect.left + rect.width / 2 - tw / 2; arrowSide = "top"; break
          case "left":   top = rect.top + rect.height / 2 - th / 2; left = rect.left - tw - gap; arrowSide = "right"; break
          case "right":  top = rect.top + rect.height / 2 - th / 2; left = rect.right + gap; arrowSide = "left"; break
        }
      }
    }

    // Clamp to viewport
    left = Math.max(8, Math.min(left, vw - tw - 8))
    top = Math.max(8, Math.min(top, vh - th - 8))

    tooltip.style.left = `${Math.round(left)}px`
    tooltip.style.top = `${Math.round(top)}px`

    // Position arrow
    const aw = 8
    const clampArrow = (val, max) => Math.min(Math.max(val, 12), max - aw - 12)

    switch (arrowSide) {
      case "top":
        arrow.style.top = `${-aw / 2}px`
        arrow.style.left = `${clampArrow(rect.left + rect.width / 2 - left - aw / 2, tw)}px`
        arrow.style.borderTop = "none"
        arrow.style.borderLeft = "none"
        break
      case "bottom":
        arrow.style.top = `${th - aw / 2}px`
        arrow.style.left = `${clampArrow(rect.left + rect.width / 2 - left - aw / 2, tw)}px`
        arrow.style.borderBottom = "none"
        arrow.style.borderRight = "none"
        break
      case "left":
        arrow.style.left = `${-aw / 2}px`
        arrow.style.top = `${clampArrow(rect.top + rect.height / 2 - top - aw / 2, th)}px`
        arrow.style.borderBottom = "none"
        arrow.style.borderLeft = "none"
        break
      case "right":
        arrow.style.left = `${tw - aw / 2}px`
        arrow.style.top = `${clampArrow(rect.top + rect.height / 2 - top - aw / 2, th)}px`
        arrow.style.borderTop = "none"
        arrow.style.borderRight = "none"
        break
    }
  }

  _closeTooltip() {
    if (this.activeTooltip) {
      this.activeTooltip.el.remove()
      this.activeTooltip = null
    }
  }

  _handleOutsideClick(e) {
    if (!this.activeTooltip) return
    if (this.activeTooltip.el.contains(e.target)) return
    if (e.target.closest(".hint-dot")) return
    this._closeTooltip()
  }

  _dismissAll() {
    this._clearAll()
    this.seenValue = [...ALL_KEYS]

    fetch(this.dismissUrlValue.replace("dismiss_hint", "dismiss_all_hints"), {
      method: "POST",
      headers: { "X-CSRF-Token": this._csrfToken() },
    }).then(() => {
      this._showToast("All tutorial tips dismissed.")
    }).catch(() => {})
  }

  _showToast(message) {
    const toast = document.createElement("div")
    toast.className = "fixed top-4 right-4 z-[100] bg-success text-white px-4 py-2 rounded-lg shadow-lg"
    toast.setAttribute("data-controller", "toast")
    toast.textContent = message
    document.body.appendChild(toast)
  }

  _dismiss(key) {
    const dot = this.activeDots.get(key)
    if (dot) {
      dot.remove()
      this.activeDots.delete(key)
    }
    this._closeTooltip()

    if (!this.seenValue.includes(key)) {
      this.seenValue = [...this.seenValue, key]
    }

    const token = this._csrfToken()
    fetch(this.dismissUrlValue, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": token,
      },
      body: JSON.stringify({ hint_key: key }),
    }).catch(() => {})
  }

  _repositionDots() {
    for (const [key, dot] of this.activeDots) {
      const el = dot._targetEl
      if (!el || !document.body.contains(el) || !this._isVisible(el)) {
        dot.remove()
        this.activeDots.delete(key)
        continue
      }
      this._positionDot(dot, el, dot._position, dot._anchor)
    }
    // Also reposition active tooltip
    if (this.activeTooltip) {
      const dot = this.activeDots.get(this.activeTooltip.key)
      if (dot) {
        const def = HINT_DEFS[this.activeTooltip.key]
        const arrowEl = this.activeTooltip.el.querySelector(".hint-tooltip-arrow")
        if (arrowEl) {
          // Reset arrow styles before repositioning
          arrowEl.style.borderTop = ""
          arrowEl.style.borderBottom = ""
          arrowEl.style.borderLeft = ""
          arrowEl.style.borderRight = ""
        }
        this._positionTooltip(this.activeTooltip.el, arrowEl, dot._targetEl, def.position)
      }
    }
  }

  _clearAll() {
    for (const [, dot] of this.activeDots) {
      dot.remove()
    }
    this.activeDots.clear()
    this._closeTooltip()
  }
}
