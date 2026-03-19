// Shared server discovery logic — fetches discoverable servers from relays
// Used by add_server_modal_controller (modal) and server_discover_controller (full page)

let cachedServers = null
let cacheTime = 0
const CACHE_TTL = 60000

export async function fetchDiscoverServers(listEl) {
  const now = Date.now()
  if (cachedServers && (now - cacheTime) < CACHE_TTL) {
    renderDiscoverList(listEl, cachedServers)
    return
  }

  listEl.innerHTML = spinnerHTML()

  try {
    const res = await fetch("/discover_servers", {
      headers: { "Accept": "application/json" },
      credentials: "same-origin"
    })
    if (!res.ok) throw new Error(`Fetch failed: ${res.status}`)
    const servers = await res.json()
    cachedServers = servers
    cacheTime = Date.now()
    renderDiscoverList(listEl, servers)
  } catch (err) {
    console.error("[server-discover]", err)
    listEl.innerHTML = emptyHTML("Could not reach relays")
  }
}

export function renderDiscoverList(listEl, servers) {
  if (!servers.length) {
    listEl.innerHTML = emptyHTML("No servers found on your relays")
    return
  }

  listEl.innerHTML = servers.map(s => cardHTML(s)).join("")

  listEl.querySelectorAll("[data-nostr-group-id]").forEach(card => {
    card.addEventListener("click", () => {
      const gid = card.dataset.nostrGroupId
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
    })
  })
}

function cardHTML(server) {
  const letter = (server.name || "?")[0].toUpperCase()
  const icon = server.icon_url
    ? `<img src="${escAttr(server.icon_url)}" class="w-9 h-9 rounded-lg object-cover shrink-0" loading="lazy">`
    : `<div class="w-9 h-9 rounded-lg bg-gray-700 flex items-center justify-center text-sm font-bold text-white shrink-0">${esc(letter)}</div>`

  const desc = server.description
    ? `<p class="text-[11px] text-gray-500 truncate">${esc(server.description)}</p>`
    : ""

  const badge = server.age_restricted
    ? `<span class="text-[9px] bg-red-500/20 text-red-400 px-1 rounded font-semibold">18+</span>`
    : ""

  return `<div class="flex items-center gap-2.5 px-2.5 py-2 rounded-lg hover:bg-gray-700/50 transition cursor-pointer group"
               data-nostr-group-id="${escAttr(server.nostr_group_id)}">
            ${icon}
            <div class="flex-1 min-w-0">
              <p class="text-sm text-white font-medium truncate">${esc(server.name || "Unknown Server")} ${badge}</p>
              ${desc}
            </div>
            <svg class="w-4 h-4 text-gray-600 group-hover:text-accent-light transition shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7"/></svg>
          </div>`
}

function spinnerHTML() {
  return `<div class="text-center py-4">
            <svg class="w-5 h-5 text-gray-400 animate-spin mx-auto" fill="none" viewBox="0 0 24 24">
              <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
              <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path>
            </svg>
            <p class="text-xs text-gray-500 mt-2">Searching relays...</p>
          </div>`
}

function emptyHTML(msg) {
  return `<div class="text-center py-6">
            <svg class="w-10 h-10 text-gray-600 mx-auto mb-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"/>
            </svg>
            <p class="text-sm text-gray-500">${esc(msg)}</p>
            <p class="text-xs text-gray-600 mt-1">Servers will appear here as they're discovered on your relays</p>
          </div>`
}

function esc(str) {
  const el = document.createElement("span")
  el.textContent = str || ""
  return el.innerHTML
}

function escAttr(str) {
  return (str || "").replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}
