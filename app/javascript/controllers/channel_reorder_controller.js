import { Controller } from "@hotwired/stimulus"

const NEST_HOVER_MS = 350
const MAX_DEPTH = 3
const DRAG_THRESHOLD = 5
const SCROLL_EDGE = 40
const SCROLL_SPEED = 8

export default class extends Controller {
  static values = { serverId: String, canManage: Boolean }

  connect() {
    if (!this.canManageValue) return

    this._state = "idle" // idle | pending | dragging
    this._draggedEl = null
    this._dragUnit = []
    this._ghost = null
    this._dropLine = null
    this._startX = 0
    this._startY = 0
    this._scrollRAF = null

    // Nest state
    this._nestTimer = null
    this._nestTarget = null
    this._nestActivated = false
    this._nestDropZone = null

    // Drop target tracking
    this._currentDropTarget = null
    this._currentDropBefore = true

    // Original position for cancel
    this._originalContainer = null
    this._originalNextSibling = null

    // Ensure container is positioned for the absolute drop-line indicator
    this.element.style.position = "relative"

    this._onPointerDown = this._onPointerDown.bind(this)
    this._onPointerMove = this._onPointerMove.bind(this)
    this._onPointerUp = this._onPointerUp.bind(this)
    this._onKeyDown = this._onKeyDown.bind(this)

    this.element.addEventListener("pointerdown", this._onPointerDown)
  }

  disconnect() {
    this.element.removeEventListener("pointerdown", this._onPointerDown)
    this._cancelDrag()
  }

  // ─── Drag units ──────────────────────────────────────────────

  // Returns an array of DOM elements that constitute a single draggable unit.
  // Uses data-attribute lookups so the result is correct even if siblings are
  // out of order (e.g. after a previous drag or Turbo Stream update).
  _getDragUnit(el) {
    if (el.hasAttribute("data-category-id")) return [el]

    const unit = [el]
    if (el.hasAttribute("data-voice-channel")) {
      const channelId = el.dataset.channelId

      const participants = this.element.querySelector(
        `.voice-participants[data-voice-channel-participants="${channelId}"]`
      )
      const childContainer = this.element.querySelector(
        `.voice-child-channels[data-parent-channel="${channelId}"]`
      )

      // Canonical order: <a> → participants → child-container
      if (participants) unit.push(participants)
      if (childContainer) unit.push(childContainer)
    }
    return unit
  }

  // ─── Pointer events ─────────────────────────────────────────

  _onPointerDown(e) {
    if (e.button !== 0) return
    if (this._state !== "idle") return

    // Don't start drag from interactive elements
    if (e.target.closest("button, input, a[href*='new_server_channel']")) return

    const target = e.target.closest("[data-channel-id], [data-category-id]")
    if (!target || !this.element.contains(target)) return

    // For categories, only allow drag from the header area (not channels inside)
    if (target.hasAttribute("data-category-id")) {
      const header = target.querySelector(":scope > div:first-child")
      if (header && !header.contains(e.target)) return
    }

    this._state = "pending"
    this._startX = e.clientX
    this._startY = e.clientY
    this._draggedEl = target

    document.addEventListener("pointermove", this._onPointerMove)
    document.addEventListener("pointerup", this._onPointerUp)
    document.addEventListener("keydown", this._onKeyDown)

    e.preventDefault()
  }

  _onPointerMove(e) {
    if (this._state === "pending") {
      const dx = e.clientX - this._startX
      const dy = e.clientY - this._startY
      if (Math.sqrt(dx * dx + dy * dy) < DRAG_THRESHOLD) return
      this._startDrag(e)
    }

    if (this._state !== "dragging") return

    // Move ghost
    this._ghost.style.left = `${e.clientX + 8}px`
    this._ghost.style.top = `${e.clientY - 12}px`

    // Find drop target
    this._updateDropTarget(e.clientX, e.clientY)

    // Auto-scroll
    this._handleAutoScroll(e.clientY)
  }

  _onPointerUp(e) {
    if (this._state === "pending") {
      // Was just a click, not a drag
      this._cleanupListeners()
      this._state = "idle"
      this._draggedEl = null
      return
    }

    if (this._state === "dragging") {
      this._performDrop()
    }
  }

