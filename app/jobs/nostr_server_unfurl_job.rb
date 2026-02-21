class NostrServerUnfurlJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: 5.seconds, attempts: 3

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return unless message&.content.present?

    html = message.rendered_content_cached
    return if html.blank?

    changed = false

    message.content.scan(Message::NOSTR_SERVER_REGEX).each do |gid_match|
      nostr_group_id = gid_match.is_a?(Array) ? gid_match[0] : gid_match
      next if nostr_group_id.blank?

      # Try local DB first
      server = Server.find_by(nostr_group_id: nostr_group_id)

      embed_html = if server
        render_local_server_embed(server, nostr_group_id)
      else
        info = NostrServerSyncService.fetch_metadata_preview(nostr_group_id)
        next unless info && info[:name].present?
        render_nostr_server_embed(info, nostr_group_id)
      end

      placeholder_pattern = /<div class="mt-2 nostr-server-placeholder" data-nostr-gid="#{Regexp.escape(nostr_group_id)}"[^>]*>.*?<\/div>/m
      if html.match?(placeholder_pattern)
        html = html.sub(placeholder_pattern, embed_html)
        changed = true
      end
    end

    return unless changed

    message.update_column(:rendered_content_cached, html)

    if message.channel
      ChannelChatChannel.broadcast_to(
        message.channel,
        {
          type: "update_message_content",
          message_id: message.id,
          html: html
        }
      )
    end
  end

  private

  def render_local_server_embed(server, nostr_group_id)
    icon_html = if server.icon.attached?
      icon_url = Rails.application.routes.url_helpers.rails_blob_path(server.icon, only_path: true)
      %(<img src="#{icon_url}" class="w-12 h-12 rounded-xl object-cover shrink-0" />)
    else
      %(<div class="w-12 h-12 rounded-xl bg-gray-700 flex items-center justify-center text-lg font-bold text-white shrink-0">#{ERB::Util.html_escape(server.name[0].upcase)}</div>)
    end

    member_count = server.members.count
    online_count = server.members.where(online_state: :online).count
    instance_domain = Rails.application.config.x.instance_domain

    first_channel = server.channels.ordered.first
    link_url = first_channel ? "/servers/#{server.public_id}/channels/#{first_channel.public_id}" : "/inferno/server/#{nostr_group_id}"

    %(<a href="#{link_url}" data-turbo="false" class="mt-2 flex items-center gap-3 max-w-sm rounded-lg border border-gray-700 bg-gray-800/60 hover:bg-gray-700/60 transition-colors no-underline px-3 py-2.5 group" data-nostr-server-embed="true">#{icon_html}<div class="min-w-0"><div class="text-white font-semibold text-sm group-hover:underline truncate">#{ERB::Util.html_escape(server.name)}</div><div class="flex items-center gap-3 text-xs text-gray-400"><span class="flex items-center gap-1"><span class="w-1.5 h-1.5 rounded-full bg-green-500"></span>#{online_count} Online</span><span class="flex items-center gap-1"><span class="w-1.5 h-1.5 rounded-full bg-gray-500"></span>#{member_count} Members</span></div><div class="text-xs text-gray-500 mt-0.5">Inferno · #{ERB::Util.html_escape(instance_domain)}</div></div></a>)
  end

  def render_nostr_server_embed(info, nostr_group_id)
    icon_html = if info[:picture_url].present?
      %(<img src="#{ERB::Util.html_escape(info[:picture_url])}" class="w-12 h-12 rounded-xl object-cover shrink-0" />)
    else
      initial = (info[:name] || "?")[0].upcase
      %(<div class="w-12 h-12 rounded-xl bg-gray-700 flex items-center justify-center text-lg font-bold text-white shrink-0">#{ERB::Util.html_escape(initial)}</div>)
    end

    name = ERB::Util.html_escape(info[:name] || "Unknown Server")
    members = info[:member_count] || 0
    instance_domain = Rails.application.config.x.instance_domain
    link_url = "/inferno/server/#{ERB::Util.html_escape(nostr_group_id)}"

    %(<a href="#{link_url}" data-turbo="false" class="mt-2 flex items-center gap-3 max-w-sm rounded-lg border border-gray-700 bg-gray-800/60 hover:bg-gray-700/60 transition-colors no-underline px-3 py-2.5 group" data-nostr-server-embed="true">#{icon_html}<div class="min-w-0"><div class="text-white font-semibold text-sm group-hover:underline truncate">#{name}</div><div class="flex items-center gap-3 text-xs text-gray-400"><span class="flex items-center gap-1"><span class="w-1.5 h-1.5 rounded-full bg-gray-500"></span>#{members} Members</span></div><div class="text-xs text-gray-500 mt-0.5">Inferno · #{ERB::Util.html_escape(instance_domain)}</div></div></a>)
  end
end
