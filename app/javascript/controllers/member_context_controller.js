import { Controller } from "@hotwired/stimulus"
import { positionPopup } from "../utils/popup_positioning"

export default class extends Controller {
  static values = { serverId: String }

  connect() {
    this.menu = null
    this.rolesDropdown = null
    this.nicknameModal = null
    this.boundClose = this.closeMenu.bind(this)
  }

  disconnect() {
    this.closeMenu()
    this.closeNicknameModal()
  }

  async show(event) {
    event.preventDefault()
    event.stopPropagation()
    this.closeMenu()

    // Close any open profile card
    document.querySelectorAll("[data-profile-card]").forEach(el => el.remove())

    const target = event.currentTarget
    const userId = target.dataset.userId
    if (!userId || !this.serverIdValue) return

    const response = await fetch(`/servers/${this.serverIdValue}/members/${userId}/context_menu`, {
      headers: { "X-Requested-With": "XMLHttpRequest" }
    })
    if (!response.ok) return

    const html = await response.text()
    this.menu = document.createElement("div")
    this.menu.className = "fixed z-[60] context-pop"
    this.menu.setAttribute("data-context-menu", "member")
    this.menu.innerHTML = html

    document.body.appendChild(this.menu)
    positionPopup(this.menu, { x: event.clientX, y: event.clientY }, {
      preferredSide: "below",
      horizontalAlign: "left"
    })
    this.bindMenuActions()
    setTimeout(() => document.addEventListener("click", this.boundClose), 10)
  }

  bindMenuActions() {
    if (!this.menu) return
    this.menu.querySelectorAll("[data-context-action]").forEach(btn => {
      const action = btn.dataset.contextAction
      if (action === "showRoles") {
        btn.addEventListener("click", (e) => this.showRoles(e))
      } else if (action === "changeNickname") {
        btn.addEventListener("click", (e) => this.changeNickname(e))
      } else if (action === "mention") {
        btn.addEventListener("click", (e) => this.insertMention(e))
      } else if (action === "viewProfile") {
        btn.addEventListener("click", (e) => this.viewProfile(e))
      }
    })
  }

  // --- Roles: secondary dropdown ---

  showRoles(event) {
    event.preventDefault()
    event.stopPropagation()

    // If already open, close it
    if (this.rolesDropdown) {
      this.rolesDropdown.remove()
      this.rolesDropdown = null
      return
    }

    const btn = event.currentTarget
    const memberId = btn.dataset.memberId
    const serverId = btn.dataset.serverId
    const roles = JSON.parse(btn.dataset.roles || "[]")
    const memberRoles = JSON.parse(btn.dataset.memberRoles || "[]")

    if (!this.menu) return

    // Build the secondary dropdown
    this.rolesDropdown = document.createElement("div")
    this.rolesDropdown.className = "absolute z-[70] w-52 bg-gray-900 rounded-lg shadow-2xl border border-gray-700 py-1.5 text-sm max-h-64 overflow-y-auto context-pop"

    // Position it to the right of the wrapper
    const wrapper = btn.closest(".context-roles-wrapper")
    const menuRect = this.menu.getBoundingClientRect()
    const btnRect = wrapper.getBoundingClientRect()

    let ddLeft = btnRect.right + 4
    // If it would overflow right, show to the left instead
    if (ddLeft + 210 > window.innerWidth) {
      ddLeft = btnRect.left - 214
    }
    let ddTop = btnRect.top
    if (ddTop + 260 > window.innerHeight) {
      ddTop = window.innerHeight - 264
    }

    this.rolesDropdown.style.position = "fixed"
    this.rolesDropdown.style.left = `${ddLeft}px`
    this.rolesDropdown.style.top = `${ddTop}px`

    let html = '<p class="px-3 py-1.5 text-[10px] font-semibold text-gray-500 uppercase sticky top-0 bg-gray-900">Assign Roles</p>'

    if (roles.length === 0) {
      html += '<p class="px-3 py-2 text-xs text-gray-500">No roles available</p>'
    } else {
      roles.forEach(role => {
        const checked = memberRoles.includes(role.id) ? "checked" : ""
        const escapedName = this.escapeHtml(role.name)
        html += `<label class="flex items-center px-3 py-1.5 hover:bg-gray-800 cursor-pointer">
          <input type="checkbox" value="${role.id}" ${checked}
                 class="mr-2 accent-red-500 context-role-checkbox">
          <span class="w-2.5 h-2.5 rounded-full mr-1.5 flex-shrink-0" style="background-color: ${role.color || '#ffffff'}"></span>
          <span class="text-gray-300 text-sm">${escapedName}</span>
        </label>`
      })
    }

    this.rolesDropdown.innerHTML = html

    document.body.appendChild(this.rolesDropdown)

    // Attach change listeners
    this.rolesDropdown.querySelectorAll(".context-role-checkbox").forEach(cb => {
      cb.addEventListener("change", () => this.handleContextRoleToggle(memberId, serverId))
    })

    // Prevent clicks inside dropdown from closing the menu
    this.rolesDropdown.addEventListener("click", (e) => e.stopPropagation())
  }

