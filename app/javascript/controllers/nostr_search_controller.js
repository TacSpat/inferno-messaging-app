import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "dropdown", "spinner"]

  connect() {
    console.log("[nostr-search] controller connected")
    this.debounceTimer = null
    this.selectedIndex = -1
    this.results = []
    this.boundClickOutside = this.clickOutside.bind(this)
    document.addEventListener("click", this.boundClickOutside)
  }

  disconnect() {
    if (this.debounceTimer) clearTimeout(this.debounceTimer)
    document.removeEventListener("click", this.boundClickOutside)
  }

  clickOutside(event) {
    if (!this.element.contains(event.target)) this.closeDropdown()
  }

  onInput() {
    if (this.debounceTimer) clearTimeout(this.debounceTimer)
    var query = this.inputTarget.value.trim()
    if (query.length < 2) {
      this.closeDropdown()
      return
    }
    this.debounceTimer = setTimeout(this.search.bind(this), 300)
  }

  onKeydown(event) {
    if (this.dropdownTarget.classList.contains("hidden")) return
    var items = this.dropdownTarget.querySelectorAll("[data-index]")

    if (event.key === "ArrowDown") {
      event.preventDefault()
      this.selectedIndex = Math.min(this.selectedIndex + 1, items.length - 1)
      this.highlightItem(items)
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      this.selectedIndex = Math.max(this.selectedIndex - 1, 0)
      this.highlightItem(items)
    } else if (event.key === "Enter" && this.selectedIndex >= 0) {
      event.preventDefault()
      var item = items[this.selectedIndex]
      var btn = item ? item.querySelector("[data-action*='addContact']") : null
      if (btn && !btn.disabled) btn.click()
    } else if (event.key === "Escape") {
      this.closeDropdown()
      this.inputTarget.blur()
    }
  }

  onFocus() {
    if (this.results.length > 0) this.openDropdown()
  }

  search() {
    var query = this.inputTarget.value.trim()
    if (query.length < 2) {
      this.closeDropdown()
      return
    }

    this.spinnerTarget.classList.remove("hidden")
    var self = this

    fetch("/nostr/search?q=" + encodeURIComponent(query))
      .then(function(response) {
        if (!response.ok) throw new Error("Request failed")
        return response.json()
      })
      .then(function(data) {
        self.results = data
        self.selectedIndex = -1
        self.renderDropdown()
      })
      .catch(function() {
        self.results = []
        self.dropdownTarget.innerHTML = '<div class="px-4 py-3 text-sm text-gray-400">Search failed. Try again.</div>'
        self.openDropdown()
      })
      .finally(function() {
        self.spinnerTarget.classList.add("hidden")
      })
  }

  renderDropdown() {
    if (this.results.length === 0) {
      this.dropdownTarget.innerHTML = '<div class="flex items-center gap-3 px-4 py-4 text-gray-400"><svg class="w-5 h-5 shrink-0 text-gray-500" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"/></svg><span class="text-sm">No users found.</span></div>'
      this.openDropdown()
      return
    }

    var html = ""
    for (var i = 0; i < this.results.length; i++) {
      html += this.resultRow(this.results[i], i)
    }
    this.dropdownTarget.innerHTML = html
    this.openDropdown()
  }

  resultRow(r, index) {
    var displayName = r.display_name || r.name || this.truncateNpub(r.npub) || r.pubkey.slice(0, 12) + "..."
    var initial = (displayName[0] || "?").toUpperCase()
    var avatar = ""
    if (r.avatar_url) {
      avatar = '<img src="' + this.esc(r.avatar_url) + '" class="w-8 h-8 rounded-full object-cover" onerror="this.style.display=\'none\';this.nextElementSibling.style.display=\'flex\'">'
    }
    var fallbackClass = r.avatar_url ? "hidden" : ""
    var fallback = '<div class="w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold bg-gray-600 text-gray-200 ' + fallbackClass + '">' + this.esc(initial) + '</div>'
    var sub = r.nip05 ? this.esc(r.nip05) : (r.npub ? this.truncateNpub(r.npub) : "")
    var action = this.actionButton(r)
    var bg = index === this.selectedIndex ? "bg-gray-600/40" : ""

    return '<div data-index="' + index + '" class="flex items-center gap-3 px-3 py-2 cursor-pointer transition-colors hover:bg-gray-600/40 ' + bg + '">' +
      '<div class="shrink-0">' + avatar + fallback + '</div>' +
      '<div class="flex-1 min-w-0">' +
        '<p class="text-sm font-medium text-white truncate">' + this.esc(displayName) + '</p>' +
        (sub ? '<p class="text-xs text-gray-400 truncate font-mono">' + sub + '</p>' : '') +
      '</div>' +
      '<div class="shrink-0">' + action + '</div>' +
    '</div>'
  }

  actionButton(r) {
    if (r.contact_status === "friend") {
      return '<span class="px-2.5 py-1 text-xs font-medium text-green-400 bg-green-900/30 rounded">Added</span>'
    }
    if (r.contact_status === "pending_outgoing") {
      return '<span class="px-2.5 py-1 text-xs font-medium text-yellow-400 bg-yellow-900/30 rounded">Pending</span>'
    }
    if (r.contact_status === "pending_incoming") {
      return '<span class="px-2.5 py-1 text-xs font-medium text-blue-400 bg-blue-900/30 rounded">Respond</span>'
    }
    return '<button class="px-2.5 py-1 bg-confirm hover:bg-confirm-light text-white text-xs font-medium rounded cursor-pointer disabled:opacity-50" data-action="click->nostr-search#addContact" data-pubkey="' + this.esc(r.pubkey) + '">Add</button>'
  }

  addContact(event) {
    event.stopPropagation()
    var button = event.currentTarget
    var pubkey = button.dataset.pubkey
    button.disabled = true
    button.textContent = "..."

    var token = document.querySelector('meta[name="csrf-token"]')
    var csrfToken = token ? token.content : ""

    fetch("/friendships", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": csrfToken,
        "Accept": "application/json"
      },
      body: "tag=" + encodeURIComponent(pubkey)
    }).then(function(response) {
      if (response.ok || response.redirected) {
        button.textContent = "Sent"
        button.className = "px-2.5 py-1 text-xs font-medium text-yellow-400 bg-yellow-900/30 rounded"
      } else {
        button.textContent = "Fail"
        button.disabled = false
        setTimeout(function() { button.textContent = "Add" }, 2000)
      }
    }).catch(function() {
      button.textContent = "Fail"
      button.disabled = false
      setTimeout(function() { button.textContent = "Add" }, 2000)
    })
  }

  highlightItem(items) {
    for (var i = 0; i < items.length; i++) {
      if (i === this.selectedIndex) {
        items[i].classList.add("bg-gray-600/40")
      } else {
        items[i].classList.remove("bg-gray-600/40")
      }
    }
    if (items[this.selectedIndex]) {
      items[this.selectedIndex].scrollIntoView({ block: "nearest" })
    }
  }

  openDropdown() {
    this.dropdownTarget.classList.remove("hidden")
  }

  closeDropdown() {
    this.dropdownTarget.classList.add("hidden")
    this.selectedIndex = -1
  }

  truncateNpub(npub) {
    if (!npub) return ""
    return npub.slice(0, 12) + "..." + npub.slice(-6)
  }

  esc(str) {
    if (!str) return ""
    var d = document.createElement("div")
    d.textContent = str
    return d.innerHTML
  }
}
