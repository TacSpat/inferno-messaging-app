import "@hotwired/turbo-rails"
import * as Turbo from "@hotwired/turbo"
import { Application } from "@hotwired/stimulus"

const application = Application.start()

// Custom styled confirmation dialog for Turbo
Turbo.setConfirmMethod((message) => {
  return new Promise((resolve) => {
    const overlay = document.createElement("div")
    overlay.className = "fixed inset-0 z-[100] flex items-center justify-center bg-black/60"

    overlay.innerHTML = `
      <div class="bg-gray-800 rounded-lg shadow-2xl border border-gray-700 w-full max-w-md mx-4 overflow-hidden">
        <div class="px-5 pt-5 pb-4">
          <h3 class="text-lg font-semibold text-white mb-2">Are you sure?</h3>
          <p class="text-sm text-gray-300">${message.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</p>
        </div>
        <div class="flex justify-end gap-3 px-5 py-4 bg-gray-850 bg-gray-900/50">
          <button data-action="cancel" class="px-4 py-2 text-sm font-medium text-gray-300 hover:text-white hover:underline cursor-pointer">Cancel</button>
          <button data-action="confirm" class="px-4 py-2 text-sm font-medium bg-red-600 hover:bg-red-700 text-white rounded transition cursor-pointer">Confirm</button>
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
import VoiceChannelController from "./controllers/voice_channel_controller"
import VoiceContextController from "./controllers/voice_context_controller"
import InstanceSyncController from "./controllers/instance_sync_controller"

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
application.register("voice-channel", VoiceChannelController)
application.register("voice-context", VoiceContextController)
application.register("instance-sync", InstanceSyncController)
// rebuild trigger
