require "net/http"
require "uri"

class InviteUnfurlJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: 5.seconds, attempts: 3

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return unless message&.content.present?

    html = message.rendered_content_cached
    return if html.blank?

    local_domain = Rails.application.config.x.instance_domain
    changed = false

    # Handle HTTP-based invite URLs
    message.content.scan(Message::INFERNO_INVITE_REGEX).each do |gid, invite_code|
      # Find the full URL from content
      if gid.present?
        full_url_match = message.content.match(/https?:\/\/[^\s<>]+\/inferno\/invite\/(?:#{Regexp.escape(gid)}\/)?#{Regexp.escape(invite_code)}/i)
      end
      full_url_match ||= message.content.match(/https?:\/\/[^\s<>]+\/inferno\/invite\/#{Regexp.escape(invite_code)}/)
      next unless full_url_match
      full_url = full_url_match[0]

      parsed_url = URI.parse(full_url) rescue nil
      parsed_authority = if parsed_url && parsed_url.port && ![ 80, 443 ].include?(parsed_url.port)
        "#{parsed_url.host}:#{parsed_url.port}"
      else
        parsed_url&.host
      end
      is_local = parsed_url && (parsed_authority == local_domain)

      embed_html = resolve_invite_embed(message, invite_code, gid, is_local: is_local, full_url: full_url)
      next unless embed_html

      placeholder_pattern = /<div class="mt-2 invite-placeholder" data-invite-code="#{Regexp.escape(invite_code)}"[^>]*>.*?<\/div>/m
      if html.match?(placeholder_pattern)
        html = html.sub(placeholder_pattern, embed_html)
        changed = true
      end
    end

    # Handle nostr:naddr invite URIs
    message.content.scan(Message::NOSTR_INVITE_REGEX).each do |naddr_match|
      naddr_str = naddr_match.is_a?(Array) ? naddr_match[0] : naddr_match
      decoded = Invite.decode_naddr(naddr_str)
      next unless decoded

      invite_code = decoded[:code]
      gid = decoded[:nostr_group_id]

      embed_html = resolve_invite_embed(message, invite_code, gid, is_local: true)
      next unless embed_html

      placeholder_pattern = /<div class="mt-2 invite-placeholder" data-invite-code="#{Regexp.escape(invite_code)}"[^>]*>.*?<\/div>/m
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

  def resolve_invite_embed(message, invite_code, gid, is_local: false, full_url: nil)
    invite = Invite.find_by(code: invite_code)
    if invite.nil? && gid.present?
      server = Server.find_by(nostr_group_id: gid)
      invite = server.invites.find_by(code: invite_code) if server
    end

    if invite
      server = invite.server
      if invite.usable?
        message.send(:render_invite_embed_html, server, invite_code, gid || server.nostr_group_id, local: is_local)
      else
        reason = if invite.expired? then :expired
                 elsif !invite.active? then :revoked
                 elsif invite.maxed_out? then :maxed_out
                 else :expired end
        message.send(:render_expired_invite_embed_html, server.name, reason, gid || server.nostr_group_id, invite_code)
      end
    elsif gid.present?
      info = NostrServerSyncService.fetch_metadata_preview(gid)
      if info && info[:name].present?
        data = {
          "server_name" => info[:name],
          "icon_url" => info[:picture_url],
          "member_count" => info[:member_count] || 0,
          "online_count" => 0,
          "invite_code" => invite_code,
          "nostr_group_id" => gid
        }
        message.send(:render_remote_invite_embed_html, data, full_url || "/inferno/invite/#{gid}/#{invite_code}", gid)
      end
    elsif full_url && !is_local
      data = fetch_invite_json(full_url)
      return nil unless data
      message.send(:render_remote_invite_embed_html, data, full_url)
    end
  end

  def fetch_invite_json(url)
    json_url = url.chomp("/") + ".json"
    uri = URI.parse(json_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 3
    http.read_timeout = 5
    req = Net::HTTP::Get.new(uri)
    req["Accept"] = "application/json"
    response = http.request(req)
    return nil unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)
  rescue => e
    Rails.logger.warn("Invite JSON fetch failed: #{e.message}")
    nil
  end
end
