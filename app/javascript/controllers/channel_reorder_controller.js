import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

const NEST_HOVER_MS = 600   // hold over a voice channel this long to nest
const MAX_DEPTH = 3          // max hierarchy depth

export default class extends Controller {
  static values = { serverId: String, canManage: Boolean }

  connect() {
    if (!this.canManageValue) return
    this.sortables = []
    this._nestTimer = null
    this._nestTarget = null
    this._nestActivated = false
    this._nestDropZone = null
    this._pendingNestParentId = null
    this._draggedEl = null
    this.setup()
  }

  disconnect() {
    this.sortables.forEach(s => s.destroy())
    this.sortables = []
    this._clearNest()
  }

  setup() {
    const self = this

    const makeOpts = () => ({
      group: "channels",
      animation: 150,
      ghostClass: "opacity-20",
      chosenClass: "sortable-chosen",
      dragClass: "shadow-lg",
      fallbackOnBody: true,
      swapThreshold: 0.65,
      onStart: (evt) => self._onDragStart(evt),
      onEnd: (evt) => self._onDragEnd(evt),
      onMove: (evt) => self._onMove(evt)
    })

    // Top-level container (uncategorized channels + categories)
    this.sortables.push(
      Sortable.create(this.element, {
        ...makeOpts(),
        draggable: "[data-channel-id], [data-category-id]"
      })
    )

    // Each category's channel list
    this.element.querySelectorAll("[data-category-collapse-target='channels']").forEach(container => {
      this.sortables.push(
        Sortable.create(container, {
          ...makeOpts(),
          draggable: "[data-channel-id]"
        })
      )
    })

    // Existing voice-child-channels containers (already nested children)
    this._initChildContainers()
  }

  _initChildContainers() {
    const self = this
    this.element.querySelectorAll(".voice-child-channels").forEach(container => {
      // Don't double-init
      if (container._sortableInit) return
      container._sortableInit = true
      this.sortables.push(
        Sortable.create(container, {
          group: "channels",
          animation: 150,
          ghostClass: "opacity-20",
          chosenClass: "sortable-chosen",
          dragClass: "shadow-lg",
          fallbackOnBody: true,
          swapThreshold: 0.65,
          draggable: "[data-channel-id]",
          onStart: (evt) => self._onDragStart(evt),
          onEnd: (evt) => self._onDragEnd(evt),
          onMove: (evt) => self._onMove(evt)
        })
      )
    })
  }

  // ─── Sortable callbacks ────────────────────────────────────────

  _onDragStart(evt) {
    this._draggedEl = evt.item
  }

  _onDragEnd(evt) {
    // If nesting was activated, commit the nest before saving
    if (this._nestActivated && this._pendingNestParentId) {
      this._commitNest(evt.item)
    }
    this._clearNest()
    this._draggedEl = null
    this.saveOrder()
  }

  // Called by Sortable every time the ghost would move to a new position.
  // evt.dragged = the element, evt.related = the element it's next to,
  // evt.to = the container it would land in.
  _onMove(evt) {
    // Categories can only live at the top level
    if (evt.dragged.hasAttribute("data-category-id")) {
      return evt.to === this.element
    }

    const dragged = evt.dragged
    const related = evt.related

    // Only do nest logic for voice channels
    if (!dragged.hasAttribute("data-voice-channel")) return true

    // If nest is already activated, keep it while ghost is in/near the target zone
    if (this._nestActivated && this._nestTarget) {
      const childContainer = this._findChildContainer(this._nestTarget)
      if (related === this._nestTarget) return true
      if (childContainer && (evt.to === childContainer || childContainer.contains(related))) return true
      // User moved away from the nest zone — cancel
      this._clearNest()
    }

    // If the ghost is near a voice channel, start/continue the nest timer
    if (related && related.hasAttribute("data-voice-channel") &&
        related.hasAttribute("data-channel-id") &&
        related !== dragged) {

      // Same target — timer already running, don't restart
      if (this._nestTarget === related) return true

      // New target — clear old timer and start fresh
      this._clearNest()

      // Validate depth: target depth + dragged subtree depth must stay under MAX_DEPTH
      const targetDepth = this._getChannelDepth(related)
      const draggedSubtreeDepth = this._getSubtreeDepth(dragged)
      if (targetDepth + draggedSubtreeDepth >= MAX_DEPTH) return true

      // Don't nest into own descendant
      if (this._isDescendantOf(related, dragged.dataset.channelId)) return true

      this._nestTarget = related
      this._nestTimer = setTimeout(() => this._activateNest(), NEST_HOVER_MS)
    } else if (!this._nestActivated) {
      // Moved away from a voice channel target — cancel (but don't clear an active nest,
      // that's handled above)
      this._clearNest()
    }

    return true
  }

  // ─── Nest activation ──────────────────────────────────────────

