import { Controller } from "@hotwired/stimulus"

// Intercepts clicks on remote instance links.
// Pre-checks instance reachability, warns about active voice calls,
// syncs federation data, then navigates — or shows errors and stays put.
export default class extends Controller {
  static values = { url: String }

  async navigate(event) {
    event.preventDefault()
    const targetUrl = this.urlValue || this.element.href
    if (!targetUrl) return

    const switchingInstance = this._isDifferentInstance(targetUrl)

    // 1. Pre-check: is the target instance reachable?
    if (switchingInstance) {
      this.showOverlay("Connecting to instance", "Checking availability...")
      const reachable = await this._checkInstanceReachable(targetUrl)
      if (!reachable) {
        this.hideOverlay()
        const domain = this._extractDomain(targetUrl)

        // If user previously chose "don't show again", just show a toast
        if (this._isOfflineDismissed(domain)) {
          this.showError(`${domain} is currently offline. Try again later.`)
          return
        }

        // Otherwise show the full modal with remove / acknowledge options
        const result = await this._showOfflineModal(domain)
        if (result === "remove") this.removeStaleReference()
        return
      }
    }

    // 2. Voice call warning — calls can't persist across instances
    if (switchingInstance && this._isInVoiceCall()) {
      this.hideOverlay()
      const proceed = await this._confirmVoiceDisconnect()
      if (!proceed) return
      // Disconnect voice before navigating
      window.dispatchEvent(new CustomEvent("voice:disconnect"))
      await new Promise(r => setTimeout(r, 300))
    }

    // 3. Sync federation data
    this.showOverlay("Syncing instance data", "Fetching latest profile, servers, and collections...")

    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch("/api/federation_sync", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({ target_url: targetUrl })
      })

