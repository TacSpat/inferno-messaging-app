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
  Voice: {
    connect_voice: "Join voice channels",
    speak: "Speak in voice channels",
    video: "Send video in voice channels",
    screen_share: "Share their screen in voice channels",
    mute_members: "Server-mute other members in voice",
    deafen_members: "Server-deafen other members in voice",
    move_members: "Move members between voice channels"
  },
  Dangerous: {
    administrator: "Full admin access — bypasses all permission checks"
  }
}

// --- Color conversion helpers ---
function hsvToRgb(h, s, v) {
  let r, g, b
  const i = Math.floor(h * 6)
  const f = h * 6 - i
  const p = v * (1 - s)
  const q = v * (1 - f * s)
  const t = v * (1 - (1 - f) * s)
  switch (i % 6) {
    case 0: r = v; g = t; b = p; break
    case 1: r = q; g = v; b = p; break
    case 2: r = p; g = v; b = t; break
    case 3: r = p; g = q; b = v; break
    case 4: r = t; g = p; b = v; break
    case 5: r = v; g = p; b = q; break
  }
  return [Math.round(r * 255), Math.round(g * 255), Math.round(b * 255)]
}

function rgbToHsv(r, g, b) {
  r /= 255; g /= 255; b /= 255
  const max = Math.max(r, g, b), min = Math.min(r, g, b)
  const d = max - min
  let h = 0, s = max === 0 ? 0 : d / max, v = max
  if (d !== 0) {
    switch (max) {
      case r: h = ((g - b) / d + (g < b ? 6 : 0)) / 6; break
      case g: h = ((b - r) / d + 2) / 6; break
      case b: h = ((r - g) / d + 4) / 6; break
    }
  }
  return [h, s, v]
}

function hexToRgb(hex) {
  hex = hex.replace("#", "")
  if (hex.length === 3) hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2]
  const n = parseInt(hex, 16)
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255]
}

function rgbToHex(r, g, b) {
  return "#" + [r, g, b].map(c => c.toString(16).padStart(2, "0")).join("")
}

export default class extends Controller {
  static targets = [
    "rolesData", "roleList", "emptyState", "editorForm", "editorTitle",
    "deleteBtn", "nameInput", "colorHexInput", "colorPreviewSwatch",
    "colorSection", "swatchGrid", "permissionsSection",
    "saveBar",
    "previewName", "previewMsgName", "previewGroupLabel",
    "pickerCollapse", "svField", "svCanvas", "svCursor", "hueTrack", "hueCursor",
    "tabDisplay", "tabPermissions", "tabMembers",
    "panelDisplay", "panelPermissions", "panelMembers",
    "memberSearchInput", "memberCountLabel", "memberList"
  ]
  static values = {
    serverId: String,
    canManage: Boolean,
    previewName: String,
    previewAvatar: String,
    previewInitial: String,
    previewColor: String
  }

  connect() {
    this.roles = JSON.parse(this.rolesDataTarget.textContent)
    this.selectedRoleId = null
    this.originalData = null
    this.dirty = false
    this.hsv = [0, 1, 1]
    this._svDragging = false
    this._hueDragging = false
    this._pickerOpen = false
    this._activeTab = "display"
    this._searchTimeout = null
    this._membersCache = null

    if (this.canManageValue) {
      this.sortable = Sortable.create(this.roleListTarget, {
        animation: 150,
        ghostClass: "opacity-20",
        chosenClass: "bg-gray-600",
        onEnd: () => this.handleReorder()
      })
    }

    // Global pointer handlers for dragging
    this._onPointerMove = this._onPointerMove.bind(this)
    this._onPointerUp = this._onPointerUp.bind(this)
    document.addEventListener("pointermove", this._onPointerMove)
    document.addEventListener("pointerup", this._onPointerUp)
  }

