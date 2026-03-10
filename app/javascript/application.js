import "@hotwired/turbo-rails"
import * as Turbo from "@hotwired/turbo"
import { Application } from "@hotwired/stimulus"

const application = Application.start()

// When a turbo-frame navigates to a page without a matching frame,
// perform a full-page visit instead of showing "Content missing"
document.addEventListener("turbo:frame-missing", (event) => {
  event.preventDefault()
  event.detail.visit(event.detail.response)
})

// Custom styled confirmation dialog for Turbo
Turbo.setConfirmMethod((message) => {
  return new Promise((resolve) => {
    const overlay = document.createElement("div")
    overlay.className = "modal-overlay fixed inset-0 z-[100] flex items-center justify-center bg-black/60"

    overlay.innerHTML = `
      <div class="bg-gray-800 rounded-lg shadow-2xl border border-gray-700 w-full max-w-md mx-4 overflow-hidden">
        <div class="px-5 pt-5 pb-4">
          <h3 class="text-lg font-semibold text-white mb-2">Are you sure?</h3>
          <p class="text-sm text-gray-300">${message.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</p>
        </div>
        <div class="flex justify-end gap-3 px-5 py-4 bg-gray-850 bg-gray-900/50">
          <button data-action="cancel" class="px-4 py-2 text-sm font-medium text-gray-300 hover:text-white hover:underline cursor-pointer">Cancel</button>
          <button data-action="confirm" class="px-4 py-2 text-sm font-medium bg-gradient-to-r from-danger-dark to-danger hover:from-danger hover:to-danger-light text-white rounded transition cursor-pointer">Confirm</button>
        </div>
      </div>
    `

    const cleanup = (result) => {
      overlay.remove()
      resolve(result)
    }

    overlay.addEventListener("click", (e) => {
      if (e.target === overlay) cleanup(false)
    })
    overlay.querySelector('[data-action="cancel"]').addEventListener("click", () => cleanup(false))
    overlay.querySelector('[data-action="confirm"]').addEventListener("click", () => cleanup(true))

    document.addEventListener("keydown", function handler(e) {
      if (e.key === "Escape") { document.removeEventListener("keydown", handler); cleanup(false) }
      if (e.key === "Enter") { document.removeEventListener("keydown", handler); cleanup(true) }
    })

    document.body.appendChild(overlay)
    overlay.querySelector('[data-action="confirm"]').focus()
  })
})

// Retry failed image loads once after 3s (covers race with background sync).
// If the retry also fails, apply a subtle placeholder style instead of the ugly broken icon.
document.addEventListener("error", (e) => {
  if (e.target.tagName !== "IMG") return
  if (!e.target.dataset.retried) {
    e.target.dataset.retried = "1"
    const src = e.target.src
    setTimeout(() => { e.target.src = ""; e.target.src = src }, 3000)
  } else {
    e.target.classList.add("img-broken")
  }
}, true)

