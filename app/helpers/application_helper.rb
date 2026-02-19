module ApplicationHelper
  def profile_gradient_style(user, direction: "to bottom")
    c1 = user.profile_color.presence || "#1e1c1b"
    c2 = user.profile_color_2.presence || c1
    if c1 == c2
      "background-color: #{c1};"
    else
      "background: linear-gradient(#{direction}, #{c1}, #{c2});"
    end
  end

  def profile_card_bg_style(user)
    profile_gradient_style(user, direction: "135deg")
  end

  def render_name_with_emojis(name, server = nil)
    return h(name) unless name.present? && server && name.include?(":")

    emojis = server.server_emojis.includes(image_attachment: :blob).index_by(&:name)
    escaped = h(name)
    result = escaped.gsub(/:([a-z0-9_]+):/) do |match|
      emoji = emojis[$1]
      if emoji
        image_tag(url_for(emoji.image), alt: match, style: "height:1.2em;width:1.2em;object-fit:contain;vertical-align:middle;display:inline", loading: "lazy")
      else
        match
      end
    end
    result.html_safe
  end

  def render_reaction_emoji(emoji_string, message)
    if emoji_string.match?(/\A:[a-z0-9_]+:\z/)
      name = emoji_string[1..-2]
      server_emoji = find_server_emoji(name, message)
      if server_emoji
        image_tag url_for(server_emoji.image), alt: emoji_string, style: "height:1.25em;width:1.25em;object-fit:contain;vertical-align:middle;display:inline", loading: "lazy"
      else
        emoji_string
      end
    else
      emoji_string
    end
  end

  private

  def find_server_emoji(name, message)
    if message.channel&.server
      message.channel.server.server_emojis.includes(image_attachment: :blob).find_by(name: name)
    elsif message.user
      ServerEmoji.where(server_id: message.user.servers.select(:id), name: name).includes(image_attachment: :blob).first
    end
  end
end
