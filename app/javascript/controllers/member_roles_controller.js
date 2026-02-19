import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    serverId: String,
    membershipId: String,
    allRoles: Array,
    currentRoleIds: Array
  }
  static targets = ["dropdown", "badges"]

  connect() {
    this.boundCloseDropdown = this.closeDropdown.bind(this)
  }

  disconnect() {
    document.removeEventListener("click", this.boundCloseDropdown)
  }

  toggle(event) {
    event.stopPropagation()
    const dropdown = this.dropdownTarget
    const isHidden = dropdown.classList.contains("hidden")
    if (isHidden) {
      dropdown.classList.remove("hidden")
      setTimeout(() => document.addEventListener("click", this.boundCloseDropdown), 10)
    } else {
      this.closeDropdown()
    }
  }

  closeDropdown(event) {
    if (event && this.dropdownTarget.contains(event.target)) return
    this.dropdownTarget.classList.add("hidden")
    document.removeEventListener("click", this.boundCloseDropdown)
  }

  async toggleRole(event) {
    event.stopPropagation()
    const checkboxes = this.dropdownTarget.querySelectorAll("input[type=checkbox]")
    const roleIds = Array.from(checkboxes).filter(cb => cb.checked).map(cb => cb.value)

    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch(`/servers/${this.serverIdValue}/settings/members/${this.membershipIdValue}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({ role_ids: roleIds })
      })

      if (!response.ok) throw new Error("Failed to update roles")

      const data = await response.json()
      this.updateBadges(data.roles)
      this.showToast("Roles updated", "success")
    } catch (error) {
      this.showToast("Failed to update roles", "error")
    }
  }

  updateBadges(roles) {
    const badgesEl = this.badgesTarget
    if (!badgesEl) return

    if (roles.length === 0) {
      badgesEl.innerHTML = '<span class="inline-flex items-center text-xs px-2 py-0.5 rounded-full bg-gray-700 text-gray-400">@everyone</span>'
      return
    }

    badgesEl.innerHTML = ""
    const tpl = document.getElementById("tpl-role-badge")
    roles.forEach(role => {
      const clone = tpl.content.cloneNode(true)
      const badge = clone.querySelector("span")
      badge.className = `inline-flex items-center text-xs px-2 py-0.5 rounded-full ${role.name === "Admin" ? "bg-red-600/20 text-red-400" : "bg-gray-700 text-gray-400"}`
      clone.querySelector('[data-slot="color-dot"]').style.backgroundColor = role.color || "#ffffff"
      clone.querySelector('[data-slot="name"]').textContent = role.name
      badgesEl.appendChild(clone)
    })
  }

  showToast(message, type) {
    const toast = document.getElementById("toast")
    if (!toast) return
    toast.textContent = message
    toast.className = `fixed top-4 right-4 px-4 py-2 rounded-lg shadow-lg text-sm font-medium z-[100] transition-opacity duration-300 context-pop ${type === "success" ? "bg-green-600 text-white" : "bg-red-600 text-white"}`
    toast.classList.remove("hidden", "opacity-0")
    setTimeout(() => {
      toast.classList.add("opacity-0")
      setTimeout(() => toast.classList.add("hidden"), 300)
    }, 3000)
  }
}
