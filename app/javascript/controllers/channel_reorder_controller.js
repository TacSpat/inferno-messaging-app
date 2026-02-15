import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

export default class extends Controller {
  static values = { serverId: String, canManage: Boolean }

  connect() {
    if (!this.canManageValue) return
    this.sortables = []
    this.setup()
  }

  disconnect() {
    this.sortables.forEach(s => s.destroy())
    this.sortables = []
  }

  setup() {
    const opts = {
      group: "channels",
      animation: 150,
      ghostClass: "opacity-20",
      chosenClass: "bg-gray-600",
      dragClass: "shadow-lg",
      fallbackOnBody: true,
      swapThreshold: 0.65,
      onEnd: () => this.saveOrder()
    }

    // Make the top-level container sortable (uncategorized channels + categories)
    this.sortables.push(
      Sortable.create(this.element, {
        ...opts,
        group: "channels",
        draggable: "[data-channel-id], [data-category-id]",
        // Don't allow dragging categories into channel groups
        onMove: (evt) => {
          // If dragging a category, only allow it at the top level
          if (evt.dragged.hasAttribute("data-category-id")) {
            return evt.to === this.element
          }
          return true
        }
      })
    )

    // Make each category's channel list sortable
    this.element.querySelectorAll("[data-category-collapse-target='channels']").forEach(container => {
      this.sortables.push(
        Sortable.create(container, {
          ...opts,
          group: "channels",
          draggable: "[data-channel-id]"
        })
      )
    })
  }

  async saveOrder() {
    const channels = []
    const categories = []

    let catPos = 0
    this.element.querySelectorAll("[data-category-id]").forEach(catEl => {
      const catId = catEl.dataset.categoryId
      categories.push({ id: catId, position: catPos++ })

      let chPos = 0
      const channelsDiv = catEl.querySelector("[data-category-collapse-target='channels']")
      if (channelsDiv) {
        channelsDiv.querySelectorAll("[data-channel-id]").forEach(chEl => {
          channels.push({ id: chEl.dataset.channelId, position: chPos++, category_id: catId })
        })
      }
    })

    // Uncategorized channels (direct children)
    let uncatPos = 0
    Array.from(this.element.children).forEach(child => {
      if (child.hasAttribute("data-channel-id")) {
        channels.push({ id: child.dataset.channelId, position: uncatPos++, category_id: null })
      }
    })

    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    await fetch(`/servers/${this.serverIdValue}/reorder_channels`, {
      method: "PATCH",
      headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
      body: JSON.stringify({ channels, categories })
    })
  }
}
