import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container", "image", "hint", "offsetField", "input",
                    "avatarPreview", "avatarInput", "avatarInitial",
                    "previewBanner", "previewAvatar", "previewAvatarInitial", "previewGradient", "previewRing", "previewCard", "gradientPreviewStrip"]

  connect() {
    console.log("[banner-editor] connected")
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

    // Remove old modal if exists
    if (this.modal) this.modal.remove()

    const reader = new FileReader()
    reader.onload = (ev) => {
      this.cropDataUrl = ev.target.result
      this.buildAndShowModal(mode, ev.target.result)
    }
    reader.readAsDataURL(file)
  }

  buildAndShowModal(mode, src) {
    const vpHeight = mode === "avatar" ? 300 : 180
    const title = mode === "avatar" ? "Edit Avatar" : "Edit Banner"

    this.modal = document.createElement("div")
    this.modal.className = "fixed inset-0 z-[300] flex items-center justify-center bg-black/70"
    this.modal.innerHTML = `
      <div class="bg-gray-800 rounded-xl shadow-2xl w-full max-w-lg mx-4">
        <div class="px-5 pt-5 pb-3">
          <h3 class="text-white text-lg font-semibold">${title}</h3>
          <p class="text-gray-400 text-sm mt-1">Drag to reposition, use slider to zoom</p>
        </div>
        <div class="relative mx-5 rounded-lg overflow-hidden bg-gray-900" data-crop-vp
             style="height: ${vpHeight}px; cursor: grab;">
          <img src="${src}" data-crop-img
               style="position: absolute; left: 0; top: 0; pointer-events: none; user-select: none;" />
          ${mode === "avatar" ? `
          <div class="absolute inset-0 pointer-events-none">
            <svg class="w-full h-full" viewBox="0 0 480 300" preserveAspectRatio="none">
              <defs>
                <mask id="crop-hole">
                  <rect width="480" height="300" fill="white"/>
                  <circle cx="240" cy="150" r="110" fill="black"/>
                </mask>
              </defs>
              <rect width="480" height="300" fill="rgba(0,0,0,0.55)" mask="url(#crop-hole)"/>
              <circle cx="240" cy="150" r="110" fill="none" stroke="white" stroke-width="2" opacity="0.5"/>
            </svg>
          </div>` : ""}
        </div>
        <div class="px-5 py-3 flex items-center gap-3">
          <span class="text-gray-400 text-xs">Zoom</span>
          <input type="range" min="100" max="300" value="100" class="flex-1 accent-indigo-500" data-crop-zoom />
          <span class="text-gray-400 text-xs w-10 text-right" data-crop-zoom-label>1.0x</span>
        </div>
        <div class="px-5 pb-5 flex justify-end gap-3">
          <button type="button" class="px-4 py-2 text-sm text-gray-300 hover:text-white transition" data-crop-cancel>Cancel</button>
          <button type="button" class="px-5 py-2 text-sm bg-indigo-600 hover:bg-indigo-700 text-white rounded font-semibold transition" data-crop-apply>Apply</button>
        </div>
      </div>
    `
    document.body.appendChild(this.modal)

    this.cropImg = this.modal.querySelector("[data-crop-img]")
    this.cropViewport = this.modal.querySelector("[data-crop-vp]")
    const zoomInput = this.modal.querySelector("[data-crop-zoom]")
    const zoomLabel = this.modal.querySelector("[data-crop-zoom-label]")

    // Wait for image to load to get dimensions
    this.cropImg.onload = () => {
      const vw = this.cropViewport.offsetWidth
      const vh = this.cropViewport.offsetHeight
      const nw = this.cropImg.naturalWidth
      const nh = this.cropImg.naturalHeight

      // Fit: cover the viewport
      const scale = Math.min(vw / nw, vh / nh)
      this.baseW = nw * scale
      this.baseH = nh * scale
      this.cropImg.style.width = this.baseW + "px"
      this.cropImg.style.height = this.baseH + "px"
      // Center
      this.cropOffsetX = (vw - this.baseW) / 2
      this.cropOffsetY = (vh - this.baseH) / 2
      this.updateCropPosition()
      console.log("[banner-editor] image loaded", nw, "x", nh, "-> base", this.baseW, "x", this.baseH)
    }

    // Drag
    let dragStartX, dragStartY, dragStartOX, dragStartOY
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
      this.cropOffsetX = dragStartOX + (pt.clientX - dragStartX)
      this.cropOffsetY = dragStartOY + (pt.clientY - dragStartY)
      this.updateCropPosition()
    }
    const onUp = () => {
      this.cropDragging = false
      if (this.cropViewport) this.cropViewport.style.cursor = "grab"
    }
    this.cropViewport.addEventListener("mousedown", onDown)
    this.cropViewport.addEventListener("touchstart", onDown, { passive: false })
    document.addEventListener("mousemove", onMove)
    document.addEventListener("mouseup", onUp)
    document.addEventListener("touchmove", onMove, { passive: false })
    document.addEventListener("touchend", onUp)

    // Store cleanup
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
      this.updateCropPosition()
    })

    // Buttons
    this.modal.querySelector("[data-crop-cancel]").addEventListener("click", () => this.cropCancel())
    this.modal.querySelector("[data-crop-apply]").addEventListener("click", () => this.cropApply())
  }

  updateCropPosition() {
    if (!this.cropImg) return
    // Keep image at base size, use transform for zoom + position
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
      // Map viewport center circle (r=110) to canvas
      const vpCx = vw / 2
      const vpCy = vh / 2
      const r = 110
      // Source rect in natural coords
      const natPerPx = nw / imgW
      const sx = (vpCx - r - this.cropOffsetX) * natPerPx
      const sy = (vpCy - r - this.cropOffsetY) * natPerPx
      const sw = r * 2 * natPerPx
      const sh = r * 2 * natPerPx
      // Clip to circle
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
    // Clear file input
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

  // ========== BANNER DRAG (settings page) ==========
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
    // Update preview card gradient body
    if (this.hasPreviewGradientTarget) this.previewGradientTarget.style.background = grad
    // Update avatar ring
    if (this.hasPreviewRingTarget) this.previewRingTarget.style.background = c2
    // Update gradient preview strip
    if (this.hasGradientPreviewStripTarget) this.gradientPreviewStripTarget.style.background = grad
  }

  disconnect() {
    document.removeEventListener("mousemove", this._onMouseMove)
    document.removeEventListener("mouseup", this._onMouseUp)
    this.closeModal()
  }
}
