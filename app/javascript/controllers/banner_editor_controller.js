import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container", "image", "hint", "offsetField", "input",
                    "avatarPreview", "avatarInput", "avatarInitial",
                    "previewBanner", "previewAvatar", "previewAvatarInitial", "previewGradient", "previewRing", "previewCard", "gradientPreviewStrip"]

  connect() {
    this.dragging = false
    this.startY = 0
    this.startOffset = 0
    this._onMouseMove = this.onDrag.bind(this)
    this._onMouseUp = this.stopDrag.bind(this)
    this.cropMode = null
    this.cropScale = 1
    this.cropOffsetX = 0
    this.cropOffsetY = 0
    this.cropDragging = false
    this.cropDataUrl = null
    this.modal = null
    this.cropImg = null
    this.cropViewport = null
  }

  // ========== CROP MODAL ==========
  openCropModal(mode, file) {
    this.cropMode = mode
    this.cropScale = 1
    this.cropOffsetX = 0
    this.cropOffsetY = 0

    if (this.modal) this.modal.remove()

    const reader = new FileReader()
    reader.onload = (ev) => {
      this.cropDataUrl = ev.target.result
      this.buildAndShowModal(mode, ev.target.result)
    }
    reader.readAsDataURL(file)
  }

  buildAndShowModal(mode, src) {
    const vpHeight = mode === "avatar" ? 300 : 200
    const title = mode === "avatar" ? "Edit Avatar" : "Edit Banner"

    this.modal = document.createElement("div")
    this.modal.className = "modal-overlay fixed inset-0 z-[300] flex items-center justify-center bg-black/70"

    const tpl = document.getElementById("tpl-crop-modal").content.cloneNode(true)
    tpl.querySelector('[data-slot="title"]').textContent = title

    const viewport = tpl.querySelector("[data-crop-vp]")
    viewport.style.height = vpHeight + "px"

    const cropImg = tpl.querySelector("[data-crop-img]")
    cropImg.src = src

    if (mode === "avatar") {
      tpl.querySelector('[data-slot="avatar-overlay"]').classList.remove("hidden")
    } else {
      // Show the banner profile overlay
      const bannerOverlay = tpl.querySelector('[data-slot="banner-overlay"]')
      if (bannerOverlay) {
        bannerOverlay.classList.remove("hidden")
        // Fill avatar preview if available
        const miniAvatar = bannerOverlay.querySelector('[data-slot="banner-avatar-preview"]')
        if (miniAvatar && this.hasAvatarPreviewTarget && this.avatarPreviewTarget.src && !this.avatarPreviewTarget.classList.contains("hidden")) {
          miniAvatar.innerHTML = `<img src="${this.avatarPreviewTarget.src}" class="w-full h-full object-cover">`
        }
      }
    }

    this.modal.appendChild(tpl)
    document.body.appendChild(this.modal)

    this.cropImg = this.modal.querySelector("[data-crop-img]")
    this.cropViewport = this.modal.querySelector("[data-crop-vp]")
    this.snapLineX = this.modal.querySelector('[data-crop-snap-line="x"]')
    this.snapLineY = this.modal.querySelector('[data-crop-snap-line="y"]')
    const zoomInput = this.modal.querySelector("[data-crop-zoom]")
    const zoomLabel = this.modal.querySelector("[data-crop-zoom-label]")

    // Wait for image to load
    this.cropImg.onload = () => {
      const vw = this.cropViewport.offsetWidth
      const vh = this.cropViewport.offsetHeight
      const nw = this.cropImg.naturalWidth
      const nh = this.cropImg.naturalHeight

      if (mode === "banner") {
        // Cover: image fills viewport completely (no empty space)
        const coverScale = Math.max(vw / nw, vh / nh)
        this.baseW = nw * coverScale
        this.baseH = nh * coverScale
        // Center
        this.cropOffsetX = (vw - this.baseW) / 2
        this.cropOffsetY = (vh - this.baseH) / 2
      } else {
        // Avatar: fit inside
        const fitScale = Math.min(vw / nw, vh / nh)
        this.baseW = nw * fitScale
        this.baseH = nh * fitScale
        this.cropOffsetX = (vw - this.baseW) / 2
        this.cropOffsetY = (vh - this.baseH) / 2
      }
      this.updateCropPosition()
    }

    // Drag
    let dragStartX, dragStartY, dragStartOX, dragStartOY
    const SNAP_THRESHOLD = 8

    const onDown = (e) => {
      e.preventDefault()
      this.cropDragging = true
      const pt = e.touches ? e.touches[0] : e
      dragStartX = pt.clientX
      dragStartY = pt.clientY
      dragStartOX = this.cropOffsetX
      dragStartOY = this.cropOffsetY
      this.cropViewport.style.cursor = "grabbing"
    }

    const onMove = (e) => {
      if (!this.cropDragging) return
      const pt = e.touches ? e.touches[0] : e
      let newX = dragStartOX + (pt.clientX - dragStartX)
      let newY = dragStartOY + (pt.clientY - dragStartY)

      // Constrain + snap
      const constrained = this._constrainAndSnap(newX, newY, SNAP_THRESHOLD)
      this.cropOffsetX = constrained.x
      this.cropOffsetY = constrained.y

      // Show snap lines
      if (this.snapLineX) this.snapLineX.style.opacity = constrained.snappedX ? "1" : "0"
      if (this.snapLineY) this.snapLineY.style.opacity = constrained.snappedY ? "1" : "0"

      this.updateCropPosition()
    }

    const onUp = () => {
      this.cropDragging = false
      if (this.cropViewport) this.cropViewport.style.cursor = "grab"
      // Hide snap lines
      if (this.snapLineX) this.snapLineX.style.opacity = "0"
      if (this.snapLineY) this.snapLineY.style.opacity = "0"
    }

    this.cropViewport.addEventListener("mousedown", onDown)
    this.cropViewport.addEventListener("touchstart", onDown, { passive: false })
    document.addEventListener("mousemove", onMove)
    document.addEventListener("mouseup", onUp)
    document.addEventListener("touchmove", onMove, { passive: false })
    document.addEventListener("touchend", onUp)

    this._cropCleanup = () => {
      document.removeEventListener("mousemove", onMove)
      document.removeEventListener("mouseup", onUp)
      document.removeEventListener("touchmove", onMove)
      document.removeEventListener("touchend", onUp)
    }

    // Zoom
    zoomInput.addEventListener("input", (e) => {
      const oldScale = this.cropScale
      this.cropScale = parseInt(e.target.value) / 100
      zoomLabel.textContent = this.cropScale.toFixed(1) + "x"
      // Zoom toward center of viewport
      const vw = this.cropViewport.offsetWidth
      const vh = this.cropViewport.offsetHeight
      const cx = vw / 2
      const cy = vh / 2
      this.cropOffsetX = cx - (cx - this.cropOffsetX) * (this.cropScale / oldScale)
      this.cropOffsetY = cy - (cy - this.cropOffsetY) * (this.cropScale / oldScale)

      // Constrain after zoom
      if (this.cropMode === "banner") {
        const c = this._constrainAndSnap(this.cropOffsetX, this.cropOffsetY, 0)
        this.cropOffsetX = c.x
        this.cropOffsetY = c.y
      }

      this.updateCropPosition()
    })

    // Backdrop close
    this.modal.addEventListener("click", (e) => {
      if (e.target === this.modal) this.cropCancel()
    })

    // Buttons
    this.modal.querySelector("[data-crop-cancel]").addEventListener("click", () => this.cropCancel())
    this.modal.querySelector("[data-crop-apply]").addEventListener("click", () => this.cropApply())
  }

  _constrainAndSnap(x, y, snapThreshold) {
    const vw = this.cropViewport.offsetWidth
    const vh = this.cropViewport.offsetHeight
    const imgW = this.baseW * this.cropScale
    const imgH = this.baseH * this.cropScale

    let snappedX = false
    let snappedY = false

    if (this.cropMode === "banner") {
      // Constrain: image must cover viewport (no empty edges)
      const minX = vw - imgW
      const maxX = 0
      const minY = vh - imgH
      const maxY = 0

      x = Math.max(minX, Math.min(maxX, x))
      y = Math.max(minY, Math.min(maxY, y))

      // Snap points for X: center, left edge, right edge
      const centerX = (vw - imgW) / 2
      if (Math.abs(x - centerX) < snapThreshold) { x = centerX; snappedX = true }

      // Snap points for Y: center, top edge, bottom edge
      const centerY = (vh - imgH) / 2
      if (Math.abs(y - centerY) < snapThreshold) { y = centerY; snappedY = true }
      if (Math.abs(y - maxY) < snapThreshold) { y = maxY; snappedY = true } // snap to top
      if (Math.abs(y - minY) < snapThreshold) { y = minY; snappedY = true } // snap to bottom
    }

    return { x, y, snappedX, snappedY }
  }

  updateCropPosition() {
    if (!this.cropImg) return
    this.cropImg.style.width = this.baseW + "px"
    this.cropImg.style.height = this.baseH + "px"
    this.cropImg.style.left = "0px"
    this.cropImg.style.top = "0px"
    this.cropImg.style.transformOrigin = "0 0"
    this.cropImg.style.transform = `translate(${this.cropOffsetX}px, ${this.cropOffsetY}px) scale(${this.cropScale})`
  }

  cropApply() {
    const vw = this.cropViewport.offsetWidth
    const vh = this.cropViewport.offsetHeight
    const imgW = this.baseW * this.cropScale
    const imgH = this.baseH * this.cropScale
    const nw = this.cropImg.naturalWidth
    const nh = this.cropImg.naturalHeight

    const canvas = document.createElement("canvas")
    const ctx = canvas.getContext("2d")

    if (this.cropMode === "avatar") {
      const size = 512
      canvas.width = size
      canvas.height = size
      const vpCx = vw / 2
      const vpCy = vh / 2
      const r = 110
      const natPerPx = nw / imgW
      const sx = (vpCx - r - this.cropOffsetX) * natPerPx
      const sy = (vpCy - r - this.cropOffsetY) * natPerPx
      const sw = r * 2 * natPerPx
      const sh = r * 2 * natPerPx
      ctx.beginPath()
      ctx.arc(size/2, size/2, size/2, 0, Math.PI * 2)
      ctx.closePath()
      ctx.clip()
      ctx.drawImage(this.cropImg, sx, sy, sw, sh, 0, 0, size, size)
    } else {
      const outW = 960
      const outH = Math.round(960 * (vh / vw))
      canvas.width = outW
      canvas.height = outH
      const natPerPx = nw / imgW
      const sx = -this.cropOffsetX * natPerPx
      const sy = -this.cropOffsetY * natPerPx
      const sw = vw * natPerPx
      const sh = vh * natPerPx
      ctx.drawImage(this.cropImg, sx, sy, sw, sh, 0, 0, outW, outH)
    }

    canvas.toBlob((blob) => {
      if (!blob) return
      const file = new File([blob], `cropped_${this.cropMode}.png`, { type: "image/png" })
      const dt = new DataTransfer()
      dt.items.add(file)

      if (this.cropMode === "avatar" && this.hasAvatarInputTarget) {
        this.avatarInputTarget.files = dt.files
        this.updateAvatarPreviews(canvas.toDataURL())
      } else if (this.cropMode === "banner" && this.hasInputTarget) {
        this.inputTarget.files = dt.files
        this.updateBannerPreviews(canvas.toDataURL())
      }
      this.closeModal()
    }, "image/png")
  }

  cropCancel() {
    if (this.cropMode === "avatar" && this.hasAvatarInputTarget) {
      this.avatarInputTarget.value = ""
    } else if (this.hasInputTarget) {
      this.inputTarget.value = ""
    }
    this.closeModal()
  }

  closeModal() {
    if (this._cropCleanup) this._cropCleanup()
    if (this.modal) { this.modal.remove(); this.modal = null }
    this.cropImg = null
    this.cropViewport = null
    this.snapLineX = null
    this.snapLineY = null
    this.cropMode = null
  }

  // ========== PREVIEWS ==========
  updateAvatarPreviews(dataUrl) {
    if (this.hasAvatarPreviewTarget) {
      this.avatarPreviewTarget.src = dataUrl
      this.avatarPreviewTarget.classList.remove("hidden")
    }
    if (this.hasAvatarInitialTarget) this.avatarInitialTarget.classList.add("hidden")
    if (this.hasPreviewAvatarTarget) {
      this.previewAvatarTarget.src = dataUrl
      this.previewAvatarTarget.classList.remove("hidden")
    }
    if (this.hasPreviewAvatarInitialTarget) this.previewAvatarInitialTarget.classList.add("hidden")
  }

  updateBannerPreviews(dataUrl) {
    if (this.hasImageTarget) {
      this.imageTarget.src = dataUrl
      this.imageTarget.style.top = "0px"
      this.imageTarget.classList.remove("hidden")
    }
    if (this.hasPreviewBannerTarget) {
      this.previewBannerTarget.src = dataUrl
      this.previewBannerTarget.style.top = "0px"
      this.previewBannerTarget.classList.remove("hidden")
    }
    if (this.hasOffsetFieldTarget) this.offsetFieldTarget.value = 0
    if (this.hasHintTarget) this.hintTarget.textContent = ""
  }

  // ========== FILE INPUT HANDLERS ==========
  previewBannerFile(e) {
    const file = e.target.files[0]
    if (!file) return
    this.openCropModal("banner", file)
  }

  previewAvatarFile(e) {
    const file = e.target.files[0]
    if (!file) return
    this.openCropModal("avatar", file)
  }

  // ========== BANNER DRAG (settings page — inline reposition) ==========
  startDrag(e) {
    if (!this.hasImageTarget) return
    e.preventDefault()
    this.dragging = true
    this.startY = e.clientY
    this.startOffset = parseInt(this.offsetFieldTarget.value) || 0
    document.addEventListener("mousemove", this._onMouseMove)
    document.addEventListener("mouseup", this._onMouseUp)
  }

  onDrag(e) {
    if (!this.dragging) return
    const delta = e.clientY - this.startY
    const containerH = this.containerTarget.offsetHeight
    const imgEl = this.imageTarget
    const imageH = imgEl.naturalHeight * (this.containerTarget.offsetWidth / imgEl.naturalWidth)
    const maxOffset = 0
    const minOffset = Math.min(0, containerH - imageH)
    let newOffset = Math.max(minOffset, Math.min(maxOffset, this.startOffset + delta))
    imgEl.style.top = newOffset + "px"
    this.offsetFieldTarget.value = Math.round(newOffset)
    if (this.hasPreviewBannerTarget) {
      this.previewBannerTarget.style.top = Math.round(newOffset / 1.5) + "px"
    }
  }

  stopDrag() {
    this.dragging = false
    document.removeEventListener("mousemove", this._onMouseMove)
    document.removeEventListener("mouseup", this._onMouseUp)
  }

  // --- Live color picker updates ---
  updateColors() {
    const c1Input = this.element.querySelector('input[name="user[profile_color]"]')
    const c2Input = this.element.querySelector('input[name="user[profile_color_2]"]')
    if (!c1Input || !c2Input) return
    const c1 = c1Input.value
    const c2 = c2Input.value
    const grad = `linear-gradient(135deg, ${c1}, ${c2})`
    if (this.hasPreviewGradientTarget) this.previewGradientTarget.style.background = grad
    if (this.hasPreviewRingTarget) this.previewRingTarget.style.background = c2
    if (this.hasGradientPreviewStripTarget) this.gradientPreviewStripTarget.style.background = grad
  }

  disconnect() {
    document.removeEventListener("mousemove", this._onMouseMove)
    document.removeEventListener("mouseup", this._onMouseUp)
    this.closeModal()
  }
}
