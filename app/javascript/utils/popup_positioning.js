/**
 * Position a popup element relative to an anchor, staying within the viewport.
 *
 * @param {HTMLElement} popup - The popup element (must be position: fixed)
 * @param {DOMRect|{x: number, y: number}} anchor - Anchor rect or point
 * @param {Object} [options]
 * @param {"above"|"below"} [options.preferredSide="above"]
 * @param {number} [options.gap=8] - px between anchor and popup
 * @param {number} [options.viewportPadding=8] - min px from viewport edge
 * @param {"left"|"right"|"center"} [options.horizontalAlign="right"]
 */
export function positionPopup(popup, anchor, options = {}) {
  const {
    preferredSide = "above",
    gap = 8,
    viewportPadding = 8,
    horizontalAlign = "right"
  } = options

  // Account for CSS zoom on <html> — getBoundingClientRect returns zoomed
  // coords but fixed positioning and window.innerWidth/Height are unzoomed
  const zoom = parseFloat(getComputedStyle(document.documentElement).zoom) || 1

  // Ensure popup is visible so we can measure it
  const wasHidden = popup.style.visibility === "hidden"
  popup.style.visibility = "hidden"
  popup.style.display = ""

  const popupRect = popup.getBoundingClientRect()
  const pw = popupRect.width / zoom
  const ph = popupRect.height / zoom

  // Normalize anchor to a rect, adjusting for zoom
  const raw = anchor instanceof DOMRect || (anchor.top !== undefined && anchor.bottom !== undefined)
    ? anchor
    : { top: anchor.y, bottom: anchor.y, left: anchor.x, right: anchor.x, width: 0, height: 0 }
  const rect = {
    top: raw.top / zoom,
    bottom: raw.bottom / zoom,
    left: raw.left / zoom,
    right: raw.right / zoom,
    width: (raw.width || 0) / zoom,
    height: (raw.height || 0) / zoom
  }

  const vpW = window.innerWidth
  const vpH = window.innerHeight

  // Vertical: try preferred side, flip if not enough room
  let top
  if (preferredSide === "above") {
    if (rect.top - ph - gap >= viewportPadding) {
      top = rect.top - ph - gap
    } else {
      top = rect.bottom + gap
    }
  } else {
    if (rect.bottom + ph + gap <= vpH - viewportPadding) {
      top = rect.bottom + gap
    } else {
      top = rect.top - ph - gap
    }
  }

  // Horizontal alignment
  let left
  if (horizontalAlign === "right") {
    left = rect.right - pw
  } else if (horizontalAlign === "left") {
    left = rect.left
  } else {
    left = rect.left + rect.width / 2 - pw / 2
  }

  // Clamp to viewport
  top = Math.max(viewportPadding, Math.min(top, vpH - ph - viewportPadding))
  left = Math.max(viewportPadding, Math.min(left, vpW - pw - viewportPadding))

  popup.style.position = "fixed"
  popup.style.top = `${Math.round(top)}px`
  popup.style.left = `${Math.round(left)}px`

  if (!wasHidden) {
    popup.style.visibility = ""
  }
}
