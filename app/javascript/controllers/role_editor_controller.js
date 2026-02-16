import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

const PERMISSION_GROUPS = {
  General: {
    read_messages: "View channels and read messages",
    read_message_history: "Read message history",
    create_invite: "Create invite links",
    change_nickname: "Change their own nickname in this server"
  },
  Text: {
    send_messages: "Send messages in text channels",
    attach_files: "Upload images and files",
    send_gifs: "Send GIFs in messages",
    add_reactions: "Add emoji reactions to messages",
    mention_everyone: "Use @everyone and @here mentions"
  },
  Expression: {
    send_custom_emojis: "Use custom server emojis in messages",
    send_custom_stickers: "Use custom server stickers in messages",
    create_emojis: "Upload custom emojis to the server",
    create_stickers: "Upload custom stickers to the server",
    manage_emojis: "Delete emojis and stickers uploaded by others"
  },
  Management: {
    manage_messages: "Delete or pin other members' messages",
    manage_channels: "Create, edit, and delete channels",
    manage_roles: "Create, edit, and reorder roles",
    manage_invites: "View and revoke invite links",
    manage_server: "Edit server name, icon, and settings"
  },
  Moderation: {
    kick_members: "Remove members from the server",
    ban_members: "Permanently ban members"
  },
  Dangerous: {
    administrator: "Full admin access — bypasses all permission checks"
  }
}

export default class extends Controller {
  static targets = [
    "rolesData", "roleList", "emptyState", "editorForm", "editorTitle",
    "deleteBtn", "nameInput", "colorInput", "colorHex", "permissionsSection",
    "saveBar", "roleName"
  ]
  static values = { serverId: String, canManage: Boolean }

  connect() {
    this.roles = JSON.parse(this.rolesDataTarget.textContent)
    this.selectedRoleId = null
    this.originalData = null
    this.dirty = false

    if (this.canManageValue) {
      this.sortable = Sortable.create(this.roleListTarget, {
        animation: 150,
        ghostClass: "opacity-20",
        chosenClass: "bg-gray-600",
        onEnd: () => this.handleReorder()
      })
    }
  }

  disconnect() {
    if (this.sortable) this.sortable.destroy()
  }

  selectRole(e) {
    const id = e.currentTarget.dataset.roleId
    if (id === this.selectedRoleId) return

    if (this.dirty) {
      if (!confirm("You have unsaved changes. Discard them?")) return
    }

    this.selectedRoleId = id
    const role = this.roles.find(r => r.id === id)
    if (!role) return

    this.originalData = JSON.parse(JSON.stringify(role))
    this.dirty = false
    this.saveBarTarget.classList.add("hidden")

    // Highlight selected role in list
    this.roleListTarget.querySelectorAll("[data-role-id]").forEach(el => {
      el.classList.toggle("bg-gray-600", el.dataset.roleId === id)
      el.classList.toggle("bg-gray-800", el.dataset.roleId !== id)
    })

    this.populateEditor(role)
  }

  populateEditor(role) {
    this.editorFormTarget.classList.remove("hidden")
    this.emptyStateTarget.classList.add("hidden")

    this.editorTitleTarget.textContent = role.name
    this.roleNameTarget.textContent = role.name

    // Show/hide delete button for system roles
    if (role.is_owner || role.is_everyone) {
      this.deleteBtnTarget.classList.add("hidden")
    } else {
      this.deleteBtnTarget.classList.remove("hidden")
    }

    // Name and color fields
    this.nameInputTarget.value = role.name
    this.colorInputTarget.value = role.color || "#99aab5"
    this.colorHexTarget.textContent = (role.color || "#99aab5").toUpperCase()

    // Disable name/color for @everyone
    const disableDisplay = role.is_everyone || role.is_owner
    this.nameInputTarget.disabled = disableDisplay
    this.colorInputTarget.disabled = disableDisplay
    if (disableDisplay) {
      this.nameInputTarget.classList.add("opacity-50")
      this.colorInputTarget.classList.add("opacity-50")
    } else {
      this.nameInputTarget.classList.remove("opacity-50")
      this.colorInputTarget.classList.remove("opacity-50")
    }

    // Hoist toggle
    const hoistToggle = this.element.querySelector("[data-hoist-toggle]")
    if (hoistToggle) {
      if (role.is_everyone || role.is_owner) {
        hoistToggle.closest("[data-hoist-row]").classList.add("hidden")
      } else {
        hoistToggle.closest("[data-hoist-row]").classList.remove("hidden")
        if (role.hoist) {
          hoistToggle.classList.remove("bg-gray-600")
          hoistToggle.classList.add("bg-orange-600")
          hoistToggle.firstElementChild.classList.remove("translate-x-0.5")
          hoistToggle.firstElementChild.classList.add("translate-x-5")
        } else {
          hoistToggle.classList.remove("bg-orange-600")
          hoistToggle.classList.add("bg-gray-600")
          hoistToggle.firstElementChild.classList.remove("translate-x-5")
          hoistToggle.firstElementChild.classList.add("translate-x-0.5")
        }
      }
    }

    this.renderPermissions(role)
  }