// Lock image dimensions after load to prevent layout shift on re-render.
// Images with data-lock-dims get explicit width/height once naturalWidth is known.
// Caches dimensions by src URL so shimmer placeholders show at correct size.
const _imgDimCache = (() => {
  try { return JSON.parse(sessionStorage.getItem("imgDims") || "{}") } catch { return {} }
})()
function _saveImgDimCache() {
  try { sessionStorage.setItem("imgDims", JSON.stringify(_imgDimCache)) } catch {}
}
function lockImageDims(img) {
  if (img.naturalWidth && img.naturalHeight) {
    const maxW = parseFloat(getComputedStyle(img).maxWidth) || img.naturalWidth
    const maxH = parseFloat(getComputedStyle(img).maxHeight) || img.naturalHeight
    let w = img.naturalWidth, h = img.naturalHeight
    if (w > maxW) { h = h * (maxW / w); w = maxW }
    if (h > maxH) { w = w * (maxH / h); h = maxH }
    const rw = Math.round(w), rh = Math.round(h)
    img.setAttribute("width", rw)
    img.setAttribute("height", rh)
    img.classList.remove("img-loading")
    if (img.src) { _imgDimCache[img.src] = [rw, rh]; _saveImgDimCache() }
  }
}
// Pre-apply cached dimensions and loading class for shimmer placeholders
function applyCachedDims(root = document) {
  root.querySelectorAll("img[data-lock-dims]").forEach(img => {
    if (img.complete && img.naturalWidth) return // already loaded
    img.classList.add("img-loading")
    const cached = _imgDimCache[img.src]
    if (cached) {
      img.setAttribute("width", cached[0])
      img.setAttribute("height", cached[1])
    }
  })
}
document.addEventListener("load", (e) => {
  if (e.target.tagName === "IMG" && e.target.hasAttribute("data-lock-dims")) {
    lockImageDims(e.target)
  }
}, true)
// Also lock dims for images already loaded (cached)
function lockAllLoadedDims(root = document) {
  applyCachedDims(root)
  root.querySelectorAll("img[data-lock-dims]").forEach(img => {
    if (img.complete && img.naturalWidth) lockImageDims(img)
  })
}
document.addEventListener("turbo:load", () => lockAllLoadedDims())
document.addEventListener("turbo:frame-render", (e) => lockAllLoadedDims(e.target))
// Observe DOM for new img[data-lock-dims] elements (e.g. from insertAdjacentHTML)
new MutationObserver((mutations) => {
  for (const m of mutations) {
    for (const node of m.addedNodes) {
      if (node.nodeType !== 1) continue
      const imgs = node.tagName === "IMG" && node.hasAttribute("data-lock-dims")
        ? [node]
        : node.querySelectorAll ? [...node.querySelectorAll("img[data-lock-dims]")] : []
      for (const img of imgs) {
        if (img.complete && img.naturalWidth) { lockImageDims(img) }
        else {
          img.classList.add("img-loading")
          const cached = _imgDimCache[img.src]
          if (cached) { img.setAttribute("width", cached[0]); img.setAttribute("height", cached[1]) }
        }
      }
    }
  }
}).observe(document.body, { childList: true, subtree: true })
// Apply to images already in DOM on script init
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => lockAllLoadedDims())
} else {
  lockAllLoadedDims()
}

// Themed number input spinners — subtle inline chevrons
function wrapNumberInputs(root = document) {
  const chevronUp = '<svg viewBox="0 0 10 6" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M1 5L5 1L9 5"/></svg>'
  const chevronDown = '<svg viewBox="0 0 10 6" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M1 1L5 5L9 1"/></svg>'

  root.querySelectorAll('input[type="number"]').forEach(input => {
    if (input.closest('.number-input-wrap')) return
    const wrap = document.createElement('div')
    wrap.className = 'number-input-wrap'
    input.parentNode.insertBefore(wrap, input)
    wrap.appendChild(input)

    const up = document.createElement('button')
    up.type = 'button'
    up.className = 'num-btn num-btn-up'
    up.innerHTML = chevronUp
    up.tabIndex = -1
    up.addEventListener('click', () => { input.stepUp(); input.dispatchEvent(new Event('input', { bubbles: true })); input.dispatchEvent(new Event('change', { bubbles: true })) })

    const down = document.createElement('button')
    down.type = 'button'
    down.className = 'num-btn num-btn-down'
    down.innerHTML = chevronDown
    down.tabIndex = -1
    down.addEventListener('click', () => { input.stepDown(); input.dispatchEvent(new Event('input', { bubbles: true })); input.dispatchEvent(new Event('change', { bubbles: true })) })

    wrap.appendChild(up)
    wrap.appendChild(down)
  })
}
document.addEventListener('turbo:load', () => wrapNumberInputs())
document.addEventListener('turbo:frame-render', (e) => wrapNumberInputs(e.target))

