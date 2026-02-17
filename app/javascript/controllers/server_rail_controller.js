import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

export default class extends Controller {
  static targets = ["list", "folderList"]

  connect() {
    this.sortables = []
    this.folderMenu = null
    this.boundCloseMenu = this.closeFolderMenu.bind(this)
    this.boundKeydown = this.handleKeydown.bind(this)
    this.dragOverTarget = null
    this.folderCreationReady = false
    this.folderCreationTimer = null

    if (this.hasListTarget) {
      this.initMainSortable()
      this.initFolderSortables()
    }

    this.freezeGifs()
  }

  disconnect() {
    this.sortables.forEach(s => s.destroy())
    this.sortables = []
    this.closeFolderMenu()
    clearTimeout(this.folderCreationTimer)
  }

  // --- Sortable setup ---

  initMainSortable() {
    const sortable = Sortable.create(this.listTarget, {
      animation: 150,
      ghostClass: "opacity-20",
      dragClass: "shadow-lg",
      draggable: "[data-rail-item], [data-server-id]",
      fallbackOnBody: true,
      swapThreshold: 0.65,
      group: "rail",
      onStart: () => this.onDragStart(),
      onEnd: (evt) => this.handleMainDrop(evt),
      onMove: (evt) => this.handleDragMove(evt),
      onAdd: (evt) => {
        // Server arrived from a folder — mark as top-level
        evt.item.setAttribute("data-rail-item", "server")
      }
    })
    this.sortables.push(sortable)
  }

  initFolderSortables() {
    this.element.querySelectorAll("[data-folder-server-list]").forEach(list => {
      this.initSingleFolderSortable(list)
    })
  }

  initSingleFolderSortable(list) {
    if (list._sortableInitialized) return
    const sortable = Sortable.create(list, {
      animation: 150,
      ghostClass: "opacity-20",
      dragClass: "shadow-lg",
      draggable: "[data-server-id]",
      fallbackOnBody: true,
      swapThreshold: 0.65,
      group: "rail",
      onEnd: () => this.saveOrder(),
      onAdd: (evt) => this.handleFolderAdd(evt),
      onRemove: (evt) => this.handleFolderRemove(evt)
    })
    this.sortables.push(sortable)
    list._sortableInitialized = true
  }

  // --- Drag start/move/end ---

  onDragStart() {
    this.dragOverTarget = null
    this.folderCreationReady = false
    clearTimeout(this.folderCreationTimer)
  }

  handleDragMove(evt) {
    const dragged = evt.dragged
    const related = evt.related

    // Only highlight for folder creation when dragging a top-level server onto another top-level server
    if (!dragged || !related) {
      this.clearFolderCreationState()
      return true
    }
    if (dragged.dataset.railItem === "folder" || related.dataset.railItem === "folder") {
      this.clearFolderCreationState()
      return true
    }
    if (!dragged.dataset.serverId || !related.dataset.serverId) {
      this.clearFolderCreationState()
      return true
    }
    // Must be in the main list (not inside a folder)
    if (related.closest("[data-folder-server-list]")) {
      this.clearFolderCreationState()
      return true
    }

    // If we're hovering over the same target, keep the timer running
    if (this.dragOverTarget === related) return true

    // New target — reset
    this.clearFolderCreationState()
    related.classList.add("folder-drop-target")
    this.dragOverTarget = related

    // Start timer: hold for 500ms to flag folder creation
    this.folderCreationTimer = setTimeout(() => {
      this.folderCreationReady = true
      if (this.dragOverTarget) {
        this.dragOverTarget.classList.remove("folder-drop-target")
        this.dragOverTarget.classList.add("folder-drop-ready")
      }
    }, 500)

    return true
  }

  clearFolderCreationState() {
    clearTimeout(this.folderCreationTimer)
    this.folderCreationReady = false
    if (this.dragOverTarget) {
      this.dragOverTarget.classList.remove("folder-drop-target", "folder-drop-ready")
      this.dragOverTarget = null
    }
    this.element.querySelectorAll(".folder-drop-target, .folder-drop-ready").forEach(el => {
      el.classList.remove("folder-drop-target", "folder-drop-ready")
    })
  }

