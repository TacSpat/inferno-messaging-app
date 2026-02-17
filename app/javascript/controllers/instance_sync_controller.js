import { Controller } from "@hotwired/stimulus"

// Intercepts clicks on remote instance links.
// Shows a "Syncing instance info..." overlay, hits the sync endpoint,
// then navigates to the target URL — or removes the link if the user
// no longer exists on the home instance.
export default class extends Controller {
  static values = { url: String }

  async navigate(event) {
    event.preventDefault()
    const targetUrl = this.urlValue || this.element.href
    if (!targetUrl) return

    this.showOverlay()

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

    window.location.href = targetUrl
  }

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

  showError(message) {
    const toast = document.createElement("div")
    toast.className = "fixed top-4 right-4 z-50 bg-red-600 text-white px-4 py-2 rounded-lg shadow-lg"
    toast.setAttribute("data-controller", "toast")
    toast.textContent = message
    document.body.appendChild(toast)
  }

  showOverlay() {
    let overlay = document.getElementById("instance-sync-overlay")
    if (!overlay) {
      overlay = document.createElement("div")
      overlay.id = "instance-sync-overlay"
      overlay.innerHTML = `
        <div class="modal-overlay fixed inset-0 z-[9999] bg-black/70 flex items-center justify-center backdrop-blur-sm">
          <div class="bg-gray-800 rounded-xl border border-gray-700 p-6 max-w-sm w-full mx-4 shadow-2xl text-center">
            <div class="flex justify-center mb-4">
              <svg class="w-8 h-8 text-amber-400 animate-spin" fill="none" viewBox="0 0 24 24">
                <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
              </svg>
            </div>
            <h3 class="text-lg font-semibold text-white mb-1">Syncing instance data</h3>
            <p class="text-sm text-gray-400" data-sync-status>Fetching latest profile, servers, and collections...</p>
          </div>
        </div>
      `
      document.body.appendChild(overlay)
    }
    overlay.classList.remove("hidden")
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
