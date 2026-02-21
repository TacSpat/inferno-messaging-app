class ChannelChatChannel < ApplicationCable::Channel
  include Rails.application.routes.url_helpers

  def subscribed
    @channel = Channel.find_by!(public_id: params[:channel_id])
    stream_for @channel
  end

  def unsubscribed
    # Cleanup
  end

  def typing(data)
    avatar_info = typing_avatar_info(current_user)

    ChannelChatChannel.broadcast_to(
      @channel,
      {
        type: "typing",
        user_id: current_user.public_id,
        username: current_user.display_name.presence || current_user.username
      }.merge(avatar_info)
    )

    # Broadcast to server members for sidebar indicator
    sidebar_payload = {
      type: "channel_typing",
      channel_id: @channel.public_id,
      username: current_user.display_name.presence || current_user.username,
      user_id: current_user.public_id
    }.merge(avatar_info)

    @channel.server.members.where.not(id: current_user.id).find_each do |member|
      ActionCable.server.broadcast("user_notifications_#{member.id}", sidebar_payload)
    end

    # Publish ephemeral Kind 25050 typing indicator to Nostr relays
    publish_typing_to_nostr(avatar_info)
  end

  private

  def typing_avatar_info(user)
    if user.avatar.attached?
      { avatar_url: rails_blob_path(user.avatar, only_path: true) }
    else
      { avatar_initial: user.username[0].upcase, avatar_color: user.profile_color.presence || "#1e1c1b" }
    end
  end

  def publish_typing_to_nostr(avatar_info)
    return unless current_user.nostr_public_key.present?
    return unless @channel.nostr_group_id.present?

    content = {
      username: current_user.display_name.presence || current_user.username,
      avatar_url: avatar_info[:avatar_url] || "",
      avatar_initial: avatar_info[:avatar_initial] || current_user.username[0].upcase,
      avatar_color: avatar_info[:avatar_color] || "#1e1c1b"
    }.to_json

    signer = Nostr::Signer.new(private_key: current_user.nostr_private_key)
    event = Nostr::Event.new(
      kind: 25050,
      pubkey: current_user.nostr_public_key,
      content: content,
      tags: [
        ["h", @channel.nostr_group_id],
        ["p", current_user.nostr_public_key]
      ]
    )
    signed = signer.sign(event)
    RelayService.publish_to_all(signed.to_json)
  rescue => e
    Rails.logger.warn("[ChannelChatChannel] Failed to publish typing to Nostr: #{e.message}")
  end
end
