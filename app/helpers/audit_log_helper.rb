module AuditLogHelper
  KIND_LABELS = {
    31750 => [ "updated server settings", "bg-blue-600/20 text-blue-400", "edit" ],
    31751 => [ "updated channels", "bg-blue-600/20 text-blue-400", "edit" ],
    31752 => [ "updated roles", "bg-purple-600/20 text-purple-400", "edit" ],
    31753 => [ "updated a member", "bg-green-600/20 text-green-400", "user" ],
    31754 => [ "updated emojis", "bg-warning-dark/20 text-warning-light", "edit" ],
    31755 => [ "updated stickers", "bg-warning-dark/20 text-warning-light", "edit" ],
    31756 => [ "updated bans", "bg-red-600/20 text-red-400", "ban" ],
    31757 => [ "updated invites", "bg-cyan-600/20 text-cyan-400", "link" ]
  }.freeze

  ICONS = {
    "edit" => '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"/></svg>',
    "user" => '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"/></svg>',
    "ban" => '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728A9 9 0 015.636 5.636m12.728 12.728L5.636 5.636"/></svg>',
    "link" => '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"/></svg>'
  }.freeze

  def audit_event_display(event)
    label, color, icon_key = KIND_LABELS[event.kind] || [ "performed an action", "bg-gray-600/20 text-gray-400", "edit" ]
    [ label, color, raw(ICONS[icon_key]) ]
  end

  def audit_event_actor(event)
    User.find_by(nostr_public_key: event.pubkey) ||
      RemoteMember.find_by(pubkey: event.pubkey, server: event.server)
  end
end
