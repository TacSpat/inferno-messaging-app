import { Controller } from "@hotwired/stimulus"

// Attaches to the #messages container.
// Stamps a persistent fire-icon button onto every Tenor GIF embed.
// Visibility is handled purely by CSS (see application.tailwind.css).
export default class extends Controller {
  connect() {
    this.loadFavorites()
    this.stampAllButtons()
    this.setupGifVisibility()

    // Watch for new GIF embeds (e.g. new messages via Turbo Stream)
    this.observer = new MutationObserver(() => {
      this.stampAllButtons()
      this.observeGifs()
    })
    this.observer.observe(this.element, { childList: true, subtree: true })

    // Sync when picker or other sources toggle favorites
    this.boundOnFavoritesChanged = (e) => {
      if (e.detail.source === "message-stream") return // ignore our own events
      const { gifId, favorited } = e.detail
      if (favorited) {
        this.favoritedIds.add(gifId)
      } else {
        this.favoritedIds.delete(gifId)
      }
      // Update any matching fire icons in the message stream
      this.element.querySelectorAll(`[data-tenor-gif-id="${gifId}"] .gif-save-btn`).forEach(btn => {
        btn.innerHTML = this.fireIcon(favorited)
      })
    }
    document.addEventListener("gif-favorites-changed", this.boundOnFavoritesChanged)
  }

  disconnect() {
    if (this.observer) this.observer.disconnect()
    if (this.gifVisibilityObserver) this.gifVisibilityObserver.disconnect()
    document.removeEventListener("gif-favorites-changed", this.boundOnFavoritesChanged)
  }

  // --- GIF visibility (pause off-screen GIFs) ---

  setupGifVisibility() {
    this.gifVisibilityObserver = new IntersectionObserver(
      (entries) => {
        entries.forEach(entry => {
          const img = entry.target
          if (entry.isIntersecting) {
            if (img.dataset.gifOrigSrc) {
              img.src = img.dataset.gifOrigSrc
              delete img.dataset.gifOrigSrc
            }
          } else {
            // Only pause loaded GIFs — unloaded ones aren't animating
            if (img.complete && img.src && !img.dataset.gifOrigSrc) {
              img.dataset.gifOrigSrc = img.src
              const w = img.naturalWidth || img.offsetWidth
              const h = img.naturalHeight || img.offsetHeight
              img.src = `data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='${w}' height='${h}'%3E%3Crect width='100%25' height='100%25' fill='%23374151'/%3E%3C/svg%3E`
            }
          }
        })
      },
      { root: this.element, rootMargin: "200px 0px" }
    )
    this.observeGifs()
  }

  observeGifs() {
    // Tenor GIF imgs (including cached HTML without data-animated-gif)
    this.element.querySelectorAll("[data-tenor-gif-id] img:not([data-gif-observed])").forEach(img => {
      img.dataset.gifObserved = "1"
      this.gifVisibilityObserver.observe(img)
    })
    // Uploaded GIF attachments
    this.element.querySelectorAll("[data-animated-gif]:not([data-gif-observed])").forEach(img => {
      img.dataset.gifObserved = "1"
      this.gifVisibilityObserver.observe(img)
    })
  }

  async loadFavorites() {
    try {
      const resp = await fetch("/api/gif_favorites?default=1")
      if (resp.ok) {
        const data = await resp.json()
        this.favoritedIds = new Set(data.favorites.map(f => f.tenor_gif_id))
        // Re-stamp to update icons now that we know which are favorited
        this.element.querySelectorAll("[data-tenor-gif-id][data-gif-save-attached] .gif-save-btn").forEach(btn => {
          const gifId = btn.closest("[data-tenor-gif-id]").dataset.tenorGifId
          btn.innerHTML = this.fireIcon(this.favoritedIds.has(gifId))
        })
      }
    } catch(e) {
      this.favoritedIds = new Set()
    }
  }