  _onKeyDown(e) {
    if (e.key === "Escape" && this._state === "dragging") {
      this._cancelDrag()
    }
  }

  // ─── Drag lifecycle ──────────────────────────────────────────

  _startDrag(e) {
    this._state = "dragging"

    // Collect drag unit
    this._dragUnit = this._getDragUnit(this._draggedEl)

    // Snapshot original position for cancel
    const lastEl = this._dragUnit[this._dragUnit.length - 1]
    this._originalNextSibling = lastEl.nextElementSibling
    this._originalContainer = this._draggedEl.parentElement

    // Create ghost
    this._createGhost(e.clientX, e.clientY)

    // Fade originals
    this._dragUnit.forEach(el => {
      el.style.opacity = "0.2"
      el.style.pointerEvents = "none"
    })

    // Create drop indicator line
    this._dropLine = document.createElement("div")
    this._dropLine.className = "channel-drop-line"
    this.element.appendChild(this._dropLine)
    this._dropLine.style.display = "none"
  }

  _createGhost(x, y) {
    let sourceEl = this._draggedEl

    // For categories, clone just the header
    if (sourceEl.hasAttribute("data-category-id")) {
      const header = sourceEl.querySelector(":scope > div:first-child")
      if (header) sourceEl = header
    }

    const clone = sourceEl.cloneNode(true)
    clone.className = "channel-drag-ghost"
    // Copy the inner content styling
    clone.innerHTML = sourceEl.innerHTML
    clone.style.width = `${sourceEl.offsetWidth}px`
    clone.style.left = `${x + 8}px`
    clone.style.top = `${y - 12}px`

    document.body.appendChild(clone)
    this._ghost = clone
  }

  _performDrop() {
    const isDraggingCategory = this._draggedEl.hasAttribute("data-category-id")

    if (this._nestActivated && this._nestTarget) {
      // ── Nest drop ──
      this._commitNest()
    } else if (this._currentDropTarget) {
      // ── Normal reorder drop ──
      const target = this._currentDropTarget
      const before = this._currentDropBefore

      if (isDraggingCategory) {
        this._dropCategory(target, before)
      } else {
        this._dropChannel(target, before)
      }
    }
    // else: dropped nowhere valid — elements stay in original position (no-op)

    // Repair all voice channel structures: ensure each voice channel's
    // participants + child-container are contiguous siblings right after the <a>
    this._repairVoiceStructure()

    // Fix indent class based on final position
    if (!isDraggingCategory) {
      this._dragUnit.forEach(el => {
        if (el.hasAttribute("data-channel-id")) {
          if (el.closest(".voice-child-channels")) {
            el.classList.add("ml-3")
          } else {
            el.classList.remove("ml-3")
          }
        }
      })
    }

    // Remove empty voice-child-channels containers
    this.element.querySelectorAll(".voice-child-channels").forEach(container => {
      if (!container.querySelector("[data-channel-id]")) {
        container.remove()
      }
    })

    this._cleanupDrag()
    this.saveOrder()

    // Tell the sidebar controller (same element) to reinit voice sortables
    this.element.dispatchEvent(new CustomEvent("channel-reorder:done", { bubbles: false }))
  }

  _dropCategory(target, before) {
    // Categories can only live at root level
    if (target.hasAttribute("data-category-id")) {
      this._detachDragUnit()
      const ref = before ? target : target.nextElementSibling
      this.element.insertBefore(this._dragUnit[0], ref)
    }
  }

  _dropChannel(target, before) {
    if (target.hasAttribute("data-category-id")) {
      // Dropping onto a category → append into its channels container
      const channelsDiv = target.querySelector("[data-category-collapse-target='channels']")
      if (channelsDiv) {
        this._detachDragUnit()
        this._insertDragUnit(channelsDiv, null) // append
      }
    } else if (target.hasAttribute("data-channel-id")) {
      const container = target.parentElement

      // Only voice channels can live inside voice-child-channels
      if (container.classList.contains("voice-child-channels") &&
          !this._draggedEl.hasAttribute("data-voice-channel")) {
        return
      }

      // Detach first so nextElementSibling isn't a drag-unit element
      this._detachDragUnit()

      if (before) {
        this._insertDragUnit(container, target)
      } else {
        const targetUnit = this._getDragUnit(target)
        const lastOfTarget = targetUnit[targetUnit.length - 1]
        this._insertDragUnit(container, lastOfTarget.nextElementSibling)
      }
    }
  }