// Invite embed "Joined" badge detection — runs on page load AND dynamically
// when new messages arrive via ActionCable (innerHTML/outerHTML insertions).
function badgeJoinedInvites(root = document) {
  const meta = document.querySelector('meta[name="user-server-gids"]')
  if (!meta) return
  const gids = new Set(meta.content.split(",").filter(Boolean))
  if (!gids.size) return
  root.querySelectorAll("[data-invite-gid]").forEach(el => {
    if (el.querySelector(".invite-joined-badge")) return
    const gid = el.dataset.inviteGid
    if (!gids.has(gid)) return
    const badge = document.createElement("span")
    badge.className = "invite-joined-badge ml-auto text-xs font-semibold text-green-400 bg-green-400/10 px-1.5 py-0.5 rounded shrink-0"
    badge.textContent = "Joined"
    el.appendChild(badge)
  })
}
document.addEventListener("turbo:load", () => badgeJoinedInvites())
document.addEventListener("turbo:frame-render", (e) => badgeJoinedInvites(e.target))
// MutationObserver catches messages inserted via ActionCable (innerHTML/outerHTML)
const _inviteBadgeObserver = new MutationObserver((mutations) => {
  for (const m of mutations) {
    for (const node of m.addedNodes) {
      if (node.nodeType !== 1) continue
      if (node.matches?.("[data-invite-gid]") || node.querySelector?.("[data-invite-gid]")) {
        badgeJoinedInvites(node.matches?.("[data-invite-gid]") ? node.parentElement : node)
      }
    }
  }
})
_inviteBadgeObserver.observe(document.body, { childList: true, subtree: true })

// Custom styled select dropdowns — replaces native <select> with themed dropdown
// so the open-state popup matches the dark UI (native GTK popups ignore CSS).
const chevronSvg = '<svg class="cs-chevron" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 4.5L6 7.5L9 4.5"/></svg>'

function wrapSelectElements(root = document) {
  root.querySelectorAll("select").forEach(select => {
    if (select.closest(".custom-select-wrap")) return
    if (select.multiple) return  // skip multi-selects

    // Inherit every class the <select> had (bg, border, rounded, etc.)
    const origClasses = select.className

    const wrap = document.createElement("div")
    wrap.className = "custom-select-wrap"

    // Preserve original data attributes on the wrapper for Stimulus target lookups
    select.parentNode.insertBefore(wrap, select)
    wrap.appendChild(select)

    // Create the visible button (styled like the original select)
    const btn = document.createElement("button")
    btn.type = "button"
    btn.className = `custom-select-btn ${origClasses}`
    btn.setAttribute("aria-haspopup", "listbox")
    btn.setAttribute("aria-expanded", "false")

    // Label span
    const label = document.createElement("span")
    label.className = "cs-label truncate"
    btn.appendChild(label)
    btn.insertAdjacentHTML("beforeend", chevronSvg)
    wrap.appendChild(btn)

    // Dropdown list
    const list = document.createElement("div")
    list.className = "custom-select-list"
    list.setAttribute("role", "listbox")
    list.hidden = true
    wrap.appendChild(list)

    let focusedIdx = -1

    function buildOptions() {
      list.innerHTML = ""
      const options = Array.from(select.options)
      options.forEach((opt, i) => {
        const item = document.createElement("div")
        item.className = "custom-select-option"
        item.setAttribute("role", "option")
        item.dataset.value = opt.value
        item.textContent = opt.textContent
        if (opt.selected) item.classList.add("selected")
        item.addEventListener("mousedown", (e) => {
          e.preventDefault()
          select.value = opt.value
          select.dispatchEvent(new Event("change", { bubbles: true }))
          updateLabel()
          close()
        })
        list.appendChild(item)
      })
      updateLabel()
    }

    function updateLabel() {
      const sel = select.options[select.selectedIndex]
      label.textContent = sel ? sel.textContent : ""
      // Update selected styling
      list.querySelectorAll(".custom-select-option").forEach(item => {
        item.classList.toggle("selected", item.dataset.value === select.value)
      })
    }

    function positionList() {
      const rect = btn.getBoundingClientRect()
      const spaceBelow = window.innerHeight - rect.bottom - 8
      const spaceAbove = rect.top - 8
      const listHeight = Math.min(240, list.scrollHeight)

      if (spaceBelow >= listHeight || spaceBelow >= spaceAbove) {
        list.style.top = `${rect.bottom + 2}px`
      } else {
        list.style.top = `${rect.top - listHeight - 2}px`
      }
      list.style.left = `${rect.left}px`
      list.style.minWidth = `${rect.width}px`
    }

    function open() {
      buildOptions()
      list.hidden = false
      wrap.classList.add("open")
      btn.setAttribute("aria-expanded", "true")
      positionList()
      // Scroll selected into view
      const selItem = list.querySelector(".selected")
      if (selItem) selItem.scrollIntoView({ block: "nearest" })
      focusedIdx = Array.from(select.options).findIndex(o => o.selected)
      updateFocus()
    }

    function close() {
      list.hidden = true
      wrap.classList.remove("open")
      btn.setAttribute("aria-expanded", "false")
      focusedIdx = -1
    }

    function updateFocus() {
      const items = list.querySelectorAll(".custom-select-option")
      items.forEach((it, i) => it.classList.toggle("focused", i === focusedIdx))
      if (focusedIdx >= 0 && items[focusedIdx]) {
        items[focusedIdx].scrollIntoView({ block: "nearest" })
      }
    }

    btn.addEventListener("mousedown", (e) => {
      e.preventDefault()
      if (list.hidden) { open() } else { close() }
    })

    btn.addEventListener("keydown", (e) => {
      const items = list.querySelectorAll(".custom-select-option")
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault()
        if (list.hidden) {
          open()
        } else if (focusedIdx >= 0 && items[focusedIdx]) {
          items[focusedIdx].dispatchEvent(new MouseEvent("mousedown"))
        }
      } else if (e.key === "Escape") {
        close()
      } else if (e.key === "ArrowDown") {
        e.preventDefault()
        if (list.hidden) { open(); return }
        focusedIdx = Math.min(focusedIdx + 1, items.length - 1)
        updateFocus()
      } else if (e.key === "ArrowUp") {
        e.preventDefault()
        if (list.hidden) { open(); return }
        focusedIdx = Math.max(focusedIdx - 1, 0)
        updateFocus()
      }
    })

    // Close on outside click
    document.addEventListener("mousedown", (e) => {
      if (!wrap.contains(e.target)) close()
    })

    // Close on scroll so fixed-position list doesn't float away
    document.addEventListener("scroll", () => {
      if (!list.hidden) close()
    }, true)

    // Watch for programmatic option changes (e.g. voice device enumeration)
    const observer = new MutationObserver(() => {
      updateLabel()
      if (!list.hidden) buildOptions()
    })
    observer.observe(select, { childList: true, subtree: true, attributes: true })

    // Also listen for programmatic value changes
    select.addEventListener("change", () => updateLabel())

    buildOptions()
  })
}
document.addEventListener("turbo:load", () => wrapSelectElements())
document.addEventListener("turbo:frame-render", (e) => wrapSelectElements(e.target))
// Run immediately for the initial page load
if (document.readyState !== "loading") { wrapSelectElements() } else {
  document.addEventListener("DOMContentLoaded", () => wrapSelectElements())
}