      if (response.ok) {
        const data = await response.json()

        // If home instance is unreachable, the user was likely deleted there
        if (data.status === "home_unreachable") {
          this.removeStaleReference()
          this.hideOverlay()
          this.showError("That server is no longer reachable — your account may have been removed from that instance.")
          return
        }

        this.updateOverlayStatus(data.synced || [])
        await new Promise(r => setTimeout(r, 400))
      }
    } catch (e) {
      console.warn("Instance sync failed:", e)
    }

    // 4. Navigate
    window.location.href = targetUrl
  }

  // --- Instance & voice helpers ---

  _isDifferentInstance(targetUrl) {
    try {
      return new URL(targetUrl).host !== window.location.host
    } catch {
      return true
    }
  }

  _extractDomain(url) {
    try { return new URL(url).host } catch { return null }
  }

  _isInVoiceCall() {
    const bar = document.getElementById("voice-controls-bar")
    return bar && !bar.classList.contains("hidden")
  }

  async _checkInstanceReachable(url) {
    try {
      const ac = new AbortController()
      const timeout = setTimeout(() => ac.abort(), 5000)
      await fetch(url, { method: "HEAD", mode: "no-cors", signal: ac.signal })
      clearTimeout(timeout)
      return true
    } catch {
      return false
    }
  }

  _confirmVoiceDisconnect() {
    return new Promise((resolve) => {
      const tpl = document.getElementById("tpl-confirm-modal")
      if (!tpl) { resolve(true); return }

      const backdrop = document.createElement("div")
      backdrop.className = "modal-overlay fixed inset-0 z-[9999] bg-black/70 flex items-center justify-center backdrop-blur-sm"

      const content = tpl.content.cloneNode(true)
      content.querySelector('[data-slot="title"]').textContent = "Disconnect from Voice?"
      content.querySelector('[data-slot="message"]').textContent =
        "You\u2019re currently in a voice call. Switching to a different instance will disconnect you. Voice calls cannot be maintained across instances."

      const cancelBtn = content.querySelector('[data-slot="cancel"]')
      const confirmBtn = content.querySelector('[data-slot="confirm"]')
      confirmBtn.textContent = "Disconnect & Switch"
      confirmBtn.className = "px-4 py-2 text-sm font-medium text-white rounded cursor-pointer bg-red-600 hover:bg-red-500"

      const cleanup = (result) => { backdrop.remove(); resolve(result) }
      cancelBtn.addEventListener("click", () => cleanup(false))
      confirmBtn.addEventListener("click", () => cleanup(true))
      backdrop.addEventListener("click", (e) => {
        if (e.target === backdrop) cleanup(false)
      })

      backdrop.appendChild(content)
      document.body.appendChild(backdrop)
    })
  }

  _showOfflineModal(domain) {
    return new Promise((resolve) => {
      const backdrop = document.createElement("div")
      backdrop.className = "modal-overlay fixed inset-0 z-[9999] bg-black/70 flex items-center justify-center backdrop-blur-sm"

      backdrop.innerHTML = `
        <div class="bg-gray-800 rounded-lg shadow-2xl w-full max-w-md mx-4 overflow-hidden">
          <div class="p-4">
            <h3 class="text-xl font-bold text-white mb-2">Instance Unreachable</h3>
            <p class="text-sm text-gray-300">
              <strong class="text-white">${this._escapeHtml(domain)}</strong> is currently offline or cannot be reached. You can try again later, or remove this server from your list.
            </p>
            <label class="flex items-center gap-2 mt-4 cursor-pointer select-none">
              <input type="checkbox" data-dismiss-check class="w-4 h-4 rounded border-gray-600 bg-gray-700 text-red-500 focus:ring-red-500 focus:ring-offset-0 cursor-pointer accent-red-500">
              <span class="text-xs text-gray-400">Don\u2019t show this again for ${this._escapeHtml(domain)}</span>
            </label>
          </div>
          <div class="px-4 py-3 flex justify-end gap-3" style="background-color: #1e1c1b;">
            <button data-action="remove" class="px-4 py-2 text-sm font-medium text-red-400 hover:text-red-300 cursor-pointer">Remove Server</button>
            <button data-action="ok" class="px-4 py-2 text-sm font-medium text-white rounded cursor-pointer bg-gray-600 hover:bg-gray-500">OK</button>
          </div>
        </div>`

      const cleanup = (result) => {
        const checked = backdrop.querySelector("[data-dismiss-check]")?.checked
        if (checked) this._setOfflineDismissed(domain)
        backdrop.remove()
        resolve(result)
      }

      backdrop.querySelector('[data-action="remove"]').addEventListener("click", () => cleanup("remove"))
      backdrop.querySelector('[data-action="ok"]').addEventListener("click", () => cleanup("ok"))
      backdrop.addEventListener("click", (e) => {
        if (e.target === backdrop) cleanup("ok")
      })

      document.body.appendChild(backdrop)
    })
  }

  _isOfflineDismissed(domain) {
    try { return localStorage.getItem(`instance_offline_dismissed:${domain}`) === "1" } catch { return false }
  }

  _setOfflineDismissed(domain) {
    try { localStorage.setItem(`instance_offline_dismissed:${domain}`, "1") } catch {}
  }

  _escapeHtml(str) {
    const d = document.createElement("div")
    d.textContent = str || ""
    return d.innerHTML
  }

  // --- Stale reference cleanup ---

  removeStaleReference() {
    const serverEl = this.element.closest("[data-server-id]")
    if (!serverEl) return

    const folderList = serverEl.closest("[data-folder-server-list]")
    serverEl.remove()

    // If it was in a folder and the folder is now empty, remove the folder too
    if (folderList && folderList.children.length === 0) {
      const folderEl = folderList.closest("[data-rail-item]")
      if (folderEl) folderEl.remove()
    }
  }

  // --- UI helpers ---

  showError(message) {
    const toast = document.createElement("div")
    toast.className = "fixed top-4 right-4 z-[9999] bg-red-600 text-white px-4 py-2 rounded-lg shadow-lg text-sm font-medium max-w-sm"
    toast.textContent = message
    document.body.appendChild(toast)
    setTimeout(() => {
      toast.style.transition = "opacity 0.3s"
      toast.style.opacity = "0"
      setTimeout(() => toast.remove(), 300)
    }, 6000)
  }

  showOverlay(title, status) {
    let overlay = document.getElementById("instance-sync-overlay")
    if (!overlay) {
      overlay = document.createElement("div")
      overlay.id = "instance-sync-overlay"
      const tpl = document.getElementById("tpl-sync-overlay").content.cloneNode(true)
      overlay.appendChild(tpl)
      document.body.appendChild(overlay)
    }
    overlay.classList.remove("hidden")
    if (title !== undefined) {
      const h3 = overlay.querySelector("h3")
      if (h3) h3.textContent = title
    }
    if (status !== undefined) {
      const el = overlay.querySelector("[data-sync-status]")
      if (el) el.textContent = status
    }
  }

  updateOverlayStatus(synced) {
    const el = document.querySelector("[data-sync-status]")
    if (!el) return

    const labels = {
      profile: "Profile",
      servers: "Servers",
      folders: "Folders",
      conversations: "Conversations",
      friends: "Friends",
      gif_collections: "GIF collections"
    }
    const names = synced.map(s => labels[s] || s).join(", ")
    el.textContent = names.length > 0
      ? `Synced: ${names}`
      : "Up to date"
  }

  hideOverlay() {
    const overlay = document.getElementById("instance-sync-overlay")
    if (overlay) overlay.classList.add("hidden")
  }
}
