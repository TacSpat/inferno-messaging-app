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
    overlay.className = "fixed inset-0 z-[200] bg-black/80 flex items-center justify-center"
    overlay.style.touchAction = "none"

    const container = document.createElement("div")
    container.className = "relative max-w-[90vw] max-h-[90vh] flex flex-col items-center"

    const imgWrap = document.createElement("div")
    imgWrap.style.cssText = "overflow:hidden;display:flex;align-items:center;justify-content:center;max-width:90vw;max-height:85vh;"

    const img = document.createElement("img")
    img.src = src
    img.className = "max-w-[90vw] max-h-[85vh] object-contain rounded-lg shadow-2xl"
    img.style.cssText = "transform-origin:center center;transition:transform 0.2s ease;cursor:zoom-in;touch-action:none;"
    img.draggable = false

    // Zoom state
    let scale = 1, tx = 0, ty = 0
    let pinchStartDist = 0, pinchStartScale = 1
    let lastTap = 0
    let isPanning = false, panStartX = 0, panStartY = 0, panStartTx = 0, panStartTy = 0

    const applyTransform = (animate) => {
      img.style.transition = animate ? "transform 0.2s ease" : "none"
      img.style.transform = `translate(${tx}px,${ty}px) scale(${scale})`
      img.style.cursor = scale > 1 ? "grab" : "zoom-in"
    }

    const clampPan = () => {
      if (scale <= 1) { tx = 0; ty = 0; return }
      const rect = imgWrap.getBoundingClientRect()
      const imgW = img.naturalWidth ? Math.min(img.naturalWidth, rect.width) : rect.width
      const imgH = img.naturalHeight ? Math.min(img.naturalHeight, rect.height) : rect.height
      const maxTx = Math.max(0, (imgW * scale - rect.width) / 2)
      const maxTy = Math.max(0, (imgH * scale - rect.height) / 2)
      tx = Math.max(-maxTx, Math.min(maxTx, tx))
      ty = Math.max(-maxTy, Math.min(maxTy, ty))
    }

    const resetZoom = () => {
      scale = 1; tx = 0; ty = 0
      applyTransform(true)
    }

    let isTouch = false

    const toggleZoom = (clientX, clientY) => {
      if (scale > 1) {
        resetZoom()
      } else {
        const rect = img.getBoundingClientRect()
        // Offset from image center
        const ox = clientX - (rect.left + rect.width / 2)
        const oy = clientY - (rect.top + rect.height / 2)
        scale = 3
        tx = -ox * (scale - 1)
        ty = -oy * (scale - 1)
        clampPan()
        applyTransform(true)
      }
    }

    // Desktop: click to zoom, drag to pan when zoomed
    let mouseDidDrag = false
    let mouseIsDown = false
    let mousePanStartX = 0, mousePanStartY = 0, mousePanStartTx = 0, mousePanStartTy = 0

    img.addEventListener("mousedown", (e) => {
      if (isTouch || e.button !== 0) return
      mouseIsDown = true
      mouseDidDrag = false
      if (scale > 1) {
        mousePanStartX = e.clientX
        mousePanStartY = e.clientY
        mousePanStartTx = tx
        mousePanStartTy = ty
        img.style.cursor = "grabbing"
        e.preventDefault()
      }
    })

    document.addEventListener("mousemove", (e) => {
      if (!mouseIsDown || isTouch) return
      if (scale > 1) {
        const dx = e.clientX - mousePanStartX
        const dy = e.clientY - mousePanStartY
        if (Math.abs(dx) > 3 || Math.abs(dy) > 3) mouseDidDrag = true
        tx = mousePanStartTx + dx
        ty = mousePanStartTy + dy
        clampPan()
        applyTransform(false)
      }
    })

    document.addEventListener("mouseup", () => {
      if (mouseIsDown && scale > 1) img.style.cursor = "grab"
      mouseIsDown = false
    })

    // Suppress touch-end closing overlay after a pan
    let touchDidPan = false

    img.addEventListener("click", (e) => {
      if (isTouch) return
      e.stopPropagation()
      if (mouseDidDrag) { mouseDidDrag = false; return }
      toggleZoom(e.clientX, e.clientY)
    })

    // Touch: double-tap to zoom, pinch, pan
    img.addEventListener("touchstart", (e) => {
      isTouch = true
      touchDidPan = false
      if (e.touches.length === 1) {
        const now = Date.now()
        if (now - lastTap < 300) {
          e.preventDefault()
          toggleZoom(e.touches[0].clientX, e.touches[0].clientY)
          lastTap = 0
          return
        }
        lastTap = now
        if (scale > 1) {
          isPanning = true
          panStartX = e.touches[0].clientX
          panStartY = e.touches[0].clientY
          panStartTx = tx
          panStartTy = ty
          img.style.cursor = "grabbing"
        }
      } else if (e.touches.length === 2) {
        e.preventDefault()
        isPanning = false
        const d = Math.hypot(
          e.touches[1].clientX - e.touches[0].clientX,
          e.touches[1].clientY - e.touches[0].clientY
        )
        pinchStartDist = d
        pinchStartScale = scale
      }
    }, { passive: false })

    img.addEventListener("touchmove", (e) => {
      if (e.touches.length === 2) {
        e.preventDefault()
        touchDidPan = true
        const d = Math.hypot(
          e.touches[1].clientX - e.touches[0].clientX,
          e.touches[1].clientY - e.touches[0].clientY
        )
        scale = Math.max(1, Math.min(8, pinchStartScale * (d / pinchStartDist)))
        clampPan()
        applyTransform(false)
      } else if (e.touches.length === 1 && isPanning) {
        e.preventDefault()
        touchDidPan = true
        tx = panStartTx + (e.touches[0].clientX - panStartX)
        ty = panStartTy + (e.touches[0].clientY - panStartY)
        clampPan()
        applyTransform(false)
      }
    }, { passive: false })

    img.addEventListener("touchend", (e) => {
      isPanning = false
      if (scale <= 1) resetZoom()
    })

    // Mouse wheel zoom
    imgWrap.addEventListener("wheel", (e) => {
      e.preventDefault()
      const delta = e.deltaY > 0 ? 0.8 : 1.25
      scale = Math.max(1, Math.min(8, scale * delta))
      if (scale <= 1) { resetZoom(); return }
      clampPan()
      applyTransform(false)
    }, { passive: false })

    // Close on overlay click (not on image/controls, and not after a drag/pan)
    overlay.addEventListener("click", (e) => {
      if (mouseDidDrag || touchDidPan) {
        mouseDidDrag = false
        touchDidPan = false
        return
      }
      if (e.target === overlay) { cleanup(); overlay.remove() }
    })

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
    closeBtn.className = "absolute -top-2 -right-2 w-8 h-8 bg-gray-800 rounded-full flex items-center justify-center text-gray-400 hover:text-white border border-gray-600 cursor-pointer z-10"
    closeBtn.innerHTML = '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>'
    closeBtn.addEventListener("click", () => { cleanup(); overlay.remove() })

    imgWrap.appendChild(img)
    container.appendChild(closeBtn)
    container.appendChild(imgWrap)
    container.appendChild(bar)
    overlay.appendChild(container)
    document.body.appendChild(overlay)

    // ESC to close
    const escHandler = (e) => {
      if (e.key === "Escape") { cleanup(); overlay.remove() }
    }
    const cleanup = () => document.removeEventListener("keydown", escHandler)
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
