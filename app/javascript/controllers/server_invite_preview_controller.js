import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "input", "preview", "loading", "error", "discoverable",
    "banner", "icon", "iconFallback", "iconLetter",
    "name", "description", "online", "members", "joinBtn"
  ]

  connect() {
    this._debounce = null
    this._joinUrl = null
    this._joinMethod = null
  }

  onInput() {
    clearTimeout(this._debounce)
    this.errorTarget.classList.add("hidden")

    const val = this.inputTarget.value.trim()
    if (!val) {
      this.previewTarget.classList.add("hidden")
      this.loadingTarget.classList.add("hidden")
      if (this.hasDiscoverableTarget) this.discoverableTarget.classList.remove("hidden")
      return
    }

    this._debounce = setTimeout(() => this.resolve(val), 400)
  }

  onKeydown(e) {
    if (e.key === "Enter") {
      e.preventDefault()
      clearTimeout(this._debounce)
      this.resolve(this.inputTarget.value.trim())
    }
  }

  async resolve(input) {
    if (!input) {
      this.showError("Enter an invite link or server ID")
      return
    }

    this.previewTarget.classList.add("hidden")
    this.loadingTarget.classList.remove("hidden")
    this.errorTarget.classList.add("hidden")
    if (this.hasDiscoverableTarget) this.discoverableTarget.classList.add("hidden")

    try {
      const csrf = document.querySelector("meta[name=csrf-token]")?.content
      const res = await fetch("/resolve_server_preview", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": csrf
        },
        body: JSON.stringify({ input })
      })

      if (!res.ok) {
        const data = await res.json().catch(() => ({}))
        throw new Error(data.error || "Could not resolve server")
      }

      const data = await res.json()

      if (data.state && data.state !== "valid") {
        const messages = {
          revoked: "This invite has been revoked",
          expired: "This invite has expired",
          maxed_out: "This invite has reached its maximum uses"
        }
        throw new Error(messages[data.state] || "Invalid invite")
      }

      this.showPreview(data)
      this._joinUrl = data.join_url
      this._joinMethod = data.join_method
    } catch (err) {
      this.showError(err.message || "Could not resolve server")
    } finally {
      this.loadingTarget.classList.add("hidden")
    }
  }

  showPreview(data) {
    this.nameTarget.textContent = data.name || "Unknown Server"

    if (data.description) {
      this.descriptionTarget.textContent = data.description
      this.descriptionTarget.classList.remove("hidden")
    } else {
      this.descriptionTarget.classList.add("hidden")
    }

    if (data.icon_url) {
      this.iconTarget.src = data.icon_url
      this.iconTarget.classList.remove("hidden")
      this.iconFallbackTarget.classList.add("hidden")
    } else {
      this.iconTarget.classList.add("hidden")
      this.iconFallbackTarget.classList.remove("hidden")
      this.iconLetterTarget.textContent = (data.name || "?")[0].toUpperCase()
    }

    this.onlineTarget.textContent = data.online_count || 0
    this.membersTarget.textContent = data.member_count || 0

    this.bannerTarget.classList.add("hidden")

    this.previewTarget.classList.remove("hidden")
  }

  showError(msg) {
    this.errorTarget.textContent = msg
    this.errorTarget.classList.remove("hidden")
    this.previewTarget.classList.add("hidden")
  }

  join() {
    if (!this._joinUrl) return
    this._postTo(this._joinUrl)
  }

  joinDirect(e) {
    const gid = e.currentTarget.dataset.nostrGroupId
    if (!gid) return
    this._postTo(`/inferno/server/${gid}/join`)
  }

  _postTo(url) {
    const csrf = document.querySelector("meta[name=csrf-token]")?.content

    if (url.includes("/join") || url.includes("/accept")) {
      const form = document.createElement("form")
      form.method = "POST"
      form.action = url
      if (csrf) {
        const input = document.createElement("input")
        input.type = "hidden"
        input.name = "authenticity_token"
        input.value = csrf
        form.appendChild(input)
      }
      document.body.appendChild(form)
      form.submit()
    } else {
      window.location.href = url
    }
  }
}
