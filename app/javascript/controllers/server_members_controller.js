import { Controller } from "@hotwired/stimulus"
import consumer from "../lib/cable"

export default class extends Controller {
  static values = { serverId: String }
  static targets = ["list"]

  connect() {
    this.subscription = consumer.subscriptions.create(
      { channel: "ServerChannel", server_id: this.serverIdValue },
      {
        received: (data) => this.handleMessage(data)
      }
    )
  }

  disconnect() {
    if (this.subscription) this.subscription.unsubscribe()
  }

  handleMessage(data) {
    switch (data.type) {
      case "member_join":
        this.addMember(data)
        break
      case "member_leave":
        this.removeMember(data)
        break
      case "presence":
        this.updatePresence(data)
        break
      case "presence_sync":
        this.syncPresence(data)
        break
      case "member_update":
        this.updateMember(data)
        break
      case "member_timeout":
        this.handleMemberTimeout(data)
        break
      case "roles_updated":
        this.refreshMemberList()
        if (data.color_map) this.applyRoleColors(data.color_map)
        break
    }
  }

  addMember(data) {
    if (!this.hasListTarget) return
    const existing = this.listTarget.querySelector(`[data-user-id="${data.user_id}"]`)
    if (existing) return

    // Parse the incoming HTML to get the member's group
    const temp = document.createElement("div")
    temp.innerHTML = data.html
    const memberEl = temp.firstElementChild
    if (!memberEl) return

    const group = memberEl.getAttribute("data-member-group") || "online"
    this.insertMemberInGroup(memberEl, group)
    this.recountAllGroups()
  }

  removeMember(data) {
    if (!this.hasListTarget) return
    const el = this.listTarget.querySelector(`[data-user-id="${data.user_id}"]`)
    if (el) {
      el.remove()
      this.recountAllGroups()
    }
  }

  syncPresence(data) {
    if (!this.hasListTarget || !data.members) return

    // Build a set of online user IDs for quick lookup
    const onlineMap = new Map()
    data.members.forEach(m => onlineMap.set(String(m.user_id), m.state))

    // Update every member element in the list
    this.listTarget.querySelectorAll("[data-user-id]").forEach(el => {
      const userId = el.dataset.userId
      const state = onlineMap.get(String(userId)) || "offline"
      this.updatePresence({ user_id: userId, state: state })
    })
  }

  updatePresence(data) {
    if (!this.hasListTarget) return
    const el = this.listTarget.querySelector(`[data-user-id="${data.user_id}"]`)
    if (!el) return

    // Update status dot color
    const dot = el.querySelector('.rounded-full.border-2')
    if (dot) {
      dot.classList.remove('bg-green-500', 'bg-warning', 'bg-red-500', 'bg-gray-500')
      const colorMap = { online: 'bg-green-500', idle: 'bg-warning', dnd: 'bg-red-500', offline: 'bg-gray-500' }
      dot.classList.add(colorMap[data.state] || 'bg-gray-500')
    }

    const isOffline = data.state === "offline" || data.state === "invisible"

    // Update opacity
    if (isOffline) {
      el.classList.add('opacity-40')
    } else {
      el.classList.remove('opacity-40')
    }

    // Determine target group
    let targetGroup
    if (isOffline) {
      targetGroup = "offline"
      el.setAttribute("data-member-group", "offline")
    } else {
      // When coming online, restore the member's role-based group
      const roleGroup = el.getAttribute("data-role-group") || "online"
      targetGroup = roleGroup
      el.setAttribute("data-member-group", roleGroup)
    }

    // Move to the correct group with alphabetical insertion
    this.moveMemberToGroup(el, targetGroup)
    this.recountAllGroups()
  }

