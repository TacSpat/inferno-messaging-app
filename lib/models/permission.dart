import 'dart:convert';

enum Permission {
  sendMessages,
  readMessages,
  readMessageHistory,
  attachFiles,
  sendGifs,
  sendCustomEmojis,
  sendCustomStickers,
  addReactions,
  changeNickname,
  createInvite,
  createEmojis,
  createStickers,
  mentionEveryone,
  manageMessages,
  manageChannels,
  manageRoles,
  manageInvites,
  manageEmojis,
  manageServer,
  kickMembers,
  banMembers,
  administrator,
  connectVoice,
  speak,
  video,
  screenShare,
  muteMembers,
  deafenMembers,
  moveMembers,
  owner,
}

extension PermissionExtension on Permission {
  String get key {
    switch (this) {
      case Permission.sendMessages: return 'send_messages';
      case Permission.readMessages: return 'read_messages';
      case Permission.readMessageHistory: return 'read_message_history';
      case Permission.attachFiles: return 'attach_files';
      case Permission.sendGifs: return 'send_gifs';
      case Permission.sendCustomEmojis: return 'send_custom_emojis';
      case Permission.sendCustomStickers: return 'send_custom_stickers';
      case Permission.addReactions: return 'add_reactions';
      case Permission.changeNickname: return 'change_nickname';
      case Permission.createInvite: return 'create_invite';
      case Permission.createEmojis: return 'create_emojis';
      case Permission.createStickers: return 'create_stickers';
      case Permission.mentionEveryone: return 'mention_everyone';
      case Permission.manageMessages: return 'manage_messages';
      case Permission.manageChannels: return 'manage_channels';
      case Permission.manageRoles: return 'manage_roles';
      case Permission.manageInvites: return 'manage_invites';
      case Permission.manageEmojis: return 'manage_emojis';
      case Permission.manageServer: return 'manage_server';
      case Permission.kickMembers: return 'kick_members';
      case Permission.banMembers: return 'ban_members';
      case Permission.administrator: return 'administrator';
      case Permission.connectVoice: return 'connect_voice';
      case Permission.speak: return 'speak';
      case Permission.video: return 'video';
      case Permission.screenShare: return 'screen_share';
      case Permission.muteMembers: return 'mute_members';
      case Permission.deafenMembers: return 'deafen_members';
      case Permission.moveMembers: return 'move_members';
      case Permission.owner: return 'owner';
    }
  }

  String get label {
    switch (this) {
      case Permission.sendMessages: return 'Send Messages';
      case Permission.readMessages: return 'Read Messages';
      case Permission.readMessageHistory: return 'Read Message History';
      case Permission.attachFiles: return 'Attach Files';
      case Permission.sendGifs: return 'Send GIFs';
      case Permission.sendCustomEmojis: return 'Send Custom Emojis';
      case Permission.sendCustomStickers: return 'Send Custom Stickers';
      case Permission.addReactions: return 'Add Reactions';
      case Permission.changeNickname: return 'Change Nickname';
      case Permission.createInvite: return 'Create Invite';
      case Permission.createEmojis: return 'Create Emojis';
      case Permission.createStickers: return 'Create Stickers';
      case Permission.mentionEveryone: return 'Mention @everyone';
      case Permission.manageMessages: return 'Manage Messages';
      case Permission.manageChannels: return 'Manage Channels';
      case Permission.manageRoles: return 'Manage Roles';
      case Permission.manageInvites: return 'Manage Invites';
      case Permission.manageEmojis: return 'Manage Emojis';
      case Permission.manageServer: return 'Manage Server';
      case Permission.kickMembers: return 'Kick Members';
      case Permission.banMembers: return 'Ban Members';
      case Permission.administrator: return 'Administrator';
      case Permission.connectVoice: return 'Connect to Voice';
      case Permission.speak: return 'Speak';
      case Permission.video: return 'Video';
      case Permission.screenShare: return 'Screen Share';
      case Permission.muteMembers: return 'Mute Members';
      case Permission.deafenMembers: return 'Deafen Members';
      case Permission.moveMembers: return 'Move Members';
      case Permission.owner: return 'Owner';
    }
  }

  /// Category for UI grouping
  PermissionCategory get category {
    switch (this) {
      case Permission.sendMessages:
      case Permission.readMessages:
      case Permission.readMessageHistory:
      case Permission.attachFiles:
      case Permission.sendGifs:
      case Permission.sendCustomEmojis:
      case Permission.sendCustomStickers:
      case Permission.addReactions:
      case Permission.changeNickname:
      case Permission.createInvite:
      case Permission.createEmojis:
      case Permission.createStickers:
        return PermissionCategory.general;
      case Permission.mentionEveryone:
      case Permission.manageMessages:
      case Permission.manageChannels:
      case Permission.manageRoles:
      case Permission.manageInvites:
      case Permission.manageEmojis:
      case Permission.manageServer:
      case Permission.kickMembers:
      case Permission.banMembers:
      case Permission.administrator:
      case Permission.owner:
        return PermissionCategory.moderation;
      case Permission.connectVoice:
      case Permission.speak:
      case Permission.video:
      case Permission.screenShare:
      case Permission.muteMembers:
      case Permission.deafenMembers:
      case Permission.moveMembers:
        return PermissionCategory.voice;
    }
  }

  bool get defaultValue {
    switch (this) {
      case Permission.sendMessages:
      case Permission.readMessages:
      case Permission.readMessageHistory:
      case Permission.attachFiles:
      case Permission.sendGifs:
      case Permission.sendCustomEmojis:
      case Permission.sendCustomStickers:
      case Permission.addReactions:
      case Permission.changeNickname:
      case Permission.createInvite:
      case Permission.connectVoice:
      case Permission.speak:
      case Permission.video:
      case Permission.screenShare:
        return true;
      default:
        return false;
    }
  }
}

enum PermissionCategory { general, moderation, voice }

extension PermissionCategoryExtension on PermissionCategory {
  String get label {
    switch (this) {
      case PermissionCategory.general: return 'General';
      case PermissionCategory.moderation: return 'Moderation';
      case PermissionCategory.voice: return 'Voice';
    }
  }
}

class PermissionChecker {
  /// Check if a permissions JSON map grants a specific permission
  static bool hasPermission(String? permissionsJson, Permission permission) {
    if (permissionsJson == null) return permission.defaultValue;
    try {
      final perms = json.decode(permissionsJson) as Map<String, dynamic>;
      // Owner has everything
      if (perms['owner'] == true) return true;
      // Administrator has everything except owner-only
      if (perms['administrator'] == true && permission != Permission.owner) return true;
      return perms[permission.key] == true;
    } catch (_) {
      return permission.defaultValue;
    }
  }

  /// Check if any role in a list grants a permission
  static bool anyRoleHasPermission(List<String?> rolePermissions, Permission permission) {
    for (final perms in rolePermissions) {
      if (hasPermission(perms, permission)) return true;
    }
    return false;
  }

  /// Generate default permissions JSON
  static String defaultPermissionsJson() {
    final map = <String, bool>{};
    for (final p in Permission.values) {
      map[p.key] = p.defaultValue;
    }
    return json.encode(map);
  }

  /// Generate owner permissions JSON
  static String ownerPermissionsJson() {
    final map = <String, bool>{};
    for (final p in Permission.values) {
      map[p.key] = true;
    }
    return json.encode(map);
  }
}
