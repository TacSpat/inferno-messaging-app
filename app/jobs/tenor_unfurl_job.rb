require "net/http"
require "uri"

class TenorUnfurlJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: 5.seconds, attempts: 3

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return unless message&.content.present?

    html = message.rendered_content_cached
    return if html.blank?

    changed = false

    message.content.scan(Message::TENOR_REGEX).each do |slug, gif_id|
      tenor_url = "https://tenor.com/view/#{slug}-#{gif_id}"
      gif_src = fetch_tenor_og_image(tenor_url)
      next unless gif_src

      # Replace the placeholder with the actual GIF embed
      placeholder_pattern = /<div class="mt-2 tenor-placeholder" data-tenor-id="#{gif_id}">.*?<\/div>/m
      replacement = %(<div class="mt-2 inline-block"><img src="#{gif_src}" alt="GIF" class="max-w-sm max-h-72 rounded-lg cursor-pointer" loading="lazy" data-preview-src="#{gif_src}" data-preview-filename="tenor-#{gif_id}.gif"></div>)

      if html.match?(placeholder_pattern)
        html = html.sub(placeholder_pattern, replacement)
        changed = true
      end
    end

    return unless changed

    message.update_column(:rendered_content_cached, html)

    # Broadcast just the updated content HTML to avoid needing Devise context
    if message.channel
      ChannelChatChannel.broadcast_to(
        message.channel,
        {
          type: "update_message_content",
          message_id: message.id,
          html: html
        }
      )
    elsif message.conversation
      ConversationChannel.broadcast_to(
        message.conversation,
        {
          type: "update_message_content",
          message_id: message.public_id,
          html: html
        }
      )
    end
  end

  private

  def fetch_tenor_og_image(tenor_url)
    fetch_uri = URI.parse(tenor_url)
    3.times do
      http = Net::HTTP.new(fetch_uri.host, fetch_uri.port)
      http.use_ssl = true
      http.open_timeout = 3
      http.read_timeout = 5
      req = Net::HTTP::Get.new(fetch_uri)
      req["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
      response = http.request(req)
      if response.is_a?(Net::HTTPRedirection)
        fetch_uri = URI.parse(response["location"])
        next
      end
      if response.body&.match(/property="og:image"\s+content="([^"]+)"/)
        return $1
      end
      break
    end
    nil
  rescue => e
    Rails.logger.warn("Tenor fetch failed: #{e.message}")
    nil
  end
end
