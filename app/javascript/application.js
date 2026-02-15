import "@hotwired/turbo-rails"
import { Application } from "@hotwired/stimulus"

const application = Application.start()

import MessageFormController from "./controllers/message_form_controller"
import ScrollPositionController from "./controllers/scroll_position_controller"
import ToastController from "./controllers/toast_controller"
import EmojiPickerController from "./controllers/emoji_picker_controller"
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
import SettingsModalController from "./controllers/settings_modal_controller"
import ImagePreviewController from "./controllers/image_preview_controller"
import MobileNavController from "./controllers/mobile_nav_controller"
import BannerEditorController from "./controllers/banner_editor_controller"
import DmMessageFormController from "./controllers/dm_message_form_controller"
import InviteMenuController from "./controllers/invite_menu_controller"
import VideoPlayerController from "./controllers/video_player_controller"
import NostrKeyExportController from "./controllers/nostr_key_export_controller"
import RoleEditorController from "./controllers/role_editor_controller"
import MemberRolesController from "./controllers/member_roles_controller"

application.register("message-form", MessageFormController)
application.register("scroll-position", ScrollPositionController)
application.register("toast", ToastController)
application.register("emoji-picker", EmojiPickerController)
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
application.register("settings-modal", SettingsModalController)
application.register("image-preview", ImagePreviewController)
application.register("mobile-nav", MobileNavController)
application.register("banner-editor", BannerEditorController)
application.register("dm-message-form", DmMessageFormController)
application.register("invite-menu", InviteMenuController)
application.register("video-player", VideoPlayerController)
application.register("nostr-key-export", NostrKeyExportController)
application.register("role-editor", RoleEditorController)
application.register("member-roles", MemberRolesController)
// rebuild trigger