  renderPermissions(role) {
    const container = this.permissionsSectionTarget
    container.innerHTML = ""

    // Owner role: no permission editing
    if (role.is_owner) {
      container.innerHTML = '<p class="text-sm text-gray-500 italic">The Owner role has all permissions and cannot be edited.</p>'
      return
    }

    for (const [groupName, perms] of Object.entries(PERMISSION_GROUPS)) {
      // Skip manage_server for non-owner display (it's owner-only)
      const groupDiv = document.createElement("div")
      groupDiv.className = "mb-6"

      const heading = document.createElement("h4")
      heading.className = "text-xs font-bold text-gray-400 uppercase tracking-wide mb-3"
      heading.textContent = groupName
      groupDiv.appendChild(heading)

      for (const [key, description] of Object.entries(perms)) {
        const enabled = role.permissions && role.permissions[key] === true

        const row = document.createElement("div")
        row.className = "flex items-center justify-between py-2 border-b border-gray-700/50"

        const labelDiv = document.createElement("div")
        labelDiv.className = "flex-1 mr-4"

        const label = document.createElement("p")
        label.className = "text-sm text-white"
        label.textContent = key.replace(/_/g, " ").replace(/\b\w/g, c => c.toUpperCase())
        labelDiv.appendChild(label)

        const desc = document.createElement("p")
        desc.className = "text-xs text-gray-500"
        desc.textContent = description
        labelDiv.appendChild(desc)

        row.appendChild(labelDiv)

        // Toggle switch
        const toggle = document.createElement("button")
        toggle.type = "button"
        toggle.className = `relative w-11 h-6 rounded-full transition-colors focus:outline-none ${enabled ? "bg-orange-600" : "bg-gray-600"}`
        toggle.dataset.permission = key
        toggle.dataset.action = "click->role-editor#togglePermission"

        const knob = document.createElement("span")
        knob.className = `block w-5 h-5 bg-white rounded-full shadow transform transition-transform ${enabled ? "translate-x-5" : "translate-x-0.5"}`
        toggle.appendChild(knob)

        row.appendChild(toggle)
        groupDiv.appendChild(row)
      }

      container.appendChild(groupDiv)
    }
  }

  togglePermission(e) {
    const btn = e.currentTarget
    const key = btn.dataset.permission
    const role = this.roles.find(r => r.id === this.selectedRoleId)
    if (!role) return

    const newVal = !(role.permissions && role.permissions[key] === true)
    if (!role.permissions) role.permissions = {}
    role.permissions[key] = newVal

    // Update toggle visual
    if (newVal) {
      btn.classList.remove("bg-gray-600")
      btn.classList.add("bg-orange-600")
      btn.firstElementChild.classList.remove("translate-x-0.5")
      btn.firstElementChild.classList.add("translate-x-5")
    } else {
      btn.classList.remove("bg-orange-600")
      btn.classList.add("bg-gray-600")
      btn.firstElementChild.classList.remove("translate-x-5")
      btn.firstElementChild.classList.add("translate-x-0.5")
    }

    this.markDirty()
  }