  disconnect() {
    if (this.sortable) this.sortable.destroy()
    document.removeEventListener("pointermove", this._onPointerMove)
    document.removeEventListener("pointerup", this._onPointerUp)
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

    // Delete button
    if (role.undeletable) {
      this.deleteBtnTarget.classList.add("hidden")
    } else {
      this.deleteBtnTarget.classList.remove("hidden")
    }

    // Name field — fully reset state before applying
    const nameDisabled = role.is_everyone || role.is_owner
    this.nameInputTarget.disabled = false
    this.nameInputTarget.classList.remove("opacity-50")
    this.nameInputTarget.value = role.name
    if (nameDisabled) {
      this.nameInputTarget.disabled = true
      this.nameInputTarget.classList.add("opacity-50")
    }

    // Color section
    if (role.is_owner) {
      this.colorSectionTarget.classList.add("hidden")
    } else {
      this.colorSectionTarget.classList.remove("hidden")
      this.setColorUI(role.color || "#99aab5")
    }

    // Reset to display tab when switching roles
    this._activeTab = "display"
    this.panelDisplayTarget.classList.remove("hidden")
    this.panelPermissionsTarget.classList.add("hidden")
    this.panelMembersTarget.classList.add("hidden")
    this.tabDisplayTarget.classList.add("border-white", "text-white")
    this.tabDisplayTarget.classList.remove("border-transparent", "text-gray-400")
    this.tabPermissionsTarget.classList.remove("border-white", "text-white")
    this.tabPermissionsTarget.classList.add("border-transparent", "text-gray-400")
    this.tabMembersTarget.classList.remove("border-white", "text-white")
    this.tabMembersTarget.classList.add("border-transparent", "text-gray-400")
    // Hide members tab for @everyone (all members implicitly have it)
    if (role.is_everyone) {
      this.tabMembersTarget.classList.add("hidden")
    } else {
      this.tabMembersTarget.classList.remove("hidden")
    }

    // Clear member tab state
    if (this.hasMemberSearchInputTarget) this.memberSearchInputTarget.value = ""
    if (this.hasMemberListTarget) this.memberListTarget.innerHTML = ""
    if (this.hasMemberCountLabelTarget) this.memberCountLabelTarget.textContent = ""
    this._membersCache = null

    // Collapse custom picker when switching roles
    this._closePicker()

    // Hoist toggle
    const hoistToggle = this.element.querySelector("[data-hoist-toggle]")
    if (hoistToggle) {
      if (role.is_everyone || role.is_owner) {
        hoistToggle.closest("[data-hoist-row]").classList.add("hidden")
      } else {
        hoistToggle.closest("[data-hoist-row]").classList.remove("hidden")
        this.setToggle(hoistToggle, role.hoist)
      }
    }

    this.updatePreview(role.color || "#99aab5", role.name)
    this.renderPermissions(role)
  }

  // ===== Color Picker =====

  setColorUI(color) {
    this.colorHexInputTarget.value = color.replace("#", "").toUpperCase()
    this.colorPreviewSwatchTarget.style.backgroundColor = color

    // Highlight matching swatch
    this.swatchGridTarget.querySelectorAll("[data-swatch]").forEach(btn => {
      const matches = btn.dataset.swatch.toLowerCase() === color.toLowerCase()
      btn.classList.toggle("border-white", matches)
      btn.classList.toggle("scale-110", matches)
      btn.classList.toggle("z-10", matches)
      btn.classList.toggle("border-transparent", !matches)
    })

    // Sync HSV state
    const [r, g, b] = hexToRgb(color)
    this.hsv = rgbToHsv(r, g, b)
  }

  pickSwatch(e) {
    const color = e.currentTarget.dataset.swatch
    this._applyColor(color)
  }

  hexInput() {
    let val = this.colorHexInputTarget.value.replace(/[^0-9a-fA-F]/g, "").substring(0, 6)
    this.colorHexInputTarget.value = val.toUpperCase()
    if (val.length === 6) {
      this._applyColor(`#${val}`)
    }
  }

  hexCommit() {
    let val = this.colorHexInputTarget.value.replace(/[^0-9a-fA-F]/g, "")
    if (val.length === 3) val = val[0] + val[0] + val[1] + val[1] + val[2] + val[2]
    if (val.length < 6) val = val.padEnd(6, "0")
    val = val.substring(0, 6)
    this._applyColor(`#${val}`)
  }

  _applyColor(color) {
    const role = this.roles.find(r => r.id === this.selectedRoleId)
    if (role) role.color = color

    this.colorHexInputTarget.value = color.replace("#", "").toUpperCase()
    this.colorPreviewSwatchTarget.style.backgroundColor = color
    this.updateColorDot(color)
    this.updatePreview(color, role?.name)

    // Highlight matching swatch
    this.swatchGridTarget.querySelectorAll("[data-swatch]").forEach(btn => {
      const matches = btn.dataset.swatch.toLowerCase() === color.toLowerCase()
      btn.classList.toggle("border-white", matches)
      btn.classList.toggle("scale-110", matches)
      btn.classList.toggle("z-10", matches)
      btn.classList.toggle("border-transparent", !matches)
    })

    // Update HSV + canvas if picker is open
    const [r, g, b] = hexToRgb(color)
    this.hsv = rgbToHsv(r, g, b)
    if (this._pickerOpen) {
      this._drawSV()
      this._positionSVCursor()
      this._positionHueCursor()
    }

    this.markDirty()
  }