  async handleContextRoleToggle(memberId, serverId) {
    if (!this.rolesDropdown) return
    const checkboxes = this.rolesDropdown.querySelectorAll(".context-role-checkbox")
    const roleIds = Array.from(checkboxes).filter(cb => cb.checked).map(cb => cb.value)

    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch(`/servers/${serverId}/settings/members/${memberId}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({ role_ids: roleIds })
      })

      if (!response.ok) throw new Error("Failed to update roles")
      this.showToast("Roles updated", "success")
    } catch (error) {
      this.showToast("Failed to update roles", "error")
    }
  }

  // --- Nickname: modal ---

  changeNickname(event) {
    event.preventDefault()
    event.stopPropagation()

    const btn = event.currentTarget
    const memberId = btn.dataset.memberId
    const serverId = btn.dataset.serverId
    const currentNickname = btn.dataset.currentNickname || ""

    // Close the context menu
    this.closeMenu()

    // Build modal overlay
    this.nicknameModal = document.createElement("div")
    this.nicknameModal.className = "modal-overlay fixed inset-0 z-[100] flex items-center justify-center bg-black/60"
    this.nicknameModal.innerHTML = `
      <div class="bg-gray-800 rounded-lg shadow-2xl border border-gray-700 w-full max-w-sm mx-4 p-5" data-nickname-panel>
        <h3 class="text-lg font-bold text-white mb-1">Change Nickname</h3>
        <p class="text-xs text-gray-400 mb-4">Leave empty to reset to display name.</p>
        <input type="text" value="${this.escapeAttr(currentNickname)}" maxlength="32" placeholder="Enter nickname..."
               class="w-full bg-gray-900 border border-gray-600 rounded px-3 py-2 text-white text-sm focus:outline-none focus:border-red-500 mb-4"
               data-nickname-input>
        <div class="flex justify-end gap-2">
          <button class="text-sm text-gray-400 hover:text-white px-4 py-1.5 rounded transition" data-nickname-cancel>Cancel</button>
          <button class="text-sm bg-gradient-to-r from-red-700 to-red-500 hover:from-red-600 hover:to-red-400 text-white font-semibold px-4 py-1.5 rounded transition" data-nickname-save>Save</button>
        </div>
      </div>
    `

    document.body.appendChild(this.nicknameModal)

    const input = this.nicknameModal.querySelector("[data-nickname-input]")
    input.focus()
    input.select()

    // Close on backdrop click
    this.nicknameModal.addEventListener("click", (e) => {
      if (!e.target.closest("[data-nickname-panel]")) {
        this.closeNicknameModal()
      }
    })

    // Cancel button
    this.nicknameModal.querySelector("[data-nickname-cancel]").addEventListener("click", () => {
      this.closeNicknameModal()
    })

    // Save button
    this.nicknameModal.querySelector("[data-nickname-save]").addEventListener("click", () => {
      this.saveNickname(memberId, serverId, input.value.trim())
    })

    // Enter key
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault()
        this.saveNickname(memberId, serverId, input.value.trim())
      }
      if (e.key === "Escape") {
        this.closeNicknameModal()
      }
    })
  }

  async saveNickname(memberId, serverId, nickname) {
    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch(`/servers/${serverId}/settings/members/${memberId}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({ nickname: nickname || null })
      })

      if (!response.ok) throw new Error("Failed to update nickname")
      this.showToast("Nickname updated", "success")
      this.closeNicknameModal()
    } catch (error) {
      this.showToast("Failed to update nickname", "error")
    }
  }

  // --- Mention: insert @username at caret ---

  insertMention(event) {
    event.preventDefault()
    event.stopPropagation()

    const username = event.currentTarget.dataset.username
    if (!username) return

    this.closeMenu()

    const mention = `@${username} `

    // Find the message input (server channels or DMs)
    const input = document.querySelector('[data-message-form-target="input"]')
      || document.querySelector('[data-dm-message-form-target="input"]')

    if (!input) return

    input.focus()
    const start = input.selectionStart || 0
    const end = input.selectionEnd || 0
    const value = input.value || ""

    input.value = value.substring(0, start) + mention + value.substring(end)
    const newPos = start + mention.length
    input.setSelectionRange(newPos, newPos)

    // Trigger input event so Stimulus controllers pick up the change
    input.dispatchEvent(new Event("input", { bubbles: true }))
  }

  // --- Profile: open full overlay ---

  viewProfile(event) {
    event.preventDefault()
    event.stopPropagation()

    const userId = event.currentTarget.dataset.userId
    const serverId = event.currentTarget.dataset.serverId

    this.closeMenu()

    // Dispatch a custom event that notification_badge_controller listens for
    document.dispatchEvent(new CustomEvent("inferno:open-profile-overlay", {
      detail: { userId, serverId },
      bubbles: true
    }))
  }

  closeNicknameModal() {
    if (this.nicknameModal) {
      this.nicknameModal.remove()
      this.nicknameModal = null
    }
  }

  // --- Helpers ---

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  escapeAttr(text) {
    return text.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  showToast(message, type) {
    const toast = document.getElementById("toast")
    if (!toast) return
    toast.textContent = message
    toast.className = `fixed top-4 right-4 px-4 py-2 rounded-lg shadow-lg text-sm font-medium z-[100] transition-opacity duration-300 ${type === "success" ? "bg-green-600 text-white" : "bg-red-600 text-white"}`
    toast.classList.remove("hidden", "opacity-0")
    setTimeout(() => {
      toast.classList.add("opacity-0")
      setTimeout(() => toast.classList.add("hidden"), 300)
    }, 3000)
  }

  closeMenu(event) {
    if (this.rolesDropdown) {
      if (event && this.rolesDropdown.contains(event.target)) return
      this.rolesDropdown.remove()
      this.rolesDropdown = null
    }
    if (this.menu) {
      if (event && this.menu.contains(event.target)) return
      this.menu.remove()
      this.menu = null
    }
    document.removeEventListener("click", this.boundClose)
  }
}