  updateMember(data) {
    if (!this.hasListTarget) return
    const el = this.listTarget.querySelector(`[data-user-id="${data.user_id}"]`)
    if (el && data.html) {
      // Parse the new HTML to get the updated group
      const temp = document.createElement("div")
      temp.innerHTML = data.html
      const newEl = temp.firstElementChild
      if (newEl) {
        const newGroup = newEl.getAttribute("data-member-group") || "online"
        el.outerHTML = data.html
        // Re-query the element after replacing
        const updatedEl = this.listTarget.querySelector(`[data-user-id="${data.user_id}"]`)
        if (updatedEl) {
          this.moveMemberToGroup(updatedEl, newGroup)
        }
        this.recountAllGroups()
      }
    }
    // Update display names and role colors in chat message history
    document.querySelectorAll(`[data-author-id="${data.user_id}"]`).forEach(msgEl => {
      const nameSpan = msgEl.querySelector(".font-medium.hover\\:underline")
      if (nameSpan) {
        if (data.display_name) nameSpan.textContent = data.display_name
        if (data.role_color) nameSpan.style.color = data.role_color
      }
    })
    // Also update skeleton names for remote members (matched by pubkey)
    if (data.pubkey && data.display_name) {
      document.querySelectorAll(`[data-nostr-pubkey="${data.pubkey}"]`).forEach(el => {
        el.textContent = data.display_name
        el.classList.remove("skeleton-shimmer")
        el.removeAttribute("data-nostr-pubkey")
        if (data.role_color) el.style.color = data.role_color
      })
    }
    // Update own user panel (bottom-left) if it's the current user
    const currentUserId = document.body.dataset.currentUserId
    if (String(data.user_id) === String(currentUserId)) {
      const panel = document.querySelector("[style*='1a1b1e']")
      if (panel) {
        const nameEl = panel.querySelector(".text-white.truncate")
        if (nameEl && data.display_name) nameEl.textContent = data.display_name
        const tagEl = panel.querySelector(".text-gray-400.truncate")
        if (tagEl && data.tag) tagEl.textContent = data.tag
      }
    }
  }

  handleMemberTimeout(data) {
    // Dispatch custom event for message form controller to pick up
    document.dispatchEvent(new CustomEvent("inferno:member-timeout", {
      detail: {
        user_id: data.user_id,
        timed_out_until: data.timed_out_until
      }
    }))
  }

  // Fetch a fresh member list from the server and replace the current one
  async refreshMemberList() {
    if (!this.hasListTarget) return
    try {
      const res = await fetch(`/servers/${this.serverIdValue}/members`, {
        headers: { "Accept": "text/html" }
      })
      if (res.ok) {
        const html = await res.text()
        const temp = document.createElement("div")
        temp.innerHTML = html
        const newList = temp.querySelector("[data-server-members-target='list']")
        if (newList) {
          this.listTarget.innerHTML = newList.innerHTML
        }
      }
    } catch (err) {
      // Silently fail — member list will be stale until next refresh
    }
  }

  // --- Group management ---

  // Get all group headers in DOM order
  getAllGroupHeaders() {
    return Array.from(this.listTarget.querySelectorAll("[data-status-group]"))
  }

  // Get all member elements belonging to a group header
  getGroupMembers(header) {
    const members = []
    let sibling = header.nextElementSibling
    while (sibling && !sibling.hasAttribute("data-status-group")) {
      if (sibling.hasAttribute("data-user-id")) members.push(sibling)
      sibling = sibling.nextElementSibling
    }
    return members
  }

  // Ensure a group header exists, creating it in the correct position if needed
  ensureGroupHeader(group) {
    let header = this.listTarget.querySelector(`[data-status-group="${group}"]`)
    if (header) return header

    // Create the header element
    const h3 = document.createElement("h3")
    h3.className = "text-xs font-semibold uppercase tracking-wide mb-1 mt-4 first:mt-0 px-2"
    h3.setAttribute("data-status-group", group)

    // Determine position for ordering
    let position = 0
    if (group === "online") {
      h3.classList.add("text-gray-400")
      h3.textContent = "Online — 0"
      // Use the existing online header's position if available, otherwise 0
      const existingOnline = this.listTarget.querySelector('[data-status-group="online"]')
      position = existingOnline ? parseInt(existingOnline.getAttribute("data-role-position") || "0", 10) : 0
    } else if (group === "offline") {
      h3.classList.add("text-gray-400")
      h3.textContent = "Offline — 0"
    } else {
      // Role group: "role:<public_id>"
      h3.style.color = "var(--color-gray-400)"
      h3.textContent = "Role — 0"
    }

    h3.setAttribute("data-role-position", String(position))

    const insertionPoint = this.findInsertionPointForGroup(group, position)
    if (insertionPoint) {
      insertionPoint.before(h3)
    } else {
      this.listTarget.appendChild(h3)
    }

    return h3
  }