  // --- Collapsible custom picker ---

  toggleCustomPicker() {
    if (this._pickerOpen) {
      this._closePicker()
    } else {
      this._openPicker()
    }
  }

  _openPicker() {
    this._pickerOpen = true
    const el = this.pickerCollapseTarget
    el.style.gridTemplateRows = "1fr"

    // Init HSV from current color
    const role = this.roles.find(r => r.id === this.selectedRoleId)
    const color = role?.color || "#99aab5"
    const [r, g, b] = hexToRgb(color)
    this.hsv = rgbToHsv(r, g, b)

    requestAnimationFrame(() => {
      this._initCanvas()
      this._drawSV()
      this._positionSVCursor()
      this._positionHueCursor()
    })
  }

  _closePicker() {
    this._pickerOpen = false
    if (this.hasPickerCollapseTarget) {
      this.pickerCollapseTarget.style.gridTemplateRows = "0fr"
    }
  }

  _initCanvas() {
    const canvas = this.svCanvasTarget
    const rect = this.svFieldTarget.getBoundingClientRect()
    canvas.width = rect.width
    canvas.height = rect.height
  }

  _drawSV() {
    const canvas = this.svCanvasTarget
    const ctx = canvas.getContext("2d")
    const w = canvas.width, h = canvas.height

    // Base hue color
    const [r, g, b] = hsvToRgb(this.hsv[0], 1, 1)
    ctx.fillStyle = `rgb(${r},${g},${b})`
    ctx.fillRect(0, 0, w, h)

    // White gradient (left to right)
    const whiteGrad = ctx.createLinearGradient(0, 0, w, 0)
    whiteGrad.addColorStop(0, "rgba(255,255,255,1)")
    whiteGrad.addColorStop(1, "rgba(255,255,255,0)")
    ctx.fillStyle = whiteGrad
    ctx.fillRect(0, 0, w, h)

    // Black gradient (top to bottom)
    const blackGrad = ctx.createLinearGradient(0, 0, 0, h)
    blackGrad.addColorStop(0, "rgba(0,0,0,0)")
    blackGrad.addColorStop(1, "rgba(0,0,0,1)")
    ctx.fillStyle = blackGrad
    ctx.fillRect(0, 0, w, h)
  }

  _positionSVCursor() {
    const cursor = this.svCursorTarget
    const [, s, v] = this.hsv
    cursor.style.left = `${s * 100}%`
    cursor.style.top = `${(1 - v) * 100}%`

    // Set cursor color to contrast with background
    const [r, g, b] = hsvToRgb(this.hsv[0], s, v)
    cursor.style.backgroundColor = rgbToHex(r, g, b)
  }

  _positionHueCursor() {
    this.hueCursorTarget.style.left = `${this.hsv[0] * 100}%`
    const [r, g, b] = hsvToRgb(this.hsv[0], 1, 1)
    this.hueCursorTarget.style.backgroundColor = rgbToHex(r, g, b)
  }

  // --- SV field dragging ---

  svDown(e) {
    e.preventDefault()
    this._svDragging = true
    this.svFieldTarget.setPointerCapture(e.pointerId)
    this._updateSV(e)
  }