  toggleHoist(e) {
    const btn = e.currentTarget
    const role = this.roles.find(r => r.id === this.selectedRoleId)
    if (!role) return

    role.hoist = !role.hoist

    if (role.hoist) {
      btn.classList.remove("bg-gray-600")
      btn.classList.add("bg-orange-600")
      btn.firstElementChild.classList.remove("translate-x-0.5")
      btn.firstElementChild.classList.add("translate-x-5")
    } else {
      btn.classList.remove("bg-orange-600")
      btn.classList.add("bg-gray-600")
      btn.firstElementChild.classList.remove("translate-x-5")
      btn.firstElementChild.classList.add("translate-x-0.5")
    }

    this.markDirty()
  }

  previewColor() {
    const color = this.colorInputTarget.value
    this.colorHexTarget.textContent = color.toUpperCase()

    // Update role in local data
    const role = this.roles.find(r => r.id === this.selectedRoleId)
    if (role) role.color = color

    // Update the color dot in the role list
    const listItem = this.roleListTarget.querySelector(`[data-role-id="${this.selectedRoleId}"]`)
    if (listItem) {
      const dot = listItem.querySelector("[data-color-dot]")
      if (dot) dot.style.backgroundColor = color
    }

    this.markDirty()
  }

  updateName() {
    const name = this.nameInputTarget.value
    const role = this.roles.find(r => r.id === this.selectedRoleId)
    if (role) role.name = name

    // Update name in left panel
    const listItem = this.roleListTarget.querySelector(`[data-role-id="${this.selectedRoleId}"]`)
    if (listItem) {
      const nameEl = listItem.querySelector("[data-role-name]")
      if (nameEl) nameEl.textContent = name
    }

    this.editorTitleTarget.textContent = name
    this.roleNameTarget.textContent = name
    this.markDirty()
  }

  markDirty() {
    this.dirty = true
    this.saveBarTarget.classList.remove("hidden")
  }

  resetChanges() {
    if (!this.originalData) return

    // Restore role data
    const idx = this.roles.findIndex(r => r.id === this.selectedRoleId)
    if (idx !== -1) {
      this.roles[idx] = JSON.parse(JSON.stringify(this.originalData))
    }

    this.dirty = false
    this.saveBarTarget.classList.add("hidden")
    this.populateEditor(this.roles[idx])

    // Restore color dot
    const listItem = this.roleListTarget.querySelector(`[data-role-id="${this.selectedRoleId}"]`)
    if (listItem) {
      const dot = listItem.querySelector("[data-color-dot]")
      if (dot) dot.style.backgroundColor = this.originalData.color || "#99aab5"
      const nameEl = listItem.querySelector("[data-role-name]")
      if (nameEl) nameEl.textContent = this.originalData.name
    }
  }

  async saveRole() {
    const role = this.roles.find(r => r.id === this.selectedRoleId)
    if (!role) return

    const csrf = document.querySelector("meta[name=csrf-token]")?.content

    try {
      const res = await fetch(`/servers/${this.serverIdValue}/roles/${role.id}`, {
        method: "PATCH",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
        body: JSON.stringify({
          name: role.name,
          color: role.color,
          hoist: role.hoist,
          permissions: role.permissions
        })
      })

      if (res.ok) {
        const updated = await res.json()
        const idx = this.roles.findIndex(r => r.id === this.selectedRoleId)
        if (idx !== -1) this.roles[idx] = updated
        this.originalData = JSON.parse(JSON.stringify(updated))
        this.dirty = false
        this.saveBarTarget.classList.add("hidden")
        this.showToast("Role saved!")
      } else {
        const data = await res.json()
        this.showToast(data.error || data.errors?.join(", ") || "Save failed", true)
      }
    } catch (err) {
      this.showToast("Network error", true)
    }
  }

  async createRole() {
    const csrf = document.querySelector("meta[name=csrf-token]")?.content

    try {
      const res = await fetch(`/servers/${this.serverIdValue}/roles`, {
        method: "POST",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
        body: JSON.stringify({})
      })

      if (res.ok) {
        const role = await res.json()
        this.roles.push(role)
        this.appendRoleToList(role)

        // Auto-select the new role
        this.selectedRoleId = role.id
        this.originalData = JSON.parse(JSON.stringify(role))
        this.dirty = false
        this.saveBarTarget.classList.add("hidden")

        // Highlight it
        this.roleListTarget.querySelectorAll("[data-role-id]").forEach(el => {
          el.classList.toggle("bg-gray-600", el.dataset.roleId === role.id)
          el.classList.toggle("bg-gray-800", el.dataset.roleId !== role.id)
        })

        this.populateEditor(role)
        this.showToast("Role created!")
      } else {
        const data = await res.json()
        this.showToast(data.errors?.join(", ") || "Create failed", true)
      }
    } catch (err) {
      this.showToast("Network error", true)
    }
  }