  stampAllButtons() {
    this.element.querySelectorAll("[data-tenor-gif-id]:not([data-gif-save-attached])").forEach(gifEl => {
      gifEl.dataset.gifSaveAttached = "1"

      const btn = document.createElement("button")
      btn.className = "gif-save-btn absolute top-2 left-2 z-10 w-8 h-8 rounded-full bg-black/60 hover:bg-black/80 flex items-center justify-center cursor-pointer"
      btn.type = "button"

      const gifId = gifEl.dataset.tenorGifId
      const isFav = this.favoritedIds && this.favoritedIds.has(gifId)
      btn.innerHTML = this.fireIcon(isFav)

      btn.addEventListener("click", (e) => {
        e.preventDefault()
        e.stopPropagation()
        this.toggleFavorite(gifEl, btn)
      })

      if (getComputedStyle(gifEl).position === "static") {
        gifEl.style.position = "relative"
      }
      gifEl.appendChild(btn)
    })
  }

  async toggleFavorite(gifEl, btn) {
    const gifId = gifEl.dataset.tenorGifId
    const tenorUrl = gifEl.dataset.tenorUrl || ""
    const gifUrl = gifEl.dataset.gifUrl || ""
    const previewUrl = gifEl.dataset.previewUrl || ""

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    try {
      const resp = await fetch("/api/gif_favorites/toggle", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({
          tenor_gif_id: gifId,
          tenor_url: tenorUrl,
          gif_url: gifUrl,
          preview_url: previewUrl,
          description: ""
        })
      })

      if (resp.ok) {
        const data = await resp.json()
        if (data.favorited) {
          this.favoritedIds.add(gifId)
        } else {
          this.favoritedIds.delete(gifId)
        }
        btn.innerHTML = this.fireIcon(data.favorited)

        // Notify picker to invalidate its favorites cache
        document.dispatchEvent(new CustomEvent("gif-favorites-changed", { detail: { gifId, favorited: data.favorited, source: "message-stream" } }))
      }
    } catch(e) {
      console.error("Failed to toggle GIF favorite:", e)
    }
  }

  fireIcon(filled) {
    if (filled) {
      return `<svg class="w-5 h-5 text-accent-light" fill="currentColor" viewBox="0 0 24 24"><path d="M12 23c-4.97 0-9-2.69-9-6 0-2.4 1.68-4.47 2.64-5.27.32-.27.8-.04.8.39v.51c0 1.28.49 2.52 1.38 3.46.09.1.25.1.34 0 .37-.4.65-.87.82-1.39.09-.27.42-.37.63-.18C11.4 16.18 12.5 17.88 12.5 20c0 .28.22.5.5.5s.5-.22.5-.5c0-2.98-1.63-5.58-4.07-6.97a.249.249 0 01-.01-.43C11.26 11.45 13 9.13 13 6.5c0-.99-.16-1.94-.47-2.83a.252.252 0 01.34-.31C16.68 5.38 21 9.49 21 14c0 5.38-4.03 9-9 9z"/></svg>`
    }
    return `<svg class="w-5 h-5 text-white/80" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M12 23c-4.97 0-9-2.69-9-6 0-2.4 1.68-4.47 2.64-5.27.32-.27.8-.04.8.39v.51c0 1.28.49 2.52 1.38 3.46.09.1.25.1.34 0 .37-.4.65-.87.82-1.39.09-.27.42-.37.63-.18C11.4 16.18 12.5 17.88 12.5 20c0 .28.22.5.5.5s.5-.22.5-.5c0-2.98-1.63-5.58-4.07-6.97a.249.249 0 01-.01-.43C11.26 11.45 13 9.13 13 6.5c0-.99-.16-1.94-.47-2.83a.252.252 0 01.34-.31C16.68 5.38 21 9.49 21 14c0 5.38-4.03 9-9 9z"/></svg>`
  }
}