// Restore emoji PUA maps from localStorage (for page refresh resilience)
try {
  const stored = localStorage.getItem('_emojiMap')
  if (stored) {
    window._emojiMap = JSON.parse(stored)
    window._emojiPUA = JSON.parse(localStorage.getItem('_emojiPUA') || '{}')
    window._emojiReverse = JSON.parse(localStorage.getItem('_emojiReverse') || '{}')
    window._nextPUA = parseInt(localStorage.getItem('_nextPUA') || '0') || 0xE000
  }
} catch(e) {}

import MessageFormController from "./controllers/message_form_controller"
import ScrollPositionController from "./controllers/scroll_position_controller"
import ToastController from "./controllers/toast_controller"
import UnifiedPickerController from "./controllers/unified_picker_controller"
import GifSaveController from "./controllers/gif_save_controller"
import DropdownController from "./controllers/dropdown_controller"
import ServerMembersController from "./controllers/server_members_controller"
import ProfileCardController from "./controllers/profile_card_controller"
import AppearanceController from "./controllers/appearance_controller"
import MentionAutocompleteController from "./controllers/mention_autocomplete_controller"
import NotificationBadgeController from "./controllers/notification_badge_controller"
import MemberContextController from "./controllers/member_context_controller"
import CategoryCollapseController from "./controllers/category_collapse_controller"
import ChannelSidebarController from "./controllers/channel_sidebar_controller"
import ChannelReorderController from "./controllers/channel_reorder_controller"
import ImagePreviewController from "./controllers/image_preview_controller"
import MobileNavController from "./controllers/mobile_nav_controller"
import BannerEditorController from "./controllers/banner_editor_controller"
import DmMessageFormController from "./controllers/dm_message_form_controller"
import InviteMenuController from "./controllers/invite_menu_controller"
import VideoPlayerController from "./controllers/video_player_controller"
import NostrKeyExportController from "./controllers/nostr_key_export_controller"
import RoleEditorController from "./controllers/role_editor_controller"
import MemberRolesController from "./controllers/member_roles_controller"
import ServerRailController from "./controllers/server_rail_controller"
import MessageActionsController from "./controllers/message_actions_controller"
import SettingsSidebarController from "./controllers/settings_sidebar_controller"
import DirtyFormController from "./controllers/dirty_form_controller"
import FrameLoadingController from "./controllers/frame_loading_controller"
import EmojiInputController from "./controllers/emoji_input_controller"
import ServerProfilePreviewController from "./controllers/server_profile_preview_controller"
import SettingsOverlayController from "./controllers/settings_overlay_controller"
import ThemePickerController from "./controllers/theme_picker_controller"
import ClipboardController from "./controllers/clipboard_controller"
import NostrSearchController from "./controllers/nostr_search_controller"
import EncryptedChannelController from "./controllers/encrypted_channel_controller"
import VoiceChannelController from "./controllers/voice_channel_controller"
import VoiceContextController from "./controllers/voice_context_controller"
import VoiceSettingsController from "./controllers/voice_settings_controller"
import VoiceDeviceSelectController from "./controllers/voice_device_select_controller"
import ChannelTypeController from "./controllers/channel_type_controller"
import ServerIconPreviewController from "./controllers/server_icon_preview_controller"
import SidechatController from "./controllers/sidechat_controller"
import MemberManagementController from "./controllers/member_management_controller"
import CallController from "./controllers/call_controller"
import GroupChatModalController from "./controllers/group_chat_modal_controller"
import AddServerModalController from "./controllers/add_server_modal_controller"
import ServerInvitePreviewController from "./controllers/server_invite_preview_controller"
import StatusEmojiController from "./controllers/status_emoji_controller"
import MessageSearchController from "./controllers/message_search_controller"
import PruningStrategyController from "./controllers/pruning_strategy_controller"
import KeywordFilterController from "./controllers/keyword_filter_controller"