  async handleMainDrop(evt) {
    const shouldCreateFolder = this.folderCreationReady
    const target = this.dragOverTarget
    this.clearFolderCreationState()

    const dragged = evt.item

    if (shouldCreateFolder && target &&
        dragged.dataset.serverId && target.dataset.serverId &&
        dragged !== target &&
        !dragged.dataset.folderId && !target.dataset.folderId) {
      await this.createFolder(dragged.dataset.serverId, target.dataset.serverId, dragged, target)
      return
    }

    this.saveOrder()
  }

  // --- Folder creation ---

  async createFolder(serverId1, serverId2, el1, el2) {
    const csrf = document.querySelector("meta[name=csrf-token]")?.content

    const serverIds = []
    const remoteServerIds = []
    ;[serverId1, serverId2].forEach(id => {
      if (id.startsWith("r_")) {
        remoteServerIds.push(id.substring(2))
      } else {
        serverIds.push(id)
      }
    })

    try {
      const response = await fetch("/server_folders", {
        method: "POST",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
        body: JSON.stringify({
          server_folder: { name: "Folder" },
          server_ids: serverIds,
          remote_server_ids: remoteServerIds
        })
      })

      if (!response.ok) return this.saveOrder()

      const data = await response.json()

      // Replace the two server elements with the folder HTML
      const temp = document.createElement("div")
      temp.innerHTML = data.html
      const folderEl = temp.firstElementChild

      el1.replaceWith(folderEl)
      el2.remove()

      // Init sortable on the new folder's server list
      const newFolderList = folderEl.querySelector("[data-folder-server-list]")
      if (newFolderList) {
        this.initSingleFolderSortable(newFolderList)
      }

      this.freezeGifs()
      this.saveOrder()
    } catch (e) {
      this.saveOrder()
    }
  }

  // --- Handle servers entering/leaving folders via drag ---

  handleFolderAdd(evt) {
    // A server was dragged into this folder — update the folder's stacked icons
    const folderEl = evt.to.closest("[data-folder-id]")
    if (folderEl) this.updateFolderIcons(folderEl)
    this.saveOrder()
  }

  handleFolderRemove(evt) {
    // A server was dragged out of this folder
    const folderEl = evt.from.closest("[data-folder-id]")
    if (!folderEl) return

    const serverList = folderEl.querySelector("[data-folder-server-list]")
    if (serverList && serverList.children.length === 0) {
      // Folder is empty — auto-delete it
      const folderId = folderEl.dataset.folderId
      folderEl.remove()
      this.deleteFolder(folderId, false)
    } else {
      // Still has servers — update the stacked mini-icons
      this.updateFolderIcons(folderEl)
    }
    this.saveOrder()
  }

  updateFolderIcons(folderEl) {
    const serverList = folderEl.querySelector("[data-folder-server-list]")
    if (!serverList) return

    const servers = Array.from(serverList.children).filter(el => el.dataset.serverId)
    const offsets = [
      { x: -4, y: -4 },
      { x: 6, y: -2 },
      { x: 1, y: 6 }
    ]

    // Rebuild every [data-folder-icons] container (collapsed + expanded header)
    folderEl.querySelectorAll("[data-folder-icons]").forEach(container => {
      // Preserve folder color
      const folderColor = container.dataset.folderColor || "#4f545c"
      container.style.backgroundColor = folderColor
      container.innerHTML = ""

      servers.slice(0, 3).forEach((serverEl, i) => {
        const offset = offsets[i]
        const mini = document.createElement("div")
        mini.className = "absolute w-5 h-5 rounded-md overflow-hidden border border-gray-800"
        mini.style.transform = `translate(${offset.x}px, ${offset.y}px)`
        mini.style.zIndex = 3 - i

        // Extract icon from the server's full-size element
        const frozenCanvas = serverEl.querySelector("[data-gif-freeze]")
        const img = serverEl.querySelector("img:not(.gif-animated)")
        if (frozenCanvas && frozenCanvas.width > 0) {
          // GIF server — use frozen first frame as a static image
          const miniImg = document.createElement("img")
          try { miniImg.src = frozenCanvas.toDataURL() } catch(e) { miniImg.src = "" }
          miniImg.className = "w-full h-full object-cover"
          mini.appendChild(miniImg)
        } else if (img) {
          const miniImg = document.createElement("img")
          miniImg.src = img.src
          miniImg.className = "w-full h-full object-cover"
          mini.appendChild(miniImg)
        } else {
          const span = serverEl.querySelector("span.text-white")
          const initials = span ? span.textContent.trim() : "?"
          const div = document.createElement("div")
          div.className = "w-full h-full bg-gray-600 flex items-center justify-center"
          div.innerHTML = `<span class="text-white text-[6px] font-bold">${this.escapeAttr(initials)}</span>`
          mini.appendChild(div)
        }

        container.appendChild(mini)
      })
    })
  }

