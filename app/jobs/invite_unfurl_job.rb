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

    message.content.scan(Message::INFERNO_INVITE_REGEX).each do |code_match|
      invite_code = code_match.is_a?(Array) ? code_match[0] : code_match

      # Find the full URL from content
      full_url_match = message.content.match(/https?:\/\/[^\s<>]+\/inferno\/invite\/#{Regexp.escape(invite_code)}/)
      next unless full_url_match
      full_url = full_url_match[0]

      parsed_url = URI.parse(full_url) rescue nil
      is_local = parsed_url && (parsed_url.host == local_domain)

      embed_html = if is_local
        invite = Invite.find_by(code: invite_code)
        next unless invite&.usable?
        message.send(:render_invite_embed_html, invite.server, invite_code, local_domain, local: true)
      else
        data = fetch_invite_json(full_url)
        next unless data
        message.send(:render_remote_invite_embed_html, data, full_url)
      end

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
