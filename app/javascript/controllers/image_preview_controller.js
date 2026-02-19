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
    // Let notification_badge_controller handle images inside messages (unified context menu)
    if (img.closest("[data-message-id]")) return
    e.preventDefault()
    this.closeMenu()
    this.showContextMenu(e.clientX, e.clientY, img.dataset.previewSrc, img.dataset.previewFilename)
  }

  openLightbox(src, filename) {
    const tpl = document.getElementById("tpl-image-lightbox").content.cloneNode(true)
    const overlay = tpl.firstElementChild
    overlay.id = "image-lightbox"

    const imgWrap = overlay.querySelector('[data-slot="img-wrap"]')
    const img = overlay.querySelector('[data-slot="img"]')
    img.src = src

    if (filename) {
      overlay.querySelector('[data-slot="filename"]').textContent = filename
    }
    const downloadLink = overlay.querySelector('[data-slot="download"]')
    downloadLink.href = src
    downloadLink.download = filename || "image"

    const closeBtn = overlay.querySelector('[data-slot="close"]')

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

    closeBtn.addEventListener("click", () => { cleanup(); overlay.remove() })

    document.body.appendChild(overlay)

    // ESC to close
    const escHandler = (e) => {
      if (e.key === "Escape") { cleanup(); overlay.remove() }
    }
    const cleanup = () => document.removeEventListener("keydown", escHandler)
    document.addEventListener("keydown", escHandler)
  }

  showContextMenu(x, y, src, filename) {
    const tpl = document.getElementById("tpl-image-context-menu").content.cloneNode(true)
    const menu = tpl.firstElementChild
    menu.id = "image-context-menu"
    menu.style.left = `${x}px`
    menu.style.top = `${y}px`

    menu.querySelector('[data-action="copy-image"]').addEventListener("click", async () => {
      try {
        const res = await fetch(src)
        const blob = await res.blob()
        await navigator.clipboard.write([new ClipboardItem({ [blob.type]: blob })])
      } catch (err) {
        navigator.clipboard.writeText(src)
      }
      menu.remove()
    })

    menu.querySelector('[data-action="copy-link"]').addEventListener("click", () => {
      navigator.clipboard.writeText(src)
      menu.remove()
    })

    menu.querySelector('[data-action="save"]').addEventListener("click", () => {
      const a = document.createElement("a")
      a.href = src
      a.download = filename || "image"
      a.click()
      menu.remove()
    })

    document.body.appendChild(menu)

    const rect = menu.getBoundingClientRect()
    if (rect.right > window.innerWidth) menu.style.left = `${window.innerWidth - rect.width - 8}px`
    if (rect.bottom > window.innerHeight) menu.style.top = `${window.innerHeight - rect.height - 8}px`
  }

  showVideoContextMenu(x, y, src, filename) {
    const tpl = document.getElementById("tpl-video-context-menu").content.cloneNode(true)
    const menu = tpl.firstElementChild
    menu.id = "image-context-menu"
    menu.style.left = `${x}px`
    menu.style.top = `${y}px`

    menu.querySelector('[data-action="copy-link"]').addEventListener("click", () => {
      navigator.clipboard.writeText(src)
      menu.remove()
    })

    menu.querySelector('[data-action="save"]').addEventListener("click", () => {
      const a = document.createElement("a")
      a.href = src
      a.download = filename || "video"
      a.click()
      menu.remove()
    })

    menu.querySelector('[data-action="open-tab"]').addEventListener("click", () => {
      window.open(src, "_blank")
      menu.remove()
    })

    document.body.appendChild(menu)

    const rect = menu.getBoundingClientRect()
    if (rect.right > window.innerWidth) menu.style.left = `${window.innerWidth - rect.width - 8}px`
    if (rect.bottom > window.innerHeight) menu.style.top = `${window.innerHeight - rect.height - 8}px`
  }
}
