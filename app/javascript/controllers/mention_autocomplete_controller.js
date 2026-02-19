import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { serverId: String }
  static targets = ["input", "popup"]

  connect() {
    this.selectedIndex = 0
    this.results = []
    this.mentionStart = -1
  }

  onInput(event) {
    const input = this.inputTarget
    const value = input.value
    const cursor = input.selectionStart

    // Find @ before cursor
    const beforeCursor = value.substring(0, cursor)
    const atIndex = beforeCursor.lastIndexOf("@")

    if (atIndex === -1 || (atIndex > 0 && beforeCursor[atIndex - 1] !== " " && beforeCursor[atIndex - 1] !== "\n")) {
      this.hidePopup()
      return
    }

    const query = beforeCursor.substring(atIndex + 1)
    if (query.includes(" ") || query.length > 20) {
      this.hidePopup()
      return
    }

    this.mentionStart = atIndex
    this.fetchResults(query)
  }

  async fetchResults(query) {
    if (!this.serverIdValue) return
    const response = await fetch(`/servers/${this.serverIdValue}/mentions?q=${encodeURIComponent(query)}`)
    if (!response.ok) return
    this.results = await response.json()
    this.selectedIndex = 0
    this.renderPopup()
  }

  renderPopup() {
    if (this.results.length === 0) {
      this.hidePopup()
      return
    }

    let html = this.results.map((r, i) => {
      const selected = i === this.selectedIndex ? "bg-gray-600" : ""
      let icon = ""
      let detail = ""
      if (r.type === "user") {
        icon = `<div class="w-6 h-6 rounded-full bg-red-600 flex items-center justify-center text-xs font-bold text-white shrink-0">${r.name[0].toUpperCase()}</div>`
        detail = `<span class="text-xs text-gray-500">#${r.discriminator}</span>`
      } else if (r.type === "role") {
        const color = r.color || "#99aab5"
        icon = `<div class="w-6 h-6 rounded-full flex items-center justify-center shrink-0" style="background:${color}30;border:2px solid ${color}"><span class="text-xs" style="color:${color}">R</span></div>`
      } else {
        icon = `<div class="w-6 h-6 rounded-full bg-yellow-600 flex items-center justify-center text-xs font-bold text-white shrink-0">@</div>`
        detail = `<span class="text-xs text-gray-500">${r.description || ""}</span>`
      }
      return `<div class="flex items-center gap-2 px-3 py-1.5 cursor-pointer hover:bg-gray-600 rounded ${selected}" data-index="${i}" data-action="click->mention-autocomplete#selectResult mouseenter->mention-autocomplete#hoverResult">
        ${icon}
        <span class="text-sm text-white font-medium">${r.display}</span>
        ${detail}
      </div>`
    }).join("")

    this.popupTarget.innerHTML = html
    this.popupTarget.classList.remove("hidden")
  }

  hidePopup() {
    this.popupTarget.classList.add("hidden")
    this.results = []
    this.mentionStart = -1
  }

  onKeydown(event) {
    if (this.results.length === 0) return

    if (event.key === "ArrowDown") {
      event.preventDefault()
      this.selectedIndex = (this.selectedIndex + 1) % this.results.length
      this.renderPopup()
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      this.selectedIndex = (this.selectedIndex - 1 + this.results.length) % this.results.length
      this.renderPopup()
    } else if (event.key === "Enter" || event.key === "Tab") {
      if (this.results.length > 0 && this.mentionStart >= 0) {
        event.preventDefault()
        event.stopPropagation()
        this.insertMention(this.results[this.selectedIndex])
      }
    } else if (event.key === "Escape") {
      this.hidePopup()
    }
  }

  selectResult(event) {
    const index = parseInt(event.currentTarget.dataset.index)
    this.insertMention(this.results[index])
  }

  hoverResult(event) {
    this.selectedIndex = parseInt(event.currentTarget.dataset.index)
    this.renderPopup()
  }

  insertMention(result) {
    const input = this.inputTarget
    const value = input.value
    const cursor = input.selectionStart
    const before = value.substring(0, this.mentionStart)
    const after = value.substring(cursor)
    const mention = `@${result.name} `
    input.value = before + mention + after
    input.selectionStart = input.selectionEnd = before.length + mention.length
    input.focus()
    this.hidePopup()
    // Trigger input event so highlight overlay updates
    input.dispatchEvent(new Event("input", { bubbles: true }))
  }
}
