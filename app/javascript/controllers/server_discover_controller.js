import { Controller } from "@hotwired/stimulus"

// Cache relay results for 60 seconds to avoid re-fetching on every modal open
let cachedServers = null
let cacheTime = 0
const CACHE_TTL = 60000

export default class extends Controller {
  static targets = ["list"]

  connect() {
    this.fetchServers()
  }

  async fetchServers() {
    const now = Date.now()
    if (cachedServers && (now - cacheTime) < CACHE_TTL) {
      this.render(cachedServers)
      return
    }

    this.listTarget.innerHTML = this.spinnerHTML()

    try {
      const res = await fetch("/discover_servers", {
        headers: { "Accept": "application/json" }
      })
      if (!res.ok) throw new Error("Failed to fetch")
      const servers = await res.json()
      cachedServers = servers
      cacheTime = Date.now()
      this.render(servers)
    } catch {
      this.listTarget.innerHTML = this.emptyHTML("Could not reach relays")
    }
  }

  render(servers) {
    if (!servers.length) {
      this.listTarget.innerHTML = this.emptyHTML("No servers found on your relays")
      return
    }

    this.listTarget.innerHTML = servers.map(s => this.cardHTML(s)).join("")
  }

  join(e) {
    const gid = e.currentTarget.dataset.nostrGroupId
    if (!gid) return

    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    const form = document.createElement("form")
    form.method = "POST"
    form.action = `/inferno/server/${gid}/join`
    if (csrf) {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "authenticity_token"
      input.value = csrf
      form.appendChild(input)
    }
    document.body.appendChild(form)
    form.submit()
  }

  cardHTML(server) {
    const letter = (server.name || "?")[0].toUpperCase()
    const icon = server.icon_url
      ? `<img src="${this.escAttr(server.icon_url)}" class="w-9 h-9 rounded-lg object-cover shrink-0" loading="lazy">`
      : `<div class="w-9 h-9 rounded-lg bg-gray-700 flex items-center justify-center text-sm font-bold text-white shrink-0">${this.esc(letter)}</div>`

    const desc = server.description
      ? `<p class="text-[11px] text-gray-500 truncate">${this.esc(server.description)}</p>`
      : ""

    const badge = server.age_restricted
      ? `<span class="text-[9px] bg-red-500/20 text-red-400 px-1 rounded font-semibold">18+</span>`
      : ""

    return `<div class="flex items-center gap-2.5 px-2.5 py-2 rounded-lg hover:bg-gray-700/50 transition cursor-pointer group"
                 data-action="click->server-discover#join"
                 data-nostr-group-id="${this.escAttr(server.nostr_group_id)}">
              ${icon}
              <div class="flex-1 min-w-0">
                <p class="text-sm text-white font-medium truncate">${this.esc(server.name || "Unknown Server")} ${badge}</p>
                ${desc}
              </div>
              <svg class="w-4 h-4 text-gray-600 group-hover:text-accent-light transition shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7"/></svg>
            </div>`
  }

  spinnerHTML() {
    return `<div class="text-center py-4">
              <svg class="w-5 h-5 text-gray-400 animate-spin mx-auto" fill="none" viewBox="0 0 24 24">
                <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path>
              </svg>
              <p class="text-xs text-gray-500 mt-2">Searching relays...</p>
            </div>`
  }

  emptyHTML(msg) {
    return `<div class="text-center py-6">
              <svg class="w-10 h-10 text-gray-600 mx-auto mb-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"/>
              </svg>
              <p class="text-sm text-gray-500">${this.esc(msg)}</p>
              <p class="text-xs text-gray-600 mt-1">Servers will appear here as they're discovered on your relays</p>
            </div>`
  }

  esc(str) {
    const el = document.createElement("span")
    el.textContent = str || ""
    return el.innerHTML
  }

  escAttr(str) {
    return (str || "").replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }
}