  // --- Expand / Collapse ---

  toggleFolder(event) {
    event.preventDefault()
    event.stopPropagation()

    const folderEl = event.currentTarget.closest("[data-folder-id]")
    if (!folderEl) return

    const collapsed = folderEl.dataset.collapsed === "true"
    const collapsedView = folderEl.querySelector("[data-folder-collapsed-view]")
    const expandedView = folderEl.querySelector("[data-folder-expanded-view]")
    const container = folderEl.querySelector("[data-folder-server-container]")

    if (collapsed) {
      // Expanding — show view, then animate server list open
      folderEl.dataset.collapsed = "false"
      collapsedView.classList.add("hidden")

      if (container) container.classList.add("folder-grid-collapsed")
      expandedView.classList.remove("hidden")

      if (container) {
        requestAnimationFrame(() => {
          requestAnimationFrame(() => {
            container.classList.remove("folder-grid-collapsed")
          })
        })
      }

      const serverList = folderEl.querySelector("[data-folder-server-list]")
      if (serverList) this.initSingleFolderSortable(serverList)
    } else {
      // Collapsing — animate server list closed, then swap views
      if (container) {
        container.classList.add("folder-grid-collapsed")
        setTimeout(() => {
          folderEl.dataset.collapsed = "true"
          collapsedView.classList.remove("hidden")
          expandedView.classList.add("hidden")
        }, 300)
      } else {
        folderEl.dataset.collapsed = "true"
        collapsedView.classList.remove("hidden")
        expandedView.classList.add("hidden")
      }
    }

    // Persist collapse state
    const folderId = folderEl.dataset.folderId
    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    fetch(`/server_folders/${folderId}/toggle_collapse`, {
      method: "PATCH",
      headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
    })
  }

  // --- Right-click context menu ---

  showFolderMenu(event) {
    event.preventDefault()
    event.stopPropagation()
    this.closeFolderMenu()

    const folderEl = event.currentTarget.closest("[data-folder-id]")
    if (!folderEl) return

    const folderId = folderEl.dataset.folderId
    const folderNameEl = folderEl.querySelector("[data-folder-name]")
    const currentName = folderNameEl ? folderNameEl.textContent.trim() : "Folder"

    this.folderMenu = document.createElement("div")
    this.folderMenu.className = "fixed z-[60] w-48 bg-gray-800 rounded-lg shadow-xl border border-gray-600 py-1.5 text-sm"

    let left = event.clientX
    let top = event.clientY
    if (left + 192 > window.innerWidth) left = window.innerWidth - 196
    if (top + 100 > window.innerHeight) top = window.innerHeight - 104

    this.folderMenu.style.left = `${left}px`
    this.folderMenu.style.top = `${top}px`

    const currentColor = folderEl.querySelector("[data-folder-color]")?.dataset.folderColor || "#4f545c"

    this.folderMenu.innerHTML = `
      <button data-menu-action="rename" class="w-full text-left px-3 py-1.5 text-gray-300 hover:bg-gray-700 hover:text-white transition">Rename Folder</button>
      <button data-menu-action="color" class="w-full text-left px-3 py-1.5 text-gray-300 hover:bg-gray-700 hover:text-white transition">Folder Color</button>
      <button data-menu-action="delete" class="w-full text-left px-3 py-1.5 text-red-400 hover:bg-gray-700 hover:text-red-300 transition">Delete Folder</button>
    `

    document.body.appendChild(this.folderMenu)

    this.folderMenu.querySelector("[data-menu-action='rename']").addEventListener("click", (e) => {
      e.stopPropagation()
      this.showRenameInput(folderId, currentName, folderEl)
    })

    this.folderMenu.querySelector("[data-menu-action='color']").addEventListener("click", (e) => {
      e.stopPropagation()
      this.showColorPicker(folderId, currentColor, folderEl)
    })

    this.folderMenu.querySelector("[data-menu-action='delete']").addEventListener("click", (e) => {
      e.stopPropagation()
      this.deleteFolder(folderId, true)
      this.closeFolderMenu()
    })

    setTimeout(() => {
      document.addEventListener("click", this.boundCloseMenu)
      document.addEventListener("keydown", this.boundKeydown)
    }, 10)
  }