application.register("message-form", MessageFormController)
application.register("scroll-position", ScrollPositionController)
application.register("toast", ToastController)
application.register("unified-picker", UnifiedPickerController)
application.register("gif-save", GifSaveController)
application.register("dropdown", DropdownController)
application.register("server-members", ServerMembersController)
application.register("profile-card", ProfileCardController)
application.register("appearance", AppearanceController)
application.register("mention-autocomplete", MentionAutocompleteController)
application.register("notification-badge", NotificationBadgeController)
application.register("member-context", MemberContextController)
application.register("category-collapse", CategoryCollapseController)
application.register("channel-sidebar", ChannelSidebarController)
application.register("channel-reorder", ChannelReorderController)
application.register("image-preview", ImagePreviewController)
application.register("mobile-nav", MobileNavController)
application.register("banner-editor", BannerEditorController)
application.register("dm-message-form", DmMessageFormController)
application.register("invite-menu", InviteMenuController)
application.register("video-player", VideoPlayerController)
application.register("nostr-key-export", NostrKeyExportController)
application.register("role-editor", RoleEditorController)
application.register("member-roles", MemberRolesController)
application.register("server-rail", ServerRailController)
application.register("message-actions", MessageActionsController)
application.register("settings-sidebar", SettingsSidebarController)
application.register("dirty-form", DirtyFormController)
application.register("frame-loading", FrameLoadingController)
application.register("emoji-input", EmojiInputController)
application.register("server-profile-preview", ServerProfilePreviewController)
application.register("settings-overlay", SettingsOverlayController)
application.register("theme-picker", ThemePickerController)
application.register("clipboard", ClipboardController)
application.register("nostr-search", NostrSearchController)
application.register("encrypted-channel", EncryptedChannelController)
application.register("voice-channel", VoiceChannelController)
application.register("voice-context", VoiceContextController)
application.register("voice-settings", VoiceSettingsController)
application.register("voice-device-select", VoiceDeviceSelectController)
application.register("channel-type", ChannelTypeController)
application.register("server-icon-preview", ServerIconPreviewController)
application.register("sidechat", SidechatController)
application.register("member-management", MemberManagementController)
application.register("call", CallController)
application.register("group-chat-modal", GroupChatModalController)
application.register("add-server-modal", AddServerModalController)
application.register("server-invite-preview", ServerInvitePreviewController)
application.register("status-emoji", StatusEmojiController)
application.register("message-search", MessageSearchController)
application.register("pruning-strategy", PruningStrategyController)
application.register("keyword-filter", KeywordFilterController)