  // Remove drag unit from the DOM without destroying references
  _detachDragUnit() {
    this._dragUnit.forEach(el => el.remove())
  }

  _insertDragUnit(container, refNode) {
    this._dragUnit.forEach(el => {
      container.insertBefore(el, refNode)
    })
  }

  _cancelDrag() {
    if (this._state !== "dragging") {
      this._cleanupListeners()
      this._state = "idle"
      this._draggedEl = null
      return
    }
    // Elements haven't been moved yet (or we restore them)
    // No DOM changes needed — just clean up visuals
    this._cleanupDrag()
  }

  _cleanupDrag() {
    // Restore opacity
    this._dragUnit.forEach(el => {
      el.style.opacity = ""
      el.style.pointerEvents = ""
    })

    // Remove ghost
    if (this._ghost) {
      this._ghost.remove()
      this._ghost = null
    }

    // Remove drop line
    if (this._dropLine) {
      this._dropLine.remove()
      this._dropLine = null
    }

    // Clear nest state
    this._clearNest()

    // Clear drop target highlighting
    this._clearDropTargetHighlight()

    // Stop auto-scroll
    this._stopAutoScroll()

    this._cleanupListeners()

    this._state = "idle"
    this._draggedEl = null
    this._dragUnit = []
    this._currentDropTarget = null
    this._currentDropBefore = true
    this._originalContainer = null
    this._originalNextSibling = null
  }

  _cleanupListeners() {
    document.removeEventListener("pointermove", this._onPointerMove)
    document.removeEventListener("pointerup", this._onPointerUp)
    document.removeEventListener("keydown", this._onKeyDown)
  }

  // ─── Drop target detection ──────────────────────────────────

  _updateDropTarget(x, y) {
    // Hide ghost so elementFromPoint sees through it
    this._ghost.style.display = "none"
    const el = document.elementFromPoint(x, y)
    this._ghost.style.display = ""

    if (!el || !this.element.contains(el)) {
      this._hideDropLine()
      this._clearDropTargetHighlight()
      this._handleNestCandidate(null, x, y)
      this._currentDropTarget = null
      return
    }

    const isDraggingCategory = this._draggedEl.hasAttribute("data-category-id")
    const isDraggingVoice = this._draggedEl.hasAttribute("data-voice-channel")

    // Walk up to find meaningful target
    let target = el.closest("[data-channel-id], [data-category-id]")

    // If we hit a voice-participants div, treat as its parent channel
    if (!target) {
      const vpEl = el.closest(".voice-participants")
      if (vpEl) {
        const parentId = vpEl.dataset.voiceChannelParticipants
        if (parentId) {
          target = this.element.querySelector(`[data-channel-id="${parentId}"]`)
        }
      }
    }

    // If we hit a voice-child-channels container (but not a channel inside it)
    if (!target) {
      const vcc = el.closest(".voice-child-channels")
      if (vcc && this._nestActivated) {
        // Inside the active nest container — keep nest active
        return
      }
    }

    // If inside a category channels div but not on a specific channel
    if (!target) {
      const channelsDiv = el.closest("[data-category-collapse-target='channels']")
      if (channelsDiv && !isDraggingCategory) {
        const catEl = channelsDiv.closest("[data-category-id]")
        if (catEl && catEl !== this._draggedEl) {
          this._clearDropTargetHighlight()
          catEl.classList.add("channel-drop-target")
          this._highlightedCategory = catEl
          this._currentDropTarget = catEl
          this._currentDropBefore = false // append into category
          this._hideDropLine()
          this._handleNestCandidate(null, x, y)
          return
        }
      }
    }

    if (!target || target === this._draggedEl) {
      // Check if we're in empty space at root level
      if (el === this.element || el.parentElement === this.element) {
        this._hideDropLine()
        this._clearDropTargetHighlight()
        this._handleNestCandidate(null, x, y)
        this._currentDropTarget = null
      }
      return
    }

    // Skip if target is part of our own drag unit
    if (this._dragUnit.includes(target)) return
    // Skip if target is inside our drag unit
    if (this._dragUnit.some(u => u.contains(target))) return

    // Non-voice channels cannot drop inside voice nests — redirect to root parent
    if (!isDraggingVoice && !isDraggingCategory &&
        target.hasAttribute("data-channel-id") &&
        target.closest(".voice-child-channels")) {
      const rootVoice = this._findNestRoot(target)
      if (rootVoice && rootVoice !== this._draggedEl && !this._dragUnit.includes(rootVoice)) {
        target = rootVoice
      } else {
        return
      }
    }

    // Category dragging: only reorder among root-level categories
    if (isDraggingCategory) {
      if (!target.hasAttribute("data-category-id")) return
      if (target.parentElement !== this.element) return
    }

    // Channel dragging: skip if hovering over a category header and we want to
    // drop INTO it (handled separately above via category highlight)
    if (!isDraggingCategory && target.hasAttribute("data-category-id")) {
      // Show category drop target highlight
      this._clearDropTargetHighlight()
      target.classList.add("channel-drop-target")
      this._highlightedCategory = target
      this._currentDropTarget = target
      this._currentDropBefore = false
      this._hideDropLine()
      this._handleNestCandidate(null, x, y)
      return
    }

    // Determine before/after based on cursor Y vs midpoint
    const rect = target.getBoundingClientRect()
    const midY = rect.top + rect.height / 2
    const before = y < midY

    this._currentDropTarget = target
    this._currentDropBefore = before

    // Clear category highlight if showing a line
    this._clearDropTargetHighlight()

    // Position the drop indicator line
    this._positionDropLine(target, before)

    // Handle nest candidate (voice-to-voice)
    if (isDraggingVoice && target.hasAttribute("data-voice-channel") &&
        target.hasAttribute("data-channel-id")) {
      this._handleNestCandidate(target, x, y)
    } else {
      this._handleNestCandidate(null, x, y)
    }
  }