  showRenameInput(folderId, currentName, folderEl) {
    if (!this.folderMenu) return

    this.folderMenu.innerHTML = `
      <div class="px-3 py-2">
        <label class="text-[10px] text-gray-500 uppercase font-semibold mb-1 block">Folder Name</label>
        <input type="text" value="${this.escapeAttr(currentName)}" maxlength="50"
               class="w-full bg-gray-900 border border-gray-600 rounded px-2 py-1 text-white text-sm focus:outline-none focus:border-orange-500"
               data-rename-input>
        <button class="mt-2 w-full bg-orange-600 hover:bg-orange-700 text-white text-xs font-semibold py-1 rounded transition" data-rename-save>Save</button>
      </div>
    `

    const input = this.folderMenu.querySelector("[data-rename-input]")
    input.focus()
    input.select()

    const save = () => this.renameFolder(folderId, input.value.trim(), folderEl)

    this.folderMenu.querySelector("[data-rename-save]").addEventListener("click", (e) => {
      e.stopPropagation()
      save()
    })

    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault()
        save()
      }
      if (e.key === "Escape") {
        this.closeFolderMenu()
      }
    })

    input.addEventListener("click", (e) => e.stopPropagation())
  }

  showColorPicker(folderId, currentColor, folderEl) {
    if (!this.folderMenu) return

    const presets = [
      { color: "#4f545c", label: "Gray" },
      { color: "#5865f2", label: "Blurple" },
      { color: "#57f287", label: "Green" },
      { color: "#fee75c", label: "Yellow" },
      { color: "#eb459e", label: "Pink" },
      { color: "#ed4245", label: "Red" },
      { color: "#f47b67", label: "Orange" },
      { color: "#9b59b6", label: "Purple" }
    ]

    const swatchesHtml = presets.map(p => {
      const ring = p.color.toLowerCase() === currentColor.toLowerCase() ? "ring-2 ring-white" : ""
      return `<button data-color-swatch="${p.color}" title="${p.label}" class="w-8 h-8 rounded-full ${ring} hover:scale-110 transition-transform" style="background-color: ${p.color}"></button>`
    }).join("")

    this.folderMenu.innerHTML = `
      <div class="px-3 py-2">
        <label class="text-[10px] text-gray-500 uppercase font-semibold mb-2 block">Folder Color</label>
        <div class="grid grid-cols-4 gap-2 mb-2">${swatchesHtml}</div>
        <div class="flex items-center gap-2">
          <input type="color" value="${currentColor}" class="w-8 h-8 rounded cursor-pointer border-0 p-0 bg-transparent" data-custom-color>
          <span class="text-xs text-gray-400">Custom</span>
        </div>
      </div>
    `

    const applyColor = (color) => this.applyFolderColor(folderId, color, folderEl)

    this.folderMenu.querySelectorAll("[data-color-swatch]").forEach(btn => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation()
        applyColor(btn.dataset.colorSwatch)
      })
    })

    const customInput = this.folderMenu.querySelector("[data-custom-color]")
    customInput.addEventListener("input", (e) => {
      e.stopPropagation()
      applyColor(customInput.value)
    })
    customInput.addEventListener("click", (e) => e.stopPropagation())
  }

  async applyFolderColor(folderId, color, folderEl) {
    // Update folder icon backgrounds
    folderEl.querySelectorAll("[data-folder-icons]").forEach(container => {
      container.style.backgroundColor = color
      container.dataset.folderColor = color
    })
    // Update server list container background
    const serverBg = folderEl.querySelector("[data-folder-server-bg]")
    if (serverBg) {
      serverBg.style.backgroundColor = color + "30"
      serverBg.dataset.folderServerBg = color
    }

    // Persist to server
    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    try {
      await fetch(`/server_folders/${folderId}`, {
        method: "PATCH",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
        body: JSON.stringify({ server_folder: { color } })
      })
    } catch (e) {
      // silently fail
    }

    this.closeFolderMenu()
  }

  async renameFolder(folderId, newName, folderEl) {
    if (!newName) return

    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    try {
      const response = await fetch(`/server_folders/${folderId}`, {
        method: "PATCH",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
        body: JSON.stringify({ server_folder: { name: newName } })
      })

      if (response.ok) {
        folderEl.querySelectorAll("[data-folder-name]").forEach(el => {
          el.textContent = newName
        })
      }
    } catch (e) {
      // silently fail
    }

    this.closeFolderMenu()
  }

  async deleteFolder(folderId, moveServersToDom) {
    const csrf = document.querySelector("meta[name=csrf-token]")?.content

    if (moveServersToDom) {
      const folderEl = this.element.querySelector(`[data-folder-id="${folderId}"]`)
      if (folderEl) {
        const serverList = folderEl.querySelector("[data-folder-server-list]")
        if (serverList) {
          Array.from(serverList.children).forEach(serverEl => {
            serverEl.setAttribute("data-rail-item", "server")
            this.listTarget.insertBefore(serverEl, folderEl)
          })
        }
        folderEl.remove()
      }
    }

    try {
      await fetch(`/server_folders/${folderId}`, {
        method: "DELETE",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      })
    } catch (e) {
      // silently fail
    }

    this.saveOrder()
  }

  // --- Save order ---

  parseServerId(rawId) {
    if (rawId && rawId.startsWith("r_")) {
      return { id: rawId.substring(2), remote: true }
    }
    return { id: rawId, remote: false }
  }

  async saveOrder() {
    const items = []
    let position = 0

    Array.from(this.listTarget.children).forEach(child => {
      if (child.dataset.folderId) {
        const folderServers = []
        const serverList = child.querySelector("[data-folder-server-list]")
        if (serverList) {
          Array.from(serverList.children).forEach((serverEl, idx) => {
            if (serverEl.dataset.serverId) {
              const parsed = this.parseServerId(serverEl.dataset.serverId)
              const entry = { id: parsed.id, position: idx }
              if (parsed.remote) entry.remote = true
              folderServers.push(entry)
            }
          })
        }
        items.push({ type: "folder", id: child.dataset.folderId, position: position++, servers: folderServers })
      } else if (child.dataset.serverId) {
        const parsed = this.parseServerId(child.dataset.serverId)
        if (parsed.remote) {
          items.push({ type: "remote_server", id: parsed.id, position: position++ })
        } else {
          items.push({ type: "server", id: parsed.id, position: position++ })
        }
      }
    })

    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    await fetch("/reorder_servers", {
      method: "PATCH",
      headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
      body: JSON.stringify({ items })
    })
  }

  // --- Menu helpers ---

  closeFolderMenu(event) {
    if (this.folderMenu) {
      if (event && this.folderMenu.contains(event.target)) return
      this.folderMenu.remove()
      this.folderMenu = null
    }
    document.removeEventListener("click", this.boundCloseMenu)
    document.removeEventListener("keydown", this.boundKeydown)
  }

  handleKeydown(event) {
    if (event.key === "Escape") {
      this.closeFolderMenu()
    }
  }

  // --- GIF freeze ---

  freezeGifs() {
    this.element.querySelectorAll(".server-icon-gif, .folder-mini-gif").forEach(el => {
      const img = el.querySelector("[data-gif-src]")
      const canvas = el.querySelector("[data-gif-freeze]")
      if (!img || !canvas) return

      const draw = () => {
        canvas.width = img.naturalWidth || 48
        canvas.height = img.naturalHeight || 48
        const ctx = canvas.getContext("2d")
        ctx.drawImage(img, 0, 0, canvas.width, canvas.height)
      }

      if (img.complete && img.naturalWidth > 0) {
        draw()
      } else {
        img.addEventListener("load", draw, { once: true })
      }
    })
  }

  // --- Util ---

  escapeAttr(text) {
    return text.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }
}
