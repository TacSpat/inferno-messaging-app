import { Controller } from "@hotwired/stimulus"

const NEST_HOVER_MS = 600
const MAX_DEPTH = 3
const DRAG_THRESHOLD = 5
const SCROLL_EDGE = 40
const SCROLL_SPEED = 8
const CATEGORY_EDGE_PX = 6 // px from top of category header to trigger before vs into

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
    this._currentDropMode = null // null | 'before-category' | 'after-category' | 'into-category'

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
    if (this._saveTimer) {
      clearTimeout(this._saveTimer)
      this._flushSaveOrder()
    }
  }

  // ─── Drag units ──────────────────────────────────────────────

  // Returns an array of DOM elements that constitute a single draggable unit.
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
    clone.innerHTML = sourceEl.innerHTML
    clone.style.width = `${sourceEl.offsetWidth}px`
    clone.style.left = `${x + 8}px`
    clone.style.top = `${y - 12}px`

    document.body.appendChild(clone)
    this._ghost = clone
  }

  _performDrop() {
    const isDraggingCategory = this._draggedEl.hasAttribute("data-category-id")

    // Snapshot original position to detect no-op
    const origContainer = this._originalContainer
    const origNextSibling = this._originalNextSibling

    // Snapshot positions for FLIP animation
    const snapshots = this._snapshotPositions()
    const dragUnitCopy = [...this._dragUnit]

    if (this._nestActivated && this._nestTarget) {
      this._commitNest()
    } else if (this._currentDropTarget) {
      const target = this._currentDropTarget
      const before = this._currentDropBefore

      if (isDraggingCategory) {
        this._dropCategory(target, before)
      } else {
        this._dropChannel(target, before)
      }
    }

    // Repair voice structure
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

    // Detect no-op: element ended up in the same spot
    const mainEl = dragUnitCopy[0]
    const lastEl = dragUnitCopy[dragUnitCopy.length - 1]
    const samePosition = mainEl.parentElement === origContainer &&
      lastEl.nextElementSibling === origNextSibling

    this._cleanupDrag()

    if (samePosition) return // No change — skip save, broadcast, and animation

    // FLIP animate moved elements
    this._animateFLIP(snapshots, dragUnitCopy)

    this.saveOrder()

    // Tell the sidebar controller to reinit voice sortables
    this.element.dispatchEvent(new CustomEvent("channel-reorder:done", { bubbles: false }))
  }

  _dropCategory(target, before) {
    // Categories always live at root level
    this._detachDragUnit()

    if (target.hasAttribute("data-category-id")) {
      // Category-to-category or around a category
      const ref = before ? target : target.nextElementSibling
      this.element.insertBefore(this._dragUnit[0], ref)
    } else if (target.hasAttribute("data-channel-id")) {
      // Category dropped relative to a root-level channel
      if (before) {
        this.element.insertBefore(this._dragUnit[0], target)
      } else {
        const targetUnit = this._getDragUnit(target)
        const lastEl = targetUnit[targetUnit.length - 1]
        this.element.insertBefore(this._dragUnit[0], lastEl.nextElementSibling)
      }
    }
  }

  _dropChannel(target, before) {
    if (target.hasAttribute("data-category-id")) {
      if (this._currentDropMode === "before-category") {
        // Drop at root level, above the category
        this._detachDragUnit()
        this._insertDragUnit(this.element, target)
      } else if (this._currentDropMode === "after-category") {
        // Drop at root level, below the category
        this._detachDragUnit()
        this._insertDragUnit(this.element, target.nextElementSibling)
      } else {
        // Drop INTO category (append at bottom)
        const channelsDiv = target.querySelector("[data-category-collapse-target='channels']")
        if (channelsDiv) {
          this._detachDragUnit()
          this._insertDragUnit(channelsDiv, null)
        }
      }
    } else if (target.hasAttribute("data-channel-id")) {
      const container = target.parentElement

      // Only voice channels can live inside voice-child-channels
      if (container.classList.contains("voice-child-channels") &&
          !this._draggedEl.hasAttribute("data-voice-channel")) {
        return
      }

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
    this._currentDropMode = null
    this._originalContainer = null
    this._originalNextSibling = null
  }

  _cleanupListeners() {
    document.removeEventListener("pointermove", this._onPointerMove)
    document.removeEventListener("pointerup", this._onPointerUp)
    document.removeEventListener("keydown", this._onKeyDown)
  }

  // ─── FLIP animation ──────────────────────────────────────────

  _snapshotPositions() {
    const map = new Map()
    const els = this.element.querySelectorAll(
      "[data-channel-id], [data-category-id], .voice-participants, .voice-child-channels"
    )
    els.forEach(el => {
      map.set(el, el.getBoundingClientRect())
    })
    return map
  }

  _animateFLIP(snapshots, dragUnitEls) {
    snapshots.forEach((oldRect, el) => {
      // Skip elements no longer in DOM
      if (!el.isConnected) return
      // Skip the dragged elements (they were just restored to position)
      if (dragUnitEls && dragUnitEls.includes(el)) return

      const newRect = el.getBoundingClientRect()
      const deltaY = oldRect.top - newRect.top
      const deltaX = oldRect.left - newRect.left

      if (Math.abs(deltaY) < 1 && Math.abs(deltaX) < 1) return

      el.style.transform = `translate(${deltaX}px, ${deltaY}px)`
      el.style.transition = "none"

      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          el.style.transition = "transform 200ms ease"
          el.style.transform = ""
          const cleanup = () => {
            el.style.transition = ""
            el.style.transform = ""
          }
          el.addEventListener("transitionend", cleanup, { once: true })
          // Safety timeout in case transitionend doesn't fire
          setTimeout(cleanup, 250)
        })
      })
    })
  }

  // ─── Drop target detection ──────────────────────────────────

  _updateDropTarget(x, y) {
    // If cursor overlaps any drag unit element's rect (with padding), clear target —
    // we're over our own faded item. Padding covers gaps between sidebar items.
    const PAD = 4
    for (const u of this._dragUnit) {
      const r = u.getBoundingClientRect()
      if (x >= r.left && x <= r.right && y >= r.top - PAD && y <= r.bottom + PAD) {
        this._hideDropLine()
        this._clearDropTargetHighlight()
        this._handleNestCandidate(null, x, y)
        this._currentDropTarget = null
        this._currentDropMode = null
        return
      }
    }

    // Hide ghost so elementFromPoint sees through it
    this._ghost.style.display = "none"
    const el = document.elementFromPoint(x, y)
    this._ghost.style.display = ""

    if (!el || !this.element.contains(el)) {
      // Cursor might be below all items but within the sidebar's visible area
      const sidebarRect = this.element.getBoundingClientRect()
      if (x >= sidebarRect.left && x <= sidebarRect.right &&
          y >= sidebarRect.top && y <= sidebarRect.bottom) {
        const nearest = this._findNearestRootItem(y)
        if (nearest) {
          const { item, before } = nearest
          this._applyNearestRootDrop(item, before, x, y)
          return
        }
      }
      this._hideDropLine()
      this._clearDropTargetHighlight()
      this._handleNestCandidate(null, x, y)
      this._currentDropTarget = null
      this._currentDropMode = null
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
        return // Inside the active nest container
      }
    }

    // If inside a category channels div but not on a specific channel
    if (!target) {
      const channelsDiv = el.closest("[data-category-collapse-target='channels']")
      if (channelsDiv && !isDraggingCategory) {
        const catEl = channelsDiv.closest("[data-category-id]")
        if (catEl && catEl !== this._draggedEl) {
          this._highlightCategory(catEl)
          this._currentDropTarget = catEl
          this._currentDropBefore = false
          this._currentDropMode = "into-category"
          this._positionDropLineInsideContainer(channelsDiv)
          this._handleNestCandidate(null, x, y)
          return
        }
      }
    }

    if (!target) {
      // Cursor is on empty sidebar space — find nearest root item and place relative to it
      const nearest = this._findNearestRootItem(y)
      if (nearest) {
        const { item, before } = nearest
        this._applyNearestRootDrop(item, before, x, y)
      } else {
        this._hideDropLine()
        this._clearDropTargetHighlight()
        this._handleNestCandidate(null, x, y)
        this._currentDropTarget = null
        this._currentDropMode = null
      }
      return
    }

    // Skip if target is the dragged element itself or part of the drag unit
    if (target === this._draggedEl || this._dragUnit.includes(target) ||
        this._dragUnit.some(u => u.contains(target))) {
      return
    }

    // ── Category dragging ──
    if (isDraggingCategory) {
      // If hovering over a channel inside a category, redirect to the category
      if (target.hasAttribute("data-channel-id")) {
        const parentCat = target.closest("[data-category-id]")
        if (parentCat && parentCat !== this._draggedEl) {
          target = parentCat
        } else if (parentCat) {
          return // Inside our own category
        }
        // else: root-level channel, allow
      }

      // Must be at root level
      if (target.parentElement !== this.element &&
          !target.closest("[data-category-id]")?.parentElement === this.element) return

      // For root-level targets, determine before/after
      const rect = target.getBoundingClientRect()
      const midY = rect.top + rect.height / 2
      const before = y < midY

      this._currentDropTarget = target
      this._currentDropBefore = before
      this._currentDropMode = null
      this._clearDropTargetHighlight()
      this._positionDropLine(target, before)
      this._handleNestCandidate(null, x, y)
      return
    }

    // ── Channel dragging ──

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

    // Hovering over a category header
    if (target.hasAttribute("data-category-id")) {
      const header = target.querySelector(":scope > div:first-child")
      if (header) {
        if (isDraggingCategory) {
          // Category-to-category: two-zone (before / after)
          const headerRect = header.getBoundingClientRect()
          const midY = headerRect.top + headerRect.height / 2
          const catBefore = y < midY
          this._clearDropTargetHighlight()
          this._currentDropTarget = target
          this._currentDropBefore = catBefore
          this._currentDropMode = catBefore ? "before-category" : "after-category"
          this._positionDropLineAtCategoryEdge(target, catBefore)
          this._handleNestCandidate(null, x, y)
          return
        } else {
          // Channel dragging: top edge of header → place at root before category
          const headerRect = header.getBoundingClientRect()
          const topZone = headerRect.top + CATEGORY_EDGE_PX
          if (y < topZone) {
            this._clearDropTargetHighlight()
            this._currentDropTarget = target
            this._currentDropBefore = true
            this._currentDropMode = "before-category"
            this._positionDropLineAtCategoryEdge(target, true)
            this._handleNestCandidate(null, x, y)
            return
          }
          // Rest of header → drop INTO category at bottom
          this._highlightCategory(target)
          this._currentDropTarget = target
          this._currentDropBefore = false
          this._currentDropMode = "into-category"
          const channelsDiv = target.querySelector("[data-category-collapse-target='channels']")
          if (channelsDiv) {
            this._positionDropLineInsideContainer(channelsDiv)
          } else {
            this._positionDropLineAtCategoryEdge(target, false)
          }
          this._handleNestCandidate(null, x, y)
          return
        }
      }
    }

    // Determine before/after based on cursor Y vs midpoint
    const rect = target.getBoundingClientRect()
    const midY = rect.top + rect.height / 2
    const before = y < midY

    // If dragging a channel over a channel inside a category, check if we're at
    // the category boundary — allow escaping to root level
    if (!isDraggingCategory && target.hasAttribute("data-channel-id")) {
      const catChannelsDiv = target.closest("[data-category-collapse-target='channels']")
      if (catChannelsDiv) {
        const catEl = catChannelsDiv.closest("[data-category-id]")
        if (catEl) {
          // Get visible (non-drag-unit) channels in this category
          const siblingChannels = [...catChannelsDiv.querySelectorAll(":scope > [data-channel-id]")]
            .filter(el => !this._dragUnit.includes(el))
          const isFirst = siblingChannels[0] === target
          const isLast = siblingChannels[siblingChannels.length - 1] === target

          // After the last channel → escape below category
          if (!before && isLast) {
            this._clearDropTargetHighlight()
            this._currentDropTarget = catEl
            this._currentDropBefore = false
            this._currentDropMode = "after-category"
            this._positionDropLineAtCategoryEdge(catEl, false)
            this._handleNestCandidate(null, x, y)
            return
          }
        }
      }
    }

    this._currentDropTarget = target
    this._currentDropBefore = before
    this._currentDropMode = null

    // Show category bounding box if target is inside a category
    const targetCatDiv = target.closest?.("[data-category-id]")
    if (targetCatDiv && !isDraggingCategory) {
      this._highlightCategory(targetCatDiv)
    } else {
      this._clearDropTargetHighlight()
    }

    // Position the drop indicator line
    this._positionDropLine(target, before)

    // Handle nest candidate (voice-to-voice) — only in center zone of target
    if (isDraggingVoice && target.hasAttribute("data-voice-channel") &&
        target.hasAttribute("data-channel-id")) {
      const tRect = target.getBoundingClientRect()
      const edgeZone = Math.max(tRect.height * 0.3, 8)
      const inCenter = y > tRect.top + edgeZone && y < tRect.bottom - edgeZone
      this._handleNestCandidate(inCenter ? target : null, x, y)
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

    // If line was hidden, jump to position instantly and play spawn animation
    const wasHidden = this._dropLine.style.display === "none"
    if (wasHidden) {
      this._dropLine.style.transition = "none"
      this._dropLine.style.top = `${top - 1}px`
      this._dropLine.style.display = ""
      this._dropLine.classList.remove("spawn")
      this._dropLine.offsetHeight
      this._dropLine.classList.add("spawn")
      this._dropLine.style.transition = ""
    } else {
      this._dropLine.style.top = `${top - 1}px`
    }

    // Indent the line if target is inside a nested container
    const inNest = targetEl.closest(".voice-child-channels")
    if (inNest) {
      this._dropLine.style.left = "34px"
    } else {
      this._dropLine.style.left = "8px"
    }
  }

  _positionDropLineAtCategoryEdge(catEl, before) {
    if (!this._dropLine) return

    const containerRect = this.element.getBoundingClientRect()
    const catRect = catEl.getBoundingClientRect()
    const lineY = before ? catRect.top : catRect.bottom
    const top = lineY - containerRect.top + this.element.scrollTop

    const wasHidden = this._dropLine.style.display === "none"
    if (wasHidden) {
      this._dropLine.style.transition = "none"
      this._dropLine.style.top = `${top - 1}px`
      this._dropLine.style.left = "8px"
      this._dropLine.style.display = ""
      this._dropLine.classList.remove("spawn")
      this._dropLine.offsetHeight
      this._dropLine.classList.add("spawn")
      this._dropLine.style.transition = ""
    } else {
      this._dropLine.style.top = `${top - 1}px`
      this._dropLine.style.left = "8px"
    }
  }

  _positionDropLineInsideContainer(containerEl) {
    if (!this._dropLine) return

    const scrollRect = this.element.getBoundingClientRect()
    const containerRect = containerEl.getBoundingClientRect()

    // Position at the bottom of the container's content
    const lastChild = containerEl.lastElementChild
    let lineY
    if (lastChild) {
      // After the last visible child (skip drag unit elements)
      const children = [...containerEl.children].filter(el => !this._dragUnit.includes(el))
      const last = children[children.length - 1]
      if (last) {
        const lastUnit = this._getDragUnit(last)
        const lastUnitEl = lastUnit[lastUnit.length - 1]
        lineY = lastUnitEl.getBoundingClientRect().bottom
      } else {
        lineY = containerRect.top
      }
    } else {
      lineY = containerRect.top
    }

    const top = lineY - scrollRect.top + this.element.scrollTop

    const wasHidden = this._dropLine.style.display === "none"
    if (wasHidden) {
      this._dropLine.style.transition = "none"
      this._dropLine.style.top = `${top - 1}px`
      this._dropLine.style.left = "8px"
      this._dropLine.style.display = ""
      this._dropLine.classList.remove("spawn")
      this._dropLine.offsetHeight
      this._dropLine.classList.add("spawn")
      this._dropLine.style.transition = ""
    } else {
      this._dropLine.style.top = `${top - 1}px`
      this._dropLine.style.left = "8px"
    }
  }

  _positionDropLineAtContainerTop(containerEl) {
    if (!this._dropLine) return

    const scrollRect = this.element.getBoundingClientRect()
    const children = [...containerEl.children].filter(el => !this._dragUnit.includes(el))
    const first = children[0]
    const lineY = first ? first.getBoundingClientRect().top : containerEl.getBoundingClientRect().top

    const top = lineY - scrollRect.top + this.element.scrollTop

    const wasHidden = this._dropLine.style.display === "none"
    if (wasHidden) {
      this._dropLine.style.transition = "none"
      this._dropLine.style.top = `${top - 1}px`
      this._dropLine.style.left = "8px"
      this._dropLine.style.display = ""
      this._dropLine.classList.remove("spawn")
      this._dropLine.offsetHeight
      this._dropLine.classList.add("spawn")
      this._dropLine.style.transition = ""
    } else {
      this._dropLine.style.top = `${top - 1}px`
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

  _highlightCategory(catEl) {
    if (this._highlightedCategory === catEl) return
    this._clearDropTargetHighlight()
    catEl.classList.add("channel-drop-target")
    this._highlightedCategory = catEl
  }

  _findLastRootItem() {
    const children = [...this.element.children].filter(el =>
      (el.hasAttribute("data-channel-id") || el.hasAttribute("data-category-id")) &&
      !this._dragUnit.includes(el)
    )
    return children[children.length - 1] || null
  }

  _findNearestRootItem(cursorY) {
    const children = [...this.element.children].filter(el =>
      (el.hasAttribute("data-channel-id") || el.hasAttribute("data-category-id")) &&
      !this._dragUnit.includes(el)
    )
    if (!children.length) return null

    // Find the item whose edge is closest to the cursor
    let bestItem = null
    let bestDist = Infinity
    let bestBefore = false

    for (const child of children) {
      const rect = child.getBoundingClientRect()
      const distTop = Math.abs(cursorY - rect.top)
      const distBottom = Math.abs(cursorY - rect.bottom)

      if (distTop < bestDist) {
        bestDist = distTop
        bestItem = child
        bestBefore = true
      }
      if (distBottom < bestDist) {
        bestDist = distBottom
        bestItem = child
        bestBefore = false
      }
    }

    return bestItem ? { item: bestItem, before: bestBefore } : null
  }

  _applyNearestRootDrop(item, before, x, y) {
    const isDraggingCategory = this._draggedEl.hasAttribute("data-category-id")

    // When dragging a channel and nearest is a category with before=true,
    // redirect to "into-category" (append at bottom) — channels belong inside categories
    // Channel in empty space above a category → place at root level before it
    // (not into-category, since the cursor is clearly in the gap above)

    this._currentDropTarget = item
    this._currentDropBefore = before
    this._clearDropTargetHighlight()
    if (item.hasAttribute("data-category-id")) {
      this._currentDropMode = before ? "before-category" : "after-category"
      this._positionDropLineAtCategoryEdge(item, before)
    } else {
      this._currentDropMode = null
      this._positionDropLine(item, before)
    }
    this._handleNestCandidate(null, x, y)
  }

  // ─── Nest logic (hold-to-nest voice channels) ───────────────

  _handleNestCandidate(target, x, y) {
    // If nest is already activated and we're still near the target, keep it
    if (this._nestActivated && this._nestTarget) {
      if (target === this._nestTarget) return
      const childContainer = this._findChildContainer(this._nestTarget)
      if (childContainer) {
        const ccRect = childContainer.getBoundingClientRect()
        if (x >= ccRect.left && x <= ccRect.right && y >= ccRect.top && y <= ccRect.bottom) {
          return
        }
      }
      this._clearNest()
      return
    }

    if (this._nestTarget !== target) {
      this._clearNestTimer()
    }

    if (!target) {
      this._clearNestTimer()
      return
    }

    if (this._nestTarget === target && this._nestTimer) return

    if (!target.hasAttribute("data-voice-channel")) return
    if (target === this._draggedEl) return
    if (this._isDescendantOf(target, this._draggedEl.dataset.channelId)) return

    const targetDepth = this._getChannelDepth(target)
    const draggedSubtreeDepth = this._getSubtreeDepth(this._draggedEl)
    if (targetDepth + draggedSubtreeDepth >= MAX_DEPTH) return

    this._nestTarget = target
    this._nestTimer = setTimeout(() => this._activateNest(), NEST_HOVER_MS)
  }

  _activateNest() {
    if (!this._nestTarget) return
    this._nestActivated = true

    this._hideDropLine()

    this._nestTarget.classList.add("channel-nest-target")

    let childContainer = this._findChildContainer(this._nestTarget)

    if (!childContainer) {
      childContainer = document.createElement("div")
      childContainer.className = "voice-child-channels"
      const nestId = this._nestTarget.dataset.channelId
      childContainer.dataset.parentChannel = nestId
      const participants = this.element.querySelector(
        `.voice-participants[data-voice-channel-participants="${nestId}"]`
      )
      const insertAfter = participants || this._nestTarget
      insertAfter.after(childContainer)
    }

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

    if (this._nestDropZone) {
      this._nestDropZone.remove()
      this._nestDropZone = null
    }

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

  // ─── Save order (debounced) ─────────────────────────────────

  saveOrder() {
    // Debounce: if multiple reorders happen quickly, only send the final state
    if (this._saveTimer) clearTimeout(this._saveTimer)

    // Keep the skip flag fresh so broadcasts during the debounce window are ignored
    window._skipNextSidebarReorder = Date.now()

    this._saveTimer = setTimeout(() => {
      this._saveTimer = null
      this._flushSaveOrder()
    }, 800)
  }

  async _flushSaveOrder() {
    window._skipNextSidebarReorder = Date.now()

    const channels = []
    const categories = []

    // Walk root children in DOM order to assign unified root_position
    let rootPos = 0
    for (const child of this.element.children) {
      if (child.hasAttribute("data-category-id")) {
        const catId = child.dataset.categoryId
        categories.push({ id: catId, position: rootPos++ })

        const channelsDiv = child.querySelector("[data-category-collapse-target='channels']")
        if (channelsDiv) {
          this._collectChannels(channelsDiv, catId, null, channels)
        }
      } else if (child.hasAttribute("data-channel-id")) {
        const channelId = child.dataset.channelId
        channels.push({
          id: channelId,
          position: rootPos++,
          category_id: null,
          parent_channel_id: null
        })

        const nested = this._findChildContainer(child)
        if (nested) {
          this._collectChannels(nested, null, channelId, channels)
        }
      }
    }

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
}