  _positionDropLine(targetEl, before) {
    if (!this._dropLine) return

    const containerRect = this.element.getBoundingClientRect()

    // For "after", position after the last element of the target's drag unit
    let edgeEl = targetEl
    if (!before) {
      const targetUnit = this._getDragUnit(targetEl)
      edgeEl = targetUnit[targetUnit.length - 1]
    }

    const edgeRect = edgeEl.getBoundingClientRect()
    const lineY = before ? edgeRect.top : edgeRect.bottom
    const top = lineY - containerRect.top + this.element.scrollTop

    this._dropLine.style.display = ""
    this._dropLine.style.top = `${top - 1}px`

    // Indent the line if target is inside a category or nested container
    const inCategory = targetEl.closest("[data-category-collapse-target='channels']")
    const inNest = targetEl.closest(".voice-child-channels")
    if (inNest) {
      this._dropLine.style.left = "34px"
    } else if (inCategory) {
      this._dropLine.style.left = "8px"
    } else {
      this._dropLine.style.left = "8px"
    }
  }

  _hideDropLine() {
    if (this._dropLine) this._dropLine.style.display = "none"
  }

  _clearDropTargetHighlight() {
    if (this._highlightedCategory) {
      this._highlightedCategory.classList.remove("channel-drop-target")
      this._highlightedCategory = null
    }
  }

  // ─── Nest logic (hold-to-nest voice channels) ───────────────

  _handleNestCandidate(target, x, y) {
    // If nest is already activated and we're still near the target, keep it
    if (this._nestActivated && this._nestTarget) {
      if (target === this._nestTarget) return
      // Check if cursor is inside the nest target's child container
      const childContainer = this._findChildContainer(this._nestTarget)
      if (childContainer) {
        const ccRect = childContainer.getBoundingClientRect()
        if (x >= ccRect.left && x <= ccRect.right && y >= ccRect.top && y <= ccRect.bottom) {
          return // Still inside nest zone
        }
      }
      // Moved away from nest — cancel
      this._clearNest()
      return
    }

    // Clear timer if target changed
    if (this._nestTarget !== target) {
      this._clearNestTimer()
    }

    if (!target) {
      this._clearNestTimer()
      return
    }

    // Already timing this target
    if (this._nestTarget === target && this._nestTimer) return

    // Validate: target must be a voice channel, not self, not own descendant
    if (!target.hasAttribute("data-voice-channel")) return
    if (target === this._draggedEl) return
    if (this._isDescendantOf(target, this._draggedEl.dataset.channelId)) return

    // Validate depth
    const targetDepth = this._getChannelDepth(target)
    const draggedSubtreeDepth = this._getSubtreeDepth(this._draggedEl)
    if (targetDepth + draggedSubtreeDepth >= MAX_DEPTH) return

    this._nestTarget = target
    this._nestTimer = setTimeout(() => this._activateNest(), NEST_HOVER_MS)
  }