  _updateSV(e) {
    const rect = this.svFieldTarget.getBoundingClientRect()
    const s = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width))
    const v = Math.max(0, Math.min(1, 1 - (e.clientY - rect.top) / rect.height))
    this.hsv[1] = s
    this.hsv[2] = v
    this._positionSVCursor()
    this._emitColorFromHSV()
  }

  // --- Hue slider dragging ---

  hueDown(e) {
    e.preventDefault()
    this._hueDragging = true
    this.hueTrackTarget.setPointerCapture(e.pointerId)
    this._updateHue(e)
  }

  _updateHue(e) {
    const rect = this.hueTrackTarget.getBoundingClientRect()
    const h = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width))
    this.hsv[0] = h
    this._drawSV()
    this._positionSVCursor()
    this._positionHueCursor()
    this._emitColorFromHSV()
  }

  // --- Global pointer events ---

  _onPointerMove(e) {
    if (this._svDragging) this._updateSV(e)
    if (this._hueDragging) this._updateHue(e)
  }

  _onPointerUp() {
    this._svDragging = false
    this._hueDragging = false
  }

  _emitColorFromHSV() {
    const [r, g, b] = hsvToRgb(this.hsv[0], this.hsv[1], this.hsv[2])
    const hex = rgbToHex(r, g, b)

    const role = this.roles.find(r => r.id === this.selectedRoleId)
    if (role) role.color = hex

    this.colorHexInputTarget.value = hex.replace("#", "").toUpperCase()
    this.colorPreviewSwatchTarget.style.backgroundColor = hex
    this.updateColorDot(hex)
    this.updatePreview(hex, role?.name)

    // Swatch selection
    this.swatchGridTarget.querySelectorAll("[data-swatch]").forEach(btn => {
      const matches = btn.dataset.swatch.toLowerCase() === hex.toLowerCase()
      btn.classList.toggle("border-white", matches)
      btn.classList.toggle("scale-110", matches)
      btn.classList.toggle("z-10", matches)
      btn.classList.toggle("border-transparent", !matches)
    })

    this.markDirty()
  }


  // ===== Shared helpers =====

  updateColorDot(color) {
    const listItem = this.roleListTarget.querySelector(`[data-role-id="${this.selectedRoleId}"]`)
    if (listItem) {
      const dot = listItem.querySelector("[data-color-dot]")
      if (dot) dot.style.backgroundColor = color
    }
  }

  updatePreview(color, roleName) {
    if (this.hasPreviewNameTarget) this.previewNameTarget.style.color = color
    if (this.hasPreviewMsgNameTarget) this.previewMsgNameTarget.style.color = color
    if (this.hasPreviewGroupLabelTarget) {
      this.previewGroupLabelTarget.style.color = color
      this.previewGroupLabelTarget.textContent = `${roleName || "Role"} — 1`
    }
  }

  setToggle(btn, active) {
    if (active) {
      btn.classList.remove("bg-gray-600")
      btn.classList.add("bg-toggle-on")
      btn.firstElementChild.classList.remove("translate-x-0.5")
      btn.firstElementChild.classList.add("translate-x-5")
    } else {
      btn.classList.remove("bg-toggle-on")
      btn.classList.add("bg-gray-600")
      btn.firstElementChild.classList.remove("translate-x-5")
      btn.firstElementChild.classList.add("translate-x-0.5")
    }
  }

  // ===== Permissions =====

  renderPermissions(role) {
    const container = this.permissionsSectionTarget
    container.innerHTML = ""

    if (role.is_owner) {
      container.innerHTML = '<p class="text-sm text-gray-500 italic">The Owner role has all permissions and cannot be edited.</p>'
      return
    }

    const rowTemplate = document.getElementById("tpl-permission-row")
    if (!rowTemplate) {
      container.innerHTML = '<p class="text-sm text-gray-500 italic">Permission template not found.</p>'
      return
    }

    for (const [groupName, perms] of Object.entries(PERMISSION_GROUPS)) {
      const groupDiv = document.createElement("div")
      groupDiv.className = "mb-6"

      const heading = document.createElement("h4")
      heading.className = "text-xs font-bold text-gray-400 uppercase tracking-wide mb-3"
      heading.textContent = groupName
      groupDiv.appendChild(heading)

      for (const [key, description] of Object.entries(perms)) {
        const enabled = role.permissions && role.permissions[key] === true

        const clone = rowTemplate.content.cloneNode(true)
        clone.querySelector('[data-slot="label"]').textContent = key.replace(/_/g, " ").replace(/\b\w/g, c => c.toUpperCase())
        clone.querySelector('[data-slot="description"]').textContent = description

        const toggle = clone.querySelector('[data-slot="toggle"]')
        toggle.dataset.permission = key
        toggle.dataset.action = "click->role-editor#togglePermission"

        if (enabled) this.setToggle(toggle, true)

        groupDiv.appendChild(clone)
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

    this.setToggle(btn, newVal)
    this.markDirty()
  }

  toggleHoist(e) {
    const btn = e.currentTarget
    const role = this.roles.find(r => r.id === this.selectedRoleId)
    if (!role) return

    role.hoist = !role.hoist
    this.setToggle(btn, role.hoist)
    this.markDirty()
  }

  // ===== Name =====

  updateName() {
    const name = this.nameInputTarget.value
    const role = this.roles.find(r => r.id === this.selectedRoleId)
    if (role) role.name = name

    const listItem = this.roleListTarget.querySelector(`[data-role-id="${this.selectedRoleId}"]`)
    if (listItem) {
      const nameEl = listItem.querySelector("[data-role-name]")
      if (nameEl) nameEl.textContent = name
    }

    this.editorTitleTarget.textContent = name
    this.updatePreview(role?.color || "#99aab5", name)
    this.markDirty()
  }

  // ===== Dirty state =====

  markDirty() {
    this.dirty = true
    this.saveBarTarget.classList.remove("hidden")
  }

  resetChanges() {
    if (!this.originalData) return

    const idx = this.roles.findIndex(r => r.id === this.selectedRoleId)
    if (idx !== -1) {
      this.roles[idx] = JSON.parse(JSON.stringify(this.originalData))
    }

    this.dirty = false
    this.saveBarTarget.classList.add("hidden")
    this.populateEditor(this.roles[idx])

    const listItem = this.roleListTarget.querySelector(`[data-role-id="${this.selectedRoleId}"]`)
    if (listItem) {
      const dot = listItem.querySelector("[data-color-dot]")
      if (dot) dot.style.backgroundColor = this.originalData.color || "#99aab5"
      const nameEl = listItem.querySelector("[data-role-name]")
      if (nameEl) nameEl.textContent = this.originalData.name
    }
  }

  // ===== CRUD =====

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
        this.populateEditor(updated)
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

        this.selectedRoleId = role.id
        this.originalData = JSON.parse(JSON.stringify(role))
        this.dirty = false
        this.saveBarTarget.classList.add("hidden")

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
    if (!role || role.undeletable) return

    if (!confirm(`Delete "${role.name}"? Members with this role will lose it.`)) return

    const csrf = document.querySelector("meta[name=csrf-token]")?.content

    try {
      const res = await fetch(`/servers/${this.serverIdValue}/roles/${role.id}`, {
        method: "DELETE",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      })

      if (res.ok) {
        this.roles = this.roles.filter(r => r.id !== role.id)

        const listItem = this.roleListTarget.querySelector(`[data-role-id="${role.id}"]`)
        if (listItem) listItem.remove()

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

    const sortableItems = Array.from(items)
    const maxPos = sortableItems.length
    sortableItems.forEach((el, idx) => {
      const pos = maxPos - idx
      rolesPayload.push({ id: el.dataset.roleId, position: pos })
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
    const clone = document.getElementById("tpl-role-list-item").content.cloneNode(true)
    const item = clone.firstElementChild

    item.dataset.roleId = role.id
    item.dataset.action = "click->role-editor#selectRole"
    item.querySelector("[data-color-dot]").style.backgroundColor = role.color || "#99aab5"
    item.querySelector("[data-role-name]").textContent = role.name
    item.querySelector('[data-slot="member-count"]').textContent = role.member_count

    const everyoneItem = Array.from(this.roleListTarget.children).find(el => {
      const r = this.roles.find(rr => rr.id === el.dataset.roleId)
      return r && r.is_everyone
    })
    if (everyoneItem) {
      this.roleListTarget.insertBefore(item, everyoneItem)
    } else {
      this.roleListTarget.appendChild(item)
    }
  }

  // ===== Tabs =====

  switchTab(e) {
    const tab = e.currentTarget.dataset.tab
    if (tab === this._activeTab) return
    this._activeTab = tab

    const tabs = [
      { btn: this.tabDisplayTarget, panel: this.panelDisplayTarget, name: "display" },
      { btn: this.tabPermissionsTarget, panel: this.panelPermissionsTarget, name: "permissions" },
      { btn: this.tabMembersTarget, panel: this.panelMembersTarget, name: "members" }
    ]

    tabs.forEach(({ btn, panel, name }) => {
      const active = name === tab
      panel.classList.toggle("hidden", !active)
      btn.classList.toggle("border-white", active)
      btn.classList.toggle("text-white", active)
      btn.classList.toggle("border-transparent", !active)
      btn.classList.toggle("text-gray-400", !active)
    })

    if (tab === "members") this.loadRoleMembers()
    if (tab === "permissions") this.renderPermissions(this.roles.find(r => r.id === this.selectedRoleId))
  }

  // ===== Members Tab =====

  async loadRoleMembers() {
    const role = this.roles.find(r => r.id === this.selectedRoleId)
    if (!role) return

    try {
      const res = await fetch(`/servers/${this.serverIdValue}/roles/${role.id}/members`)
      if (!res.ok) return

      this._membersCache = await res.json()
      this._renderMemberList()
    } catch (err) {
      console.error("Failed to load role members:", err)
    }
  }

  searchMembers() {
    clearTimeout(this._searchTimeout)
    this._searchTimeout = setTimeout(() => this._renderMemberList(), 150)
  }

  _renderMemberList() {
    if (!this._membersCache) return
    const q = (this.memberSearchInputTarget.value || "").trim().toLowerCase()
    const filtered = q
      ? this._membersCache.filter(m =>
          m.display_name.toLowerCase().includes(q) ||
          m.username.toLowerCase().includes(q))
      : this._membersCache

    const withRole = filtered.filter(m => m.has_role).length
    this.memberCountLabelTarget.textContent = `${withRole} assigned`

    // Update sidebar count
    const role = this.roles.find(r => r.id === this.selectedRoleId)
    if (role) {
      const listItem = this.roleListTarget.querySelector(`[data-role-id="${role.id}"]`)
      if (listItem) {
        const countEl = listItem.querySelector(".text-xs.text-gray-500")
        if (countEl) countEl.textContent = this._membersCache.filter(m => m.has_role).length
      }
    }

    this.memberListTarget.innerHTML = ""
    filtered.forEach(m => {
      this.memberListTarget.appendChild(this._buildMemberRow(m))
    })
  }

  async toggleMember(e) {
    const btn = e.currentTarget
    const userId = btn.dataset.userId
    const role = this.roles.find(r => r.id === this.selectedRoleId)
    if (!role) return

    const csrf = document.querySelector("meta[name=csrf-token]")?.content

    try {
      const res = await fetch(`/servers/${this.serverIdValue}/roles/${role.id}/toggle_member`, {
        method: "POST",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
        body: JSON.stringify({ user_id: userId })
      })

      if (res.ok) {
        const data = await res.json()
        role.member_count = data.member_count

        // Update local cache
        const member = this._membersCache?.find(m => m.user_id === userId)
        if (member) {
          member.has_role = data.action === "added"
          this._renderMemberList()
        }
      } else {
        const data = await res.json()
        this.showToast(data.error || "Failed to update member", true)
      }
    } catch (err) {
      this.showToast("Network error", true)
    }
  }

  _buildMemberRow(member) {
    const row = document.createElement("div")
    row.className = "flex items-center gap-3 px-3 py-2 rounded hover:bg-gray-700/50 transition-colors"

    const avatar = this._buildAvatar(member)
    row.appendChild(avatar)

    const info = document.createElement("div")
    info.className = "flex-1 min-w-0"
    const nameEl = document.createElement("p")
    nameEl.className = "text-sm text-white truncate"
    nameEl.textContent = member.display_name
    info.appendChild(nameEl)
    const usernameEl = document.createElement("p")
    usernameEl.className = "text-xs text-gray-500 truncate"
    usernameEl.textContent = member.username
    info.appendChild(usernameEl)
    row.appendChild(info)

    // Toggle checkbox
    const toggle = document.createElement("button")
    toggle.type = "button"
    toggle.dataset.userId = member.user_id
    toggle.dataset.action = "click->role-editor#toggleMember"
    toggle.className = `relative w-11 h-6 rounded-full transition-colors focus:outline-none shrink-0 ${member.has_role ? "bg-toggle-on" : "bg-gray-600"}`
    const knob = document.createElement("span")
    knob.className = `block w-5 h-5 bg-white rounded-full shadow transform transition-transform ${member.has_role ? "translate-x-5" : "translate-x-0.5"}`
    toggle.appendChild(knob)
    row.appendChild(toggle)

    return row
  }

  _buildAvatar(member) {
    if (member.avatar_url) {
      const img = document.createElement("img")
      img.src = member.avatar_url
      img.className = "w-8 h-8 rounded-full object-cover shrink-0"
      return img
    }
    const div = document.createElement("div")
    div.className = "w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold text-white shrink-0"
    div.style.backgroundColor = member.profile_color
    div.textContent = (member.username || "?")[0].toUpperCase()
    return div
  }

  showToast(msg, isError = false) {
    const toast = document.createElement("div")
    toast.className = `fixed bottom-6 right-6 ${isError ? "bg-toggle-on" : "bg-green-600"} text-white px-4 py-2 rounded-lg shadow-lg z-[200] text-sm font-medium context-pop`
    toast.textContent = msg
    document.body.appendChild(toast)
    setTimeout(() => {
      toast.style.transition = "opacity 0.3s"
      toast.style.opacity = "0"
      setTimeout(() => toast.remove(), 300)
    }, 2000)
  }
}
