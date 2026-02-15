import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.onClick = this.handleClick.bind(this)
    this.onContext = this.handleContext.bind(this)
    this.element.addEventListener("click", this.onClick)
    this.element.addEventListener("contextmenu", this.onContext)

    this.closeMenu = () => {
      const m = document.getElementById("image-context-menu")
      if (m) m.remove()
    }
    document.addEventListener("click", this.closeMenu)
  }

  disconnect() {
    this.element.removeEventListener("click", this.onClick)
    this.element.removeEventListener("contextmenu", this.onContext)
    document.removeEventListener("click", this.closeMenu)
    this.closeMenu()
  }

  handleClick(e) {
    const img = e.target.closest("img[data-preview-src]")
    if (!img) return
    e.preventDefault()
    this.openLightbox(img.dataset.previewSrc, img.dataset.previewFilename)
  }

  handleContext(e) {
    // Video context menu
    const videoEl = e.target.closest("[data-video-src]")
    if (videoEl) {
      e.preventDefault()
      this.closeMenu()
      this.showVideoContextMenu(e.clientX, e.clientY, videoEl.dataset.videoSrc, videoEl.dataset.videoFilename)
      return
    }

    const img = e.target.closest("img[data-preview-src]")
    if (!img) return
    e.preventDefault()
    this.closeMenu()
    this.showContextMenu(e.clientX, e.clientY, img.dataset.previewSrc, img.dataset.previewFilename)
  }

  openLightbox(src, filename) {
    const overlay = document.createElement("div")
    overlay.id = "image-lightbox"
    overlay.className = "fixed inset-0 z-[200] bg-black/80 flex items-center justify-center cursor-zoom-out"
    overlay.addEventListener("click", (e) => {
      if (e.target === overlay || e.target.tagName !== "IMG") overlay.remove()
    })

    const container = document.createElement("div")
    container.className = "relative max-w-[90vw] max-h-[90vh] flex flex-col items-center"

    const img = document.createElement("img")
    img.src = src
    img.className = "max-w-[90vw] max-h-[85vh] object-contain rounded-lg shadow-2xl"

    const bar = document.createElement("div")
    bar.className = "flex items-center gap-3 mt-3"

    if (filename) {
      const name = document.createElement("span")
      name.className = "text-sm text-gray-300"
      name.textContent = filename
      bar.appendChild(name)
    }

    const downloadBtn = document.createElement("a")
    downloadBtn.href = src
    downloadBtn.download = filename || "image"
    downloadBtn.className = "text-sm text-blue-400 hover:text-blue-300 flex items-center gap-1"
    downloadBtn.innerHTML = '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"/></svg> Download'
    bar.appendChild(downloadBtn)

    const closeBtn = document.createElement("button")
    closeBtn.className = "absolute -top-2 -right-2 w-8 h-8 bg-gray-800 rounded-full flex items-center justify-center text-gray-400 hover:text-white border border-gray-600 cursor-pointer"
    closeBtn.innerHTML = '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>'
    closeBtn.addEventListener("click", () => overlay.remove())

    container.appendChild(closeBtn)
    container.appendChild(img)
    container.appendChild(bar)
    overlay.appendChild(container)
    document.body.appendChild(overlay)

    // ESC to close
    const escHandler = (e) => {
      if (e.key === "Escape") { overlay.remove(); document.removeEventListener("keydown", escHandler) }
    }
    document.addEventListener("keydown", escHandler)
  }

  showContextMenu(x, y, src, filename) {
    const menu = document.createElement("div")
    menu.id = "image-context-menu"
    menu.className = "fixed z-[100] bg-gray-900 border border-gray-700 rounded-lg shadow-xl py-1.5 px-1.5 min-w-[180px]"
    menu.style.left = `${x}px`
    menu.style.top = `${y}px`

    const items = [
      {
        icon: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>',
        label: "Copy Image",
        action: async () => {
          try {
            const res = await fetch(src)
            const blob = await res.blob()
            await navigator.clipboard.write([
              new ClipboardItem({ [blob.type]: blob })
            ])
          } catch (err) {
            // Fallback: copy URL
            navigator.clipboard.writeText(src)
          }
        }
      },
      {
        icon: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"/></svg>',
        label: "Copy Image Link",
        action: () => navigator.clipboard.writeText(src)
      },
      {
        icon: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"/></svg>',
        label: "Save Image",
        action: () => {
          const a = document.createElement("a")
          a.href = src
          a.download = filename || "image"
          a.click()
        }
      }
    ]

    items.forEach(item => {
      const btn = document.createElement("button")
      btn.className = "flex items-center w-full px-2.5 py-1.5 text-sm text-gray-300 hover:bg-gray-700 hover:text-white rounded cursor-pointer"
      btn.innerHTML = `${item.icon}${item.label}`
      btn.addEventListener("click", () => {
        item.action()
        menu.remove()
      })
      menu.appendChild(btn)
    })

    document.body.appendChild(menu)

    const rect = menu.getBoundingClientRect()
    if (rect.right > window.innerWidth) menu.style.left = `${window.innerWidth - rect.width - 8}px`
    if (rect.bottom > window.innerHeight) menu.style.top = `${window.innerHeight - rect.height - 8}px`
  }

  showVideoContextMenu(x, y, src, filename) {
    const menu = document.createElement("div")
    menu.id = "image-context-menu"
    menu.className = "fixed z-[100] bg-gray-900 border border-gray-700 rounded-lg shadow-xl py-1.5 px-1.5 min-w-[180px]"
    menu.style.left = `${x}px`
    menu.style.top = `${y}px`

    const items = [
      {
        icon: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"/></svg>',
        label: "Copy Media Link",
        action: () => navigator.clipboard.writeText(src)
      },
      {
        icon: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"/></svg>',
        label: "Save Video",
        action: () => {
          const a = document.createElement("a")
          a.href = src
          a.download = filename || "video"
          a.click()
        }
      },
      {
        icon: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"/></svg>',
        label: "Open in New Tab",
        action: () => window.open(src, "_blank")
      }
    ]

    items.forEach(item => {
      const btn = document.createElement("button")
      btn.className = "flex items-center w-full px-2.5 py-1.5 text-sm text-gray-300 hover:bg-gray-700 hover:text-white rounded cursor-pointer"
      btn.innerHTML = `${item.icon}${item.label}`
      btn.addEventListener("click", () => {
        item.action()
        menu.remove()
      })
      menu.appendChild(btn)
    })

    document.body.appendChild(menu)

    const rect = menu.getBoundingClientRect()
    if (rect.right > window.innerWidth) menu.style.left = `${window.innerWidth - rect.width - 8}px`
    if (rect.bottom > window.innerHeight) menu.style.top = `${window.innerHeight - rect.height - 8}px`
  }
}