// --- Custom spatially-aware tooltips: convert title → data-tooltip, position with JS ---
;(function() {
  const DELAY = 400
  const GAP = 6
  const PAD = 6
  let tip, arrow, showTimer, currentEl

  function ensureEl() {
    if (tip) return
    tip = document.createElement("div")
    tip.id = "tooltip-el"
    arrow = document.createElement("div")
    arrow.id = "tooltip-arrow"
    tip.appendChild(arrow)
    document.body.appendChild(tip)
  }

  function show(el) {
    const text = el.dataset.tooltip
    if (!text) return
    ensureEl()
    currentEl = el
    // Set text (arrow is first child, text after)
    tip.childNodes.forEach((n, i) => { if (i > 0) n.remove() })
    tip.appendChild(document.createTextNode(text))
    tip.classList.remove("visible")
    tip.style.left = "0"
    tip.style.top = "0"

    // Measure
    const r = el.getBoundingClientRect()
    const tw = tip.offsetWidth
    const th = tip.offsetHeight
    const vw = window.innerWidth
    const vh = window.innerHeight

    // Pick side: prefer top, fall back to bottom, then left, then right
    let top, left, side
    if (r.top - th - GAP >= PAD) {
      side = "top"
      top = r.top - th - GAP
      left = r.left + r.width / 2 - tw / 2
    } else if (r.bottom + th + GAP <= vh - PAD) {
      side = "bottom"
      top = r.bottom + GAP
      left = r.left + r.width / 2 - tw / 2
    } else if (r.left - tw - GAP >= PAD) {
      side = "left"
      top = r.top + r.height / 2 - th / 2
      left = r.left - tw - GAP
    } else {
      side = "right"
      top = r.top + r.height / 2 - th / 2
      left = r.right + GAP
    }

    // Clamp to viewport
    left = Math.max(PAD, Math.min(left, vw - tw - PAD))
    top = Math.max(PAD, Math.min(top, vh - th - PAD))

    tip.style.left = Math.round(left) + "px"
    tip.style.top = Math.round(top) + "px"

    // Position arrow
    const aw = 8
    if (side === "top") {
      arrow.style.left = Math.round(Math.min(Math.max(r.left + r.width / 2 - left - aw / 2, 4), tw - aw - 4)) + "px"
      arrow.style.top = (th - aw / 2) + "px"
      arrow.style.bottom = ""
      arrow.style.right = ""
    } else if (side === "bottom") {
      arrow.style.left = Math.round(Math.min(Math.max(r.left + r.width / 2 - left - aw / 2, 4), tw - aw - 4)) + "px"
      arrow.style.top = (-aw / 2) + "px"
      arrow.style.bottom = ""
      arrow.style.right = ""
    } else if (side === "left") {
      arrow.style.top = Math.round(Math.min(Math.max(r.top + r.height / 2 - top - aw / 2, 4), th - aw - 4)) + "px"
      arrow.style.left = (tw - aw / 2) + "px"
      arrow.style.right = ""
      arrow.style.bottom = ""
    } else {
      arrow.style.top = Math.round(Math.min(Math.max(r.top + r.height / 2 - top - aw / 2, 4), th - aw - 4)) + "px"
      arrow.style.left = (-aw / 2) + "px"
      arrow.style.right = ""
      arrow.style.bottom = ""
    }

    tip.classList.add("visible")
  }

  function hide() {
    clearTimeout(showTimer)
    currentEl = null
    if (tip) tip.classList.remove("visible")
  }

  function onEnter(e) {
    const el = e.target.closest("[data-tooltip]")
    if (!el) return
    clearTimeout(showTimer)
    showTimer = setTimeout(() => show(el), DELAY)
  }

  function onLeave(e) {
    const el = e.target.closest("[data-tooltip]")
    if (!el) return
    hide()
  }

  document.addEventListener("pointerenter", onEnter, true)
  document.addEventListener("pointerleave", onLeave, true)
  document.addEventListener("pointerdown", hide, true)
  document.addEventListener("scroll", hide, true)

  // Convert title attributes to data-tooltip
  function convertTitles(root) {
    if (!root || !root.querySelectorAll) return
    root.querySelectorAll("[title]").forEach(el => {
      if (el.dataset.tooltip !== undefined) return
      const t = el.getAttribute("title")
      if (!t) return
      el.dataset.tooltip = t
      el.removeAttribute("title")
    })
  }
  convertTitles(document)
  document.addEventListener("turbo:load", () => convertTitles(document))
  document.addEventListener("turbo:frame-render", (e) => convertTitles(e.target))
  new MutationObserver((mutations) => {
    for (const m of mutations) {
      for (const node of m.addedNodes) {
        if (node.nodeType === 1) {
          if (node.hasAttribute?.("title")) { convertTitles(node.parentElement || document) }
          else if (node.querySelector?.("[title]")) { convertTitles(node) }
        }
      }
    }
  }).observe(document.body, { childList: true, subtree: true })
})()
// External link confirmation dialog — intercepts clicks on external <a> tags
// and shows a modal so the user can verify the URL before proceeding.
document.addEventListener("click", (e) => {
  const link = e.target.closest("a[href]")
  if (!link) return
  // Skip if inside a settings form (turbo-frame navigations)
  if (link.closest("turbo-frame#settings-frame") && link.hasAttribute("data-turbo-frame")) return
  const href = link.getAttribute("href")
  if (!href || href.startsWith("/") || href.startsWith("#")) return
  if (href.startsWith("nostr:")) return
  // Skip javascript: and mailto: links
  if (href.startsWith("javascript:") || href.startsWith("mailto:")) return

  let url
  try {
    url = new URL(href, window.location.origin)
  } catch {
    return
  }
  if (url.origin === window.location.origin) return

  e.preventDefault()
  e.stopPropagation()

  const overlay = document.createElement("div")
  overlay.className = "modal-overlay fixed inset-0 z-[100] flex items-center justify-center bg-black/60"
  overlay.innerHTML = `
    <div class="bg-gray-800 rounded-lg shadow-2xl border border-gray-700 w-full max-w-md mx-4 overflow-hidden">
      <div class="px-5 pt-5 pb-4">
        <h3 class="text-lg font-semibold text-white mb-2">You are about to leave Inferno</h3>
        <p class="text-sm text-gray-400 mb-3">This link will take you to an external site:</p>
        <div class="bg-gray-900 rounded-md px-3 py-2 border border-gray-700 break-all">
          <code class="text-sm text-accent-light font-mono">${href.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</code>
        </div>
      </div>
      <div class="flex justify-end gap-3 px-5 py-4 bg-gray-900/50">
        <button data-action="cancel" class="px-4 py-2 text-sm font-medium text-gray-300 hover:text-white hover:underline cursor-pointer">Cancel</button>
        <button data-action="continue" class="px-4 py-2 text-sm font-medium bg-accent hover:bg-accent-light text-white rounded transition cursor-pointer">Continue</button>
      </div>
    </div>
  `

  const cleanup = () => overlay.remove()

  overlay.addEventListener("click", (ev) => {
    if (ev.target === overlay) cleanup()
  })
  overlay.querySelector('[data-action="cancel"]').addEventListener("click", cleanup)
  overlay.querySelector('[data-action="continue"]').addEventListener("click", () => {
    cleanup()
    window.open(href, "_blank", "noopener")
  })

  document.addEventListener("keydown", function handler(ev) {
    if (ev.key === "Escape") { document.removeEventListener("keydown", handler); cleanup() }
    if (ev.key === "Enter") { document.removeEventListener("keydown", handler); cleanup(); window.open(href, "_blank", "noopener") }
  })

  document.body.appendChild(overlay)
  overlay.querySelector('[data-action="continue"]').focus()
})

// rebuild trigger
