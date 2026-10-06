//! Permissions, following Rails' `Role` model (`app/models/role.rb`) with
//! two holes closed:
//!
//! - Rails treats any role carrying `"owner": true` as all-powerful, so anyone
//!   who can edit roles can mint an owner role. Here ownership is only ever
//!   the server's pinned owner key; the `owner` permission in a role is
//!   ignored.
//! - Rails accepts any member event its subject signs, including its `roles`
//!   tag, so a member can grant themselves admin. Here a self-signed member
//!   event can join, leave, and set nickname and profile, nothing more.

use serde_json::{Map, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Permission {
    SendMessages,
    ReadMessages,
    ReadMessageHistory,
    AttachFiles,
    AddReactions,
    ChangeNickname,
    CreateInvite,
    CreateEmojis,
    CreateStickers,
    MentionEveryone,
    ManageMessages,
    ManageChannels,
    ManageRoles,
    ManageInvites,
    ManageEmojis,
    ManageServer,
    KickMembers,
    BanMembers,
    Administrator,
    ConnectVoice,
    Speak,
    Video,
    ScreenShare,
    MuteMembers,
    DeafenMembers,
    MoveMembers,
    /// Rails' three on-by-default permissions: allowed unless a role turns
    /// them off.
    SendGifs,
    SendCustomEmojis,
    SendCustomStickers,
}

impl Permission {
    pub fn key(self) -> &'static str {
        use Permission::*;
        match self {
            SendMessages => "send_messages",
            ReadMessages => "read_messages",
            ReadMessageHistory => "read_message_history",
            AttachFiles => "attach_files",
            AddReactions => "add_reactions",
            ChangeNickname => "change_nickname",
            CreateInvite => "create_invite",
            CreateEmojis => "create_emojis",
            CreateStickers => "create_stickers",
            MentionEveryone => "mention_everyone",
            ManageMessages => "manage_messages",
            ManageChannels => "manage_channels",
            ManageRoles => "manage_roles",
            ManageInvites => "manage_invites",
            ManageEmojis => "manage_emojis",
            ManageServer => "manage_server",
            KickMembers => "kick_members",
            BanMembers => "ban_members",
            Administrator => "administrator",
            ConnectVoice => "connect_voice",
            Speak => "speak",
            Video => "video",
            ScreenShare => "screen_share",
            MuteMembers => "mute_members",
            DeafenMembers => "deafen_members",
            MoveMembers => "move_members",
            SendGifs => "send_gifs",
            SendCustomEmojis => "send_custom_emojis",
            SendCustomStickers => "send_custom_stickers",
        }
    }
}

/// Does this role permission map grant `p`? `administrator` grants
/// everything (as in Rails); `owner` grants nothing extra.
pub fn grants(permissions: &Map<String, Value>, p: Permission) -> bool {
    let on = |k: &str| permissions.get(k) == Some(&Value::Bool(true));
    let default_on = matches!(p, Permission::SendGifs | Permission::SendCustomEmojis | Permission::SendCustomStickers);
    on(Permission::Administrator.key()) || on(p.key()) || (default_on && permissions.get(p.key()) != Some(&Value::Bool(false)))
}

/// Which permission an authority-bearing state event needs. Matches Rails'
/// `NostrServerAuth::PERMISSION_FOR_KIND`, except stickers and emoji are
/// both `manage_emojis` there too.
pub fn required_for(kind: u16) -> Option<Permission> {
    use crate::kinds::*;
    match kind {
        SERVER_METADATA => Some(Permission::ManageServer),
        SERVER_STRUCTURE => Some(Permission::ManageChannels),
        SERVER_ROLES => Some(Permission::ManageRoles),
        SERVER_MEMBER => Some(Permission::ManageRoles),
        SERVER_EMOJI | SERVER_STICKERS => Some(Permission::ManageEmojis),
        SERVER_BAN => Some(Permission::BanMembers),
        SERVER_INVITE => Some(Permission::CreateInvite),
        _ => None,
    }
}