  _activateNest() {
    if (!this._nestTarget) return
    this._nestActivated = true

    // Hide the regular drop line
    this._hideDropLine()

    // Highlight the target channel
    this._nestTarget.classList.add("channel-nest-target")

    // Find or create the voice-child-channels container
    let childContainer = this._findChildContainer(this._nestTarget)

    if (!childContainer) {
      childContainer = document.createElement("div")
      childContainer.className = "voice-child-channels"
      const nestId = this._nestTarget.dataset.channelId
      childContainer.dataset.parentChannel = nestId
      // Insert after the target link and its voice-participants (if any)
      const participants = this.element.querySelector(
        `.voice-participants[data-voice-channel-participants="${nestId}"]`
      )
      const insertAfter = participants || this._nestTarget
      insertAfter.after(childContainer)
    }

    // Add the drop zone indicator inside the child container
    this._nestDropZone = document.createElement("div")
    this._nestDropZone.className = "channel-nest-dropzone"
    this._nestDropZone.innerHTML = `
      <div class="flex items-center gap-1.5 px-3 py-1.5 rounded border border-dashed border-accent/50 bg-accent/10 text-accent text-xs">
        <svg class="w-3.5 h-3.5 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 5l7 7-7 7M5 5l7 7-7 7"/></svg>
        Nest as ember
      </div>
    `
    childContainer.appendChild(this._nestDropZone)
  }

  _commitNest() {
    if (!this._nestTarget) return

    const childContainer = this._findChildContainer(this._nestTarget)
    if (!childContainer) return

    // Remove the dropzone indicator first
    if (this._nestDropZone) {
      this._nestDropZone.remove()
      this._nestDropZone = null
    }

    // Detach then re-insert to avoid sibling reference issues
    this._detachDragUnit()
    this._dragUnit.forEach(el => {
      childContainer.appendChild(el)
    })
  }

  _clearNest() {
    this._clearNestTimer()
    if (this._nestTarget) {
      this._nestTarget.classList.remove("channel-nest-target")
      this._nestTarget = null
    }
    if (this._nestDropZone) {
      this._nestDropZone.remove()
      this._nestDropZone = null
    }
    this._nestActivated = false
  }

  _clearNestTimer() {
    if (this._nestTimer) {
      clearTimeout(this._nestTimer)
      this._nestTimer = null
    }
  }

  // ─── Auto-scroll ────────────────────────────────────────────

  _handleAutoScroll(clientY) {
    const rect = this.element.getBoundingClientRect()
    const distFromTop = clientY - rect.top
    const distFromBottom = rect.bottom - clientY

    if (distFromTop < SCROLL_EDGE) {
      const speed = SCROLL_SPEED * (1 - distFromTop / SCROLL_EDGE)
      this._startAutoScroll(-speed)
    } else if (distFromBottom < SCROLL_EDGE) {
      const speed = SCROLL_SPEED * (1 - distFromBottom / SCROLL_EDGE)
      this._startAutoScroll(speed)
    } else {
      this._stopAutoScroll()
    }
  }

  _startAutoScroll(speed) {
    // Already scrolling — just update speed
    this._autoScrollSpeed = speed
    if (this._scrollRAF) return

    const tick = () => {
      this.element.scrollTop += this._autoScrollSpeed
      this._scrollRAF = requestAnimationFrame(tick)
    }
    this._scrollRAF = requestAnimationFrame(tick)
  }

  _stopAutoScroll() {
    if (this._scrollRAF) {
      cancelAnimationFrame(this._scrollRAF)
      this._scrollRAF = null
    }
  }

  // ─── Voice structure repair ─────────────────────────────────

