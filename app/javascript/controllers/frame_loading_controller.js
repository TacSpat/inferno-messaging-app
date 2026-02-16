import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this._onBeforeFetch = this._handleBeforeFetch.bind(this)
    document.addEventListener("turbo:before-fetch-request", this._onBeforeFetch)
  }

  disconnect() {
    document.removeEventListener("turbo:before-fetch-request", this._onBeforeFetch)
  }

  _handleBeforeFetch(e) {
    // Only handle main-content frame navigations
    if (e.target.id !== "main-content") return

    // Only GET requests (navigation), not form submissions
    const method = e.detail?.fetchOptions?.method
    if (method && method.toUpperCase() !== "GET") return

    this._showSkeleton(e.target)
  }

  _showSkeleton(frame) {
    const msgs = Array.from({ length: 6 }, (_, i) => {
      const nameW = ["w-20", "w-28", "w-24", "w-32", "w-20", "w-36"][i]
      const lineW = ["w-64 sm:w-80", "w-48 sm:w-64", "w-56 sm:w-72", "w-40 sm:w-56", "w-72 sm:w-96", "w-44 sm:w-60"][i]
      return `<div class="flex items-start gap-3 px-4">
        <div class="w-10 h-10 bg-gray-600 rounded-full shrink-0"></div>
        <div class="space-y-2 flex-1 min-w-0">
          <div class="flex items-center gap-2">
            <div class="h-3.5 bg-gray-600 rounded ${nameW}"></div>
            <div class="h-3 bg-gray-600/40 rounded w-10"></div>
          </div>
          <div class="h-3.5 bg-gray-600/30 rounded ${lineW} max-w-full"></div>
        </div>
      </div>`
    }).join("")

    frame.innerHTML = `
      <div class="flex flex-col flex-1 min-h-0 animate-pulse">
        <div class="flex items-center h-12 px-4 border-b border-gray-900 shrink-0">
          <div class="w-5 h-5 bg-gray-600 rounded mr-2"></div>
          <div class="h-4 bg-gray-600 rounded w-28"></div>
        </div>
        <div class="flex-1 overflow-hidden flex flex-col justify-end py-4 space-y-5">
          ${msgs}
        </div>
        <div class="px-4 pb-4 pt-2">
          <div class="h-11 bg-gray-600/30 rounded-lg"></div>
        </div>
      </div>`
  }
}