  async deleteRole() {
    const role = this.roles.find(r => r.id === this.selectedRoleId)
    if (!role || role.is_owner || role.is_everyone) return

    if (!confirm(`Delete "${role.name}"? Members with this role will be moved to @everyone.`)) return

    const csrf = document.querySelector("meta[name=csrf-token]")?.content

    try {
      const res = await fetch(`/servers/${this.serverIdValue}/roles/${role.id}`, {
        method: "DELETE",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      })

      if (res.ok) {
        this.roles = this.roles.filter(r => r.id !== role.id)

        // Remove from DOM
        const listItem = this.roleListTarget.querySelector(`[data-role-id="${role.id}"]`)
        if (listItem) listItem.remove()

        // Reset editor
        this.selectedRoleId = null
        this.originalData = null
        this.dirty = false
        this.editorFormTarget.classList.add("hidden")
        this.emptyStateTarget.classList.remove("hidden")
        this.saveBarTarget.classList.add("hidden")

        this.showToast("Role deleted!")
      } else {
        const data = await res.json()
        this.showToast(data.error || "Delete failed", true)
      }
    } catch (err) {
      this.showToast("Network error", true)
    }
  }

  async handleReorder() {
    const items = this.roleListTarget.querySelectorAll("[data-role-id]")
    const rolesPayload = []

    // Roles are displayed top-to-bottom by highest position first.
    // So first item in DOM gets the highest position.
    const sortableItems = Array.from(items)
    const maxPos = sortableItems.length
    sortableItems.forEach((el, idx) => {
      const pos = maxPos - idx
      rolesPayload.push({ id: el.dataset.roleId, position: pos })
      // Update in-memory role positions
      const role = this.roles.find(r => r.id === el.dataset.roleId)
      if (role) role.position = pos
    })

    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    try {
      const res = await fetch(`/servers/${this.serverIdValue}/reorder_roles`, {
        method: "PATCH",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
        body: JSON.stringify({ roles: rolesPayload })
      })
      if (res.ok) {
        this.showToast("Role order saved!")
      } else {
        this.showToast("Failed to save order", true)
      }
    } catch (err) {
      this.showToast("Network error", true)
    }
  }

  appendRoleToList(role) {
    const item = document.createElement("div")
    item.className = "flex items-center px-3 py-2 rounded cursor-pointer bg-gray-800 hover:bg-gray-700 transition-colors"
    item.dataset.roleId = role.id
    item.dataset.action = "click->role-editor#selectRole"

    item.innerHTML = `
      <span class="w-3 h-3 rounded-full mr-3 shrink-0" data-color-dot style="background-color: ${this.escapeHtml(role.color || "#99aab5")}"></span>
      <span class="flex-1 text-sm text-white truncate" data-role-name>${this.escapeHtml(role.name)}</span>
      <span class="text-xs text-gray-500 ml-2">${role.member_count}</span>
    `

    // Insert before @everyone (last item) or at end
    const everyoneItem = Array.from(this.roleListTarget.children).find(el => {
      const role = this.roles.find(r => r.id === el.dataset.roleId)
      return role && role.is_everyone
    })
    if (everyoneItem) {
      this.roleListTarget.insertBefore(item, everyoneItem)
    } else {
      this.roleListTarget.appendChild(item)
    }
  }

  escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  }

  showToast(msg, isError = false) {
    const toast = document.createElement("div")
    toast.className = `fixed bottom-6 right-6 ${isError ? "bg-red-600" : "bg-green-600"} text-white px-4 py-2 rounded-lg shadow-lg z-[200] text-sm font-medium`
    toast.textContent = msg
    document.body.appendChild(toast)
    setTimeout(() => toast.remove(), 2000)
  }
}
