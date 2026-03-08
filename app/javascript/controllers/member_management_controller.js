import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "toolbar", "selectedCount", "memberList", "searchInput",
    "prunePanel", "pruneList", "pruneCount", "pruneFooter", "pruneDays",
    "batchTimeoutDropdown", "batchTimeoutWrapper", "selectAllCheckbox"
  ]
  static values = { serverId: String }

  connect() {
    this.selected = new Set()
    this._searchTimeout = null
    this._lastCheckedIndex = null
  }

  // --- Helpers to find checkboxes via DOM (not Stimulus targets) ---

  _getCheckboxes() {
    return Array.from(this.memberListTarget.querySelectorAll('input[type="checkbox"][data-member-id]'))
  }

  _getVisibleCheckboxes() {
    return this._getCheckboxes().filter(cb => {
      const row = cb.closest(".member-row")
      return row && !row.classList.contains("hidden")
    })
  }

  // --- Search (client-side filter) ---

  search() {
    clearTimeout(this._searchTimeout)
    this._searchTimeout = setTimeout(() => this._doSearch(), 150)
  }

  _doSearch() {
    const query = this.searchInputTarget.value.trim().toLowerCase()
    const rows = this.memberListTarget.querySelectorAll(".member-row")

    rows.forEach(row => {
      if (!query) {
        row.classList.remove("hidden")
        return
      }
      const text = row.textContent.toLowerCase()
      const memberId = (row.dataset.memberId || "").toLowerCase()
      if (text.includes(query) || memberId.includes(query)) {
        row.classList.remove("hidden")
      } else {
        row.classList.add("hidden")
      }
    })

    // Update count in heading
    const visible = this.memberListTarget.querySelectorAll(".member-row:not(.hidden)").length
    const heading = this.element.querySelector("h1")
    if (heading) {
      const total = rows.length
      heading.textContent = query ? `Members (${visible} of ${total})` : `Members (${total})`
    }
  }

  // --- Selection ---

  toggleSelect(e) {
    const id = e.currentTarget.dataset.memberId
    const checked = e.currentTarget.checked
    const checkboxes = this._getVisibleCheckboxes()

    // Shift+click range selection
    if (e.shiftKey && this._lastCheckedIndex !== null) {
      const currentIndex = checkboxes.indexOf(e.currentTarget)
      if (currentIndex !== -1) {
        const start = Math.min(this._lastCheckedIndex, currentIndex)
        const end = Math.max(this._lastCheckedIndex, currentIndex)
        for (let i = start; i <= end; i++) {
          checkboxes[i].checked = checked
          const mid = checkboxes[i].dataset.memberId
          if (checked) this.selected.add(mid)
          else this.selected.delete(mid)
        }
      }
    } else {
      if (checked) this.selected.add(id)
      else this.selected.delete(id)
    }

    this._lastCheckedIndex = checkboxes.indexOf(e.currentTarget)
    this._updateToolbar()
  }

  selectAll(e) {
    const checked = e.currentTarget.checked
    const cbs = this._getVisibleCheckboxes()
    cbs.forEach(cb => {
      cb.checked = checked
      const id = cb.dataset.memberId
      if (checked) this.selected.add(id)
      else this.selected.delete(id)
    })
    this._updateToolbar()
  }

  _updateToolbar() {
    if (this.selected.size > 0) {
      this.toolbarTarget.classList.remove("hidden")
      this.selectedCountTarget.textContent = this.selected.size
    } else {
      this.toolbarTarget.classList.add("hidden")
    }
    // Sync select-all checkbox
    if (this.hasSelectAllCheckboxTarget) {
      const visible = this._getVisibleCheckboxes()
      this.selectAllCheckboxTarget.checked = visible.length > 0 && visible.every(cb => cb.checked)
    }
  }

  // --- Batch actions ---

  async batchKick() {
    if (!confirm(`Kick ${this.selected.size} member(s)?`)) return
    await this._batchAction("batch_kick", { member_ids: Array.from(this.selected) })
  }

  async batchBan() {
    const reason = prompt("Ban reason (optional):")
    if (reason === null) return
    await this._batchAction("batch_ban", { member_ids: Array.from(this.selected), reason })
  }

  toggleBatchTimeout() {
    this.batchTimeoutDropdownTarget.classList.toggle("hidden")
  }

  async batchTimeout(e) {
    const duration = e.currentTarget.dataset.duration
    this.batchTimeoutDropdownTarget.classList.add("hidden")
    await this._batchAction("batch_timeout", { member_ids: Array.from(this.selected), duration })
  }

  async _batchAction(action, body) {
    const token = document.querySelector("meta[name=csrf-token]")?.content
    try {
      const res = await fetch(`/servers/${this.serverIdValue}/settings/${action}`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": token },
        body: JSON.stringify(body)
      })
      if (res.ok) {
        this.selected.clear()
        this._updateToolbar()
        window.location.reload()
      } else {
        const data = await res.json().catch(() => ({}))
        alert(data.error || "Action failed")
      }
    } catch (e) {
      console.error("Batch action failed:", e)
    }
  }

  // --- Prune ---

  togglePrune() {
    this.prunePanelTarget.classList.toggle("hidden")
  }

  async previewPrune() {
    const days = this.pruneDaysTarget.value
    const token = document.querySelector("meta[name=csrf-token]")?.content
    try {
      const res = await fetch(`/servers/${this.serverIdValue}/settings/prune_preview?days=${days}`, {
        headers: { "X-CSRF-Token": token }
      })
      if (res.ok) {
        const members = await res.json()
        this.pruneListTarget.innerHTML = members.map(m => `
          <div class="flex items-center gap-2 py-1.5 px-2 bg-gray-900/50 rounded">
            <div class="w-6 h-6 rounded-full flex items-center justify-center text-xs font-bold text-white overflow-hidden"
                 style="background-color: ${m.avatar_url ? 'transparent' : m.profile_color}">
              ${m.avatar_url ? `<img src="${m.avatar_url}" class="w-full h-full object-cover">` : (m.username?.[0]?.toUpperCase() || '?')}
            </div>
            <span class="text-sm text-gray-300">${m.display_name || m.username}</span>
            <span class="text-xs text-gray-500 ml-auto">${m.last_online ? `Last online ${new Date(m.last_online).toLocaleDateString()}` : 'Never online'}</span>
          </div>
        `).join("")
        this.pruneCountTarget.textContent = `${members.length} member(s) will be pruned`
        this.pruneFooterTarget.classList.remove("hidden")
      }
    } catch (e) {
      console.error("Prune preview failed:", e)
    }
  }

  async confirmPrune() {
    if (!confirm("Are you sure you want to prune these members?")) return
    const days = this.pruneDaysTarget.value
    const token = document.querySelector("meta[name=csrf-token]")?.content
    try {
      const res = await fetch(`/servers/${this.serverIdValue}/settings/prune?days=${days}`, {
        method: "DELETE",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": token }
      })
      if (res.ok) {
        const data = await res.json()
        alert(`Pruned ${data.pruned} member(s).`)
        window.location.reload()
      }
    } catch (e) {
      console.error("Prune failed:", e)
    }
  }

  // --- Individual timeout ---

  showTimeoutDropdown(e) {
    const memberId = e.currentTarget.dataset.memberId
    document.getElementById("timeout-dropdown-popup")?.remove()

    const btn = e.currentTarget
    const rect = btn.getBoundingClientRect()
    const dropdown = document.createElement("div")
    dropdown.id = "timeout-dropdown-popup"
    dropdown.className = "fixed w-36 bg-gray-900 border border-gray-700 rounded-lg shadow-xl py-1 z-[100]"
    dropdown.style.top = `${rect.bottom + 4}px`
    dropdown.style.left = `${rect.left}px`

    const durations = [
      { label: "60 seconds", value: 60 },
      { label: "5 minutes", value: 300 },
      { label: "10 minutes", value: 600 },
      { label: "1 hour", value: 3600 },
      { label: "1 day", value: 86400 },
      { label: "1 week", value: 604800 }
    ]

    durations.forEach(d => {
      const item = document.createElement("button")
      item.type = "button"
      item.className = "w-full text-left text-sm text-gray-300 hover:bg-gray-800 px-3 py-1.5 cursor-pointer"
      item.textContent = d.label
      item.addEventListener("click", () => {
        dropdown.remove()
        this._timeoutMember(memberId, d.value)
      })
      dropdown.appendChild(item)
    })

    document.body.appendChild(dropdown)

    const close = (ev) => {
      if (!dropdown.contains(ev.target) && ev.target !== btn) {
        dropdown.remove()
        document.removeEventListener("click", close)
      }
    }
    setTimeout(() => document.addEventListener("click", close), 0)
  }

  async _timeoutMember(memberId, duration) {
    const token = document.querySelector("meta[name=csrf-token]")?.content
    try {
      const res = await fetch(`/servers/${this.serverIdValue}/settings/members/${memberId}/timeout`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": token },
        body: JSON.stringify({ duration })
      })
      if (res.ok) {
        window.location.reload()
      } else {
        const data = await res.json().catch(() => ({}))
        alert(data.error || "Timeout failed")
      }
    } catch (e) {
      console.error("Timeout failed:", e)
    }
  }

  async removeTimeout(e) {
    const memberId = e.currentTarget.dataset.memberId
    const token = document.querySelector("meta[name=csrf-token]")?.content
    try {
      const res = await fetch(`/servers/${this.serverIdValue}/settings/members/${memberId}/remove_timeout`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": token }
      })
      if (res.ok) {
        window.location.reload()
      }
    } catch (e) {
      console.error("Remove timeout failed:", e)
    }
  }
}