  _activateNest() {
    if (!this._nestTarget) return
    this._nestActivated = true
    this._pendingNestParentId = this._nestTarget.dataset.channelId

    // Highlight the target channel
    this._nestTarget.classList.add("channel-nest-target")

    // Find or create the voice-child-channels container for the target
    let childContainer = this._findChildContainer(this._nestTarget)

    if (!childContainer) {
      childContainer = document.createElement("div")
      childContainer.className = "voice-child-channels"
      // Insert after the target link and any voice-participants
      let insertAfter = this._nestTarget
      let sib = this._nestTarget.nextElementSibling
      while (sib && sib.classList.contains("voice-participants")) {
        insertAfter = sib
        sib = sib.nextElementSibling
      }
      insertAfter.after(childContainer)
    }

    // Add the drop zone indicator inside the child container
    this._nestDropZone = document.createElement("div")
    this._nestDropZone.className = "channel-nest-dropzone"
    this._nestDropZone.dataset.nestDropzone = "true"
    this._nestDropZone.innerHTML = `
      <div class="flex items-center gap-1.5 px-3 py-1.5 rounded border border-dashed border-accent/50 bg-accent/10 text-accent text-xs">
        <svg class="w-3.5 h-3.5 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 5l7 7-7 7M5 5l7 7-7 7"/></svg>
        Nest as ember
      </div>
    `
    childContainer.appendChild(this._nestDropZone)

    // Make sure the container is a Sortable so dropping into it works
    if (!childContainer._sortableInit) {
      childContainer._sortableInit = true
      const self = this
      this.sortables.push(
        Sortable.create(childContainer, {
          group: "channels",
          animation: 150,
          ghostClass: "opacity-20",
          chosenClass: "sortable-chosen",
          dragClass: "shadow-lg",
          fallbackOnBody: true,
          swapThreshold: 0.65,
          draggable: "[data-channel-id]",
          onStart: (evt) => self._onDragStart(evt),
          onEnd: (evt) => self._onDragEnd(evt),
          onMove: (evt) => self._onMove(evt)
        })
      )
    }
  }

  _commitNest(draggedEl) {
    if (!this._nestTarget || !this._pendingNestParentId) return

    // Find the child container (should exist — created in _activateNest)
    const childContainer = this._findChildContainer(this._nestTarget)
    if (!childContainer) return

    // Move the element into the child container
    draggedEl.classList.add("ml-3")
    childContainer.appendChild(draggedEl)
  }

  _clearNest() {
    if (this._nestTimer) {
      clearTimeout(this._nestTimer)
      this._nestTimer = null
    }
    if (this._nestTarget) {
      this._nestTarget.classList.remove("channel-nest-target")
      this._nestTarget = null
    }
    if (this._nestDropZone) {
      this._nestDropZone.remove()
      this._nestDropZone = null
    }
    this._nestActivated = false
    this._pendingNestParentId = null
  }

  // ─── Depth / hierarchy helpers ─────────────────────────────────

  // How deep is this channel element in the nesting tree? (0 = top-level)
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

  // How deep is the subtree under this channel? (1 = leaf, 2 = has children, etc.)
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

  // Find the .voice-child-channels container that immediately follows a channel <a> element
  // (skipping over .voice-participants divs)
  _findChildContainer(linkEl) {
    let sib = linkEl.nextElementSibling
    while (sib) {
      if (sib.classList.contains("voice-child-channels")) return sib
      if (sib.classList.contains("voice-participants")) { sib = sib.nextElementSibling; continue }
      break
    }
    return null
  }

  // Is targetEl nested inside the channel tree rooted at draggedId?
  _isDescendantOf(targetEl, draggedId) {
    // Walk up from targetEl's parent container looking for the dragged channel
    let container = targetEl.parentElement
    while (container && container !== this.element) {
      if (container.classList.contains("voice-child-channels")) {
        // The channel link is a preceding sibling of this container
        let prev = container.previousElementSibling
        while (prev) {
          if (prev.dataset?.channelId === draggedId) return true
          if (prev.classList?.contains("voice-participants")) { prev = prev.previousElementSibling; continue }
          break
        }
      }
      container = container.parentElement
    }
    return false
  }

  // ─── Save order ────────────────────────────────────────────────

  async saveOrder() {
    const channels = []
    const categories = []

    // Collect categories and their channels
    let catPos = 0
    this.element.querySelectorAll(":scope > [data-category-id]").forEach(catEl => {
      const catId = catEl.dataset.categoryId
      categories.push({ id: catId, position: catPos++ })

      const channelsDiv = catEl.querySelector("[data-category-collapse-target='channels']")
      if (channelsDiv) {
        this._collectChannels(channelsDiv, catId, null, channels)
      }
    })

    // Collect uncategorized top-level channels
    this._collectTopLevel(channels)

    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    await fetch(`/servers/${this.serverIdValue}/reorder_channels`, {
      method: "PATCH",
      headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
      body: JSON.stringify({ channels, categories })
    })
  }

  // Collect direct channels of a container, then recurse into voice-child-channels (embers)
  _collectChannels(container, categoryId, parentChannelId, result) {
    let pos = 0
    for (const child of container.children) {
      // Skip non-channel elements (voice-participants, voice-child-channels, dropzones)
      if (!child.hasAttribute("data-channel-id")) continue

      const channelId = child.dataset.channelId
      result.push({
        id: channelId,
        position: pos++,
        category_id: categoryId,
        parent_channel_id: parentChannelId
      })

      // Recurse into nested children
      const nested = this._findChildContainer(child)
      if (nested) {
        this._collectChannels(nested, categoryId, channelId, result)
      }
    }
  }

  // Collect uncategorized channels that are direct children of this.element
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

      // Recurse into nested children
      const nested = this._findChildContainer(child)
      if (nested) {
        this._collectChannels(nested, null, channelId, result)
      }
    }
  }
}