  // After any drop, ensure every voice channel's structural siblings
  // (voice-participants, voice-child-channels) sit directly after its <a> tag.
  // Uses data-attribute lookups so it works even if a prior operation left the
  // DOM out of order.
  _repairVoiceStructure() {
    this.element.querySelectorAll("[data-voice-channel][data-channel-id]").forEach(channelEl => {
      const channelId = channelEl.dataset.channelId
      let insertAfter = channelEl

      const participants = this.element.querySelector(
        `.voice-participants[data-voice-channel-participants="${channelId}"]`
      )
      if (participants) {
        if (participants.previousElementSibling !== insertAfter) {
          insertAfter.after(participants)
        }
        insertAfter = participants
      }

      const childContainer = this.element.querySelector(
        `.voice-child-channels[data-parent-channel="${channelId}"]`
      )
      if (childContainer) {
        if (childContainer.previousElementSibling !== insertAfter) {
          insertAfter.after(childContainer)
        }
      }
    })
  }

  // ─── Depth / hierarchy helpers ─────────────────────────────

  _getChannelDepth(el) {
    let depth = 0
    let parent = el.parentElement
    while (parent) {
      if (parent.classList.contains("voice-child-channels")) depth++
      if (parent === this.element) break
      parent = parent.parentElement
    }
    return depth
  }

  _getSubtreeDepth(el) {
    const childContainer = this._findChildContainer(el)
    if (!childContainer) return 1
    let maxChild = 0
    childContainer.querySelectorAll(":scope > [data-channel-id]").forEach(ch => {
      const d = this._getSubtreeDepth(ch)
      if (d > maxChild) maxChild = d
    })
    return 1 + maxChild
  }

  _findChildContainer(linkEl) {
    const channelId = linkEl.dataset?.channelId
    if (!channelId) return null
    return this.element.querySelector(
      `.voice-child-channels[data-parent-channel="${channelId}"]`
    )
  }

  // Walk up from a nested channel to find the topmost voice channel in the chain
  _findNestRoot(el) {
    let vcc = el.closest(".voice-child-channels")
    if (!vcc) return null
    let rootChannel = null
    while (vcc) {
      const parentId = vcc.dataset.parentChannel
      if (parentId) {
        const parentEl = this.element.querySelector(`[data-channel-id="${parentId}"]`)
        if (parentEl) rootChannel = parentEl
      }
      vcc = vcc.parentElement?.closest(".voice-child-channels") || null
    }
    return rootChannel
  }

  _isDescendantOf(targetEl, draggedId) {
    let container = targetEl.parentElement
    while (container && container !== this.element) {
      if (container.classList.contains("voice-child-channels") &&
          container.dataset.parentChannel === draggedId) {
        return true
      }
      container = container.parentElement
    }
    return false
  }

  // ─── Save order ────────────────────────────────────────────

  async saveOrder() {
    // Flag so the sidebar controller ignores its own broadcast
    window._skipNextSidebarReorder = Date.now()

    const channels = []
    const categories = []

    let catPos = 0
    this.element.querySelectorAll(":scope > [data-category-id]").forEach(catEl => {
      const catId = catEl.dataset.categoryId
      categories.push({ id: catId, position: catPos++ })

      const channelsDiv = catEl.querySelector("[data-category-collapse-target='channels']")
      if (channelsDiv) {
        this._collectChannels(channelsDiv, catId, null, channels)
      }
    })

    this._collectTopLevel(channels)

    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    await fetch(`/servers/${this.serverIdValue}/reorder_channels`, {
      method: "PATCH",
      headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
      body: JSON.stringify({ channels, categories })
    })
  }

  _collectChannels(container, categoryId, parentChannelId, result) {
    let pos = 0
    for (const child of container.children) {
      if (!child.hasAttribute("data-channel-id")) continue

      const channelId = child.dataset.channelId
      result.push({
        id: channelId,
        position: pos++,
        category_id: categoryId,
        parent_channel_id: parentChannelId
      })

      const nested = this._findChildContainer(child)
      if (nested) {
        this._collectChannels(nested, categoryId, channelId, result)
      }
    }
  }

  _collectTopLevel(result) {
    let pos = 0
    for (const child of this.element.children) {
      if (!child.hasAttribute("data-channel-id")) continue

      const channelId = child.dataset.channelId
      result.push({
        id: channelId,
        position: pos++,
        category_id: null,
        parent_channel_id: null
      })

      const nested = this._findChildContainer(child)
      if (nested) {
        this._collectChannels(nested, null, channelId, result)
      }
    }
  }
}