  // Find where to insert a new group header to maintain hierarchy order.
  // All groups (role groups + online) are ordered by data-role-position descending.
  // Offline is always last.
  findInsertionPointForGroup(group, position) {
    const headers = this.getAllGroupHeaders()

    if (group === "offline") {
      return null // always last
    }

    const pos = position || 0

    // Find the first existing header with a lower position to insert before
    for (const h of headers) {
      const hGroup = h.getAttribute("data-status-group")
      if (hGroup === "offline") return h // always insert before offline
      const hPos = parseInt(h.getAttribute("data-role-position") || "0", 10)
      if (hPos < pos) return h
    }

    // Insert before offline if it exists, otherwise append
    const offlineHeader = this.listTarget.querySelector('[data-status-group="offline"]')
    return offlineHeader || null
  }

  // Compare two members: higher role position first, then alphabetical
  compareMemberOrder(elA, elB) {
    const posA = parseInt(elA.getAttribute("data-role-position") || "0", 10)
    const posB = parseInt(elB.getAttribute("data-role-position") || "0", 10)
    if (posA !== posB) return posB - posA // higher position first
    const nameA = (elA.getAttribute("data-display-name") || "").toLowerCase()
    const nameB = (elB.getAttribute("data-display-name") || "").toLowerCase()
    return nameA < nameB ? -1 : nameA > nameB ? 1 : 0
  }

  // Move a member element to the correct group, sorted by role hierarchy then alphabetically
  moveMemberToGroup(el, group) {
    const header = this.ensureGroupHeader(group)

    // Find insertion position within this group using role hierarchy + alphabetical
    let sibling = header.nextElementSibling
    let insertBefore = null
    while (sibling && !sibling.hasAttribute("data-status-group")) {
      if (sibling.hasAttribute("data-user-id") && sibling !== el) {
        if (this.compareMemberOrder(el, sibling) < 0) {
          insertBefore = sibling
          break
        }
      }
      sibling = sibling.nextElementSibling
    }

    // Check if already in the right position
    if (insertBefore) {
      if (el.nextElementSibling === insertBefore) return // Already in place
      header.parentNode.insertBefore(el, insertBefore)
    } else {
      // Insert at end of group (before next group header or at end of list)
      const nextHeader = this.findNextGroupHeader(header)
      if (nextHeader) {
        if (el.nextElementSibling === nextHeader) return // Already in place
        header.parentNode.insertBefore(el, nextHeader)
      } else {
        this.listTarget.appendChild(el)
      }
    }
  }

  // Insert a new member element into the correct group
  insertMemberInGroup(el, group) {
    this.listTarget.appendChild(el) // Add to DOM first
    this.moveMemberToGroup(el, group)
  }

  // Find the next group header after the given one
  findNextGroupHeader(header) {
    let sibling = header.nextElementSibling
    while (sibling) {
      if (sibling.hasAttribute("data-status-group")) return sibling
      sibling = sibling.nextElementSibling
    }
    return null
  }

  // Update message author name colors when roles change
  applyRoleColors(colorMap) {
    for (const [userId, color] of Object.entries(colorMap)) {
      document.querySelectorAll(`[data-msg-user-id="${userId}"]`).forEach(el => {
        el.style.color = color
      })
    }
  }

  // Recount all groups and remove empty ones
  recountAllGroups() {
    const headers = this.getAllGroupHeaders()
    for (const header of headers) {
      const members = this.getGroupMembers(header)
      if (members.length === 0) {
        header.remove()
      } else {
        // Update count in header text
        const group = header.getAttribute("data-status-group")
        const currentText = header.textContent
        // Extract the label (everything before " — ")
        const dashIdx = currentText.indexOf(" — ")
        const label = dashIdx >= 0 ? currentText.substring(0, dashIdx).trim() : currentText.trim()
        header.textContent = `${label} — ${members.length}`
      }
    }
  }
}
