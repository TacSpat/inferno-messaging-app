import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "list", "empty", "suggestions"]

  add() {
    const url = this.inputTarget.value.trim()
    if (!url || !url.match(/^https?:\/\/.+/)) return
    if (this._urls().includes(url.toLowerCase())) { this.inputTarget.value = ""; return }

    this.listTarget.insertAdjacentHTML("beforeend", this._rowHTML(url))
    this.inputTarget.value = ""
    this._refresh()
    this._hideSuggestion(url)
  }

  addSuggestion(e) {
    const url = e.params.url
    if (this._urls().includes(url.toLowerCase())) return
    this.listTarget.insertAdjacentHTML("beforeend", this._rowHTML(url))
    e.currentTarget.style.display = "none"
    this._refresh()
  }

  remove(e) {
    const row = e.currentTarget.closest("[data-blossom-row]")
    const url = row.querySelector('input[name="blossom_server_urls[]"]').value
    row.remove()
    this._refresh()
    this._showSuggestion(url)
  }

  moveUp(e) {
    const row = e.currentTarget.closest("[data-blossom-row]")
    const prev = row.previousElementSibling
    if (prev) this.listTarget.insertBefore(row, prev)
    this._refresh()
  }

  // --- private ---

  _urls() {
    return Array.from(this.listTarget.querySelectorAll('input[name="blossom_server_urls[]"]')).map(i => i.value.toLowerCase())
  }

  _rows() {
    return this.listTarget.querySelectorAll("[data-blossom-row]")
  }

  _refresh() {
    this._rows().forEach((row, i) => {
      const label = row.querySelector("[data-blossom-label]")
      if (label) label.textContent = i === 0 ? "Primary — uploads go here first" : "Fallback"
      const moveBtn = row.querySelector("[data-blossom-move-up]")
      if (moveBtn) moveBtn.classList.toggle("hidden", i === 0)
    })
    if (this.hasEmptyTarget) {
      this.emptyTarget.classList.toggle("hidden", this._rows().length > 0)
    }
  }

  _hideSuggestion(url) {
    if (!this.hasSuggestionsTarget) return
    const short = url.replace("https://", "")
    this.suggestionsTarget.querySelectorAll("button").forEach(btn => {
      if (btn.textContent.trim().includes(short)) btn.style.display = "none"
    })
  }

  _showSuggestion(url) {
    if (!this.hasSuggestionsTarget) return
    const short = url.replace("https://", "")
    this.suggestionsTarget.querySelectorAll("button").forEach(btn => {
      if (btn.textContent.trim().includes(short)) btn.style.display = ""
    })
  }

  _rowHTML(url) {
    return `
    <div class="bg-gray-800 rounded-lg p-3 flex items-center gap-3 group" data-blossom-row>
      <div class="w-8 h-8 rounded-full flex items-center justify-center shrink-0 bg-accent/15">
        <svg class="w-4 h-4 text-accent" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12"/></svg>
      </div>
      <div class="flex-1 min-w-0">
        <p class="text-sm font-medium text-white font-mono truncate">${url}</p>
        <p class="text-xs text-gray-500" data-blossom-label>Fallback</p>
      </div>
      <input type="hidden" name="blossom_server_urls[]" value="${url}">
      <div class="flex items-center gap-1 shrink-0 opacity-0 group-hover:opacity-100 transition-opacity">
        <button type="button" data-blossom-move-up data-action="click->blossom-servers#moveUp" class="p-1.5 text-gray-400 hover:text-white rounded hover:bg-gray-700 transition cursor-pointer" title="Move up">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 15l7-7 7 7"/></svg>
        </button>
        <button type="button" data-action="click->blossom-servers#remove" class="p-1.5 text-gray-400 hover:text-red-400 rounded hover:bg-gray-700 transition cursor-pointer" title="Remove">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/></svg>
        </button>
      </div>
    </div>`
  }
}
