import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "newPanel", "migratePanel",
    "newTab", "migrateTab",
    "modeInput", "privateKeyInput",
    "relayList", "fetchButton", "fetchSpinner", "fetchError",
    "profilePreview", "usernameInput",
    "fetchedUsername", "fetchedDisplayName", "fetchedBio",
    "fetchedAvatarUrl", "fetchedBannerUrl", "fetchedRelays",
    "avatarPreview", "bannerPreview",
    "displayNamePreview", "usernamePreview", "bioPreview",
    "profileNotFound"
  ]

  connect() {
    this.relayCount = 1
  }

  switchToNew() {
    this.newPanelTarget.classList.remove("hidden")
    this.migratePanelTarget.classList.add("hidden")
    this.modeInputTarget.value = "new"
    this.newTabTarget.classList.add("border-accent", "text-white")
    this.newTabTarget.classList.remove("border-transparent", "text-gray-400")
    this.migrateTabTarget.classList.add("border-transparent", "text-gray-400")
    this.migrateTabTarget.classList.remove("border-accent", "text-white")
    this.togglePanelInputs(this.newPanelTarget, true)
    this.togglePanelInputs(this.migratePanelTarget, false)
  }

  switchToMigrate() {
    this.newPanelTarget.classList.add("hidden")
    this.migratePanelTarget.classList.remove("hidden")
    this.modeInputTarget.value = "migrate"
    this.migrateTabTarget.classList.add("border-accent", "text-white")
    this.migrateTabTarget.classList.remove("border-transparent", "text-gray-400")
    this.newTabTarget.classList.add("border-transparent", "text-gray-400")
    this.newTabTarget.classList.remove("border-accent", "text-white")
    this.togglePanelInputs(this.newPanelTarget, false)
    this.togglePanelInputs(this.migratePanelTarget, true)
  }

  togglePanelInputs(panel, enabled) {
    panel.querySelectorAll("input, select, textarea").forEach(el => {
      el.disabled = !enabled
    })
  }

  addRelayInput(e) {
    e.preventDefault()
    if (this.relayCount >= 5) return

    this.relayCount++
    const input = document.createElement("input")
    input.type = "text"
    input.name = "relay_urls[]"
    input.placeholder = "wss://relay.example.com"
    input.className = "w-full bg-gray-900 border border-gray-700 rounded px-3 py-2 text-white placeholder-gray-500 focus:outline-none focus:border-accent text-sm font-mono mt-2"
    this.relayListTarget.appendChild(input)

    if (this.relayCount >= 5) {
      e.target.classList.add("hidden")
    }
  }

  async fetchProfile(e) {
    e.preventDefault()

    const privateKey = this.privateKeyInputTarget.value.trim()
    if (!privateKey) {
      this.showError("Please enter a private key")
      return
    }

    // Collect relay URLs
    const relayInputs = this.relayListTarget.querySelectorAll("input")
    const relayUrls = Array.from(relayInputs).map(i => i.value.trim()).filter(Boolean)

    this.fetchButtonTarget.disabled = true
    this.fetchSpinnerTarget.classList.remove("hidden")
    this.hideError()
    this.profilePreviewTarget.classList.add("hidden")
    this.profileNotFoundTarget.classList.add("hidden")

    try {
      const body = new FormData()
      body.append("private_key", privateKey)
      relayUrls.forEach(url => body.append("relay_urls[]", url))

      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch("/setup/fetch_profile", {
        method: "POST",
        headers: { "X-CSRF-Token": csrfToken },
        body
      })

      const data = await response.json()

      if (!response.ok) {
        this.showError(data.error || "Failed to fetch profile")
        return
      }

      if (!data.found) {
        this.profileNotFoundTarget.classList.remove("hidden")
        this.usernameInputTarget.required = true
        this.usernameInputTarget.focus()
        // Still populate hidden key input so form submission works
        return
      }

      // Populate preview
      this.profilePreviewTarget.classList.remove("hidden")

      if (data.avatar_url) {
        this.avatarPreviewTarget.src = data.avatar_url
        this.avatarPreviewTarget.classList.remove("hidden")
      }
      if (data.banner_url) {
        this.bannerPreviewTarget.src = data.banner_url
        this.bannerPreviewTarget.parentElement.classList.remove("hidden")
      }

      this.displayNamePreviewTarget.textContent = data.display_name || ""
      this.usernamePreviewTarget.textContent = data.username ? `@${data.username}` : ""
      this.bioPreviewTarget.textContent = data.bio || ""

      // Fill editable username
      if (data.username) {
        this.usernameInputTarget.value = data.username
      }

      // Fill hidden inputs
      this.fetchedUsernameTarget.value = data.username || ""
      this.fetchedDisplayNameTarget.value = data.display_name || ""
      this.fetchedBioTarget.value = data.bio || ""
      this.fetchedAvatarUrlTarget.value = data.avatar_url || ""
      this.fetchedBannerUrlTarget.value = data.banner_url || ""

      // Populate relay hidden inputs
      this.fetchedRelaysTarget.innerHTML = ""
      ;(data.relays || []).forEach(url => {
        const input = document.createElement("input")
        input.type = "hidden"
        input.name = "fetched_relays[]"
        input.value = url
        this.fetchedRelaysTarget.appendChild(input)
      })
    } catch (err) {
      this.showError("Network error — could not reach server")
    } finally {
      this.fetchButtonTarget.disabled = false
      this.fetchSpinnerTarget.classList.add("hidden")
    }
  }

  showError(msg) {
    this.fetchErrorTarget.textContent = msg
    this.fetchErrorTarget.classList.remove("hidden")
  }

  hideError() {
    this.fetchErrorTarget.classList.add("hidden")
  }
}
