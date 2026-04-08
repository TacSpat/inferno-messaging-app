class ReactionsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_channel
  before_action :set_message

  def toggle
    emoji = params[:emoji]
    return head :bad_request unless emoji.present?

    existing = @message.reactions.find_by(user: current_user, emoji: emoji)

    removing = existing.present?
    if removing
      existing.destroy
    else
      @message.reactions.create!(user: current_user, emoji: emoji)
    end

    html = render_to_string(partial: "messages/reactions", locals: { message: @message.reload, reaction_controller: "message-form", current_user: current_user })
    ChannelChatChannel.broadcast_to(
      @channel,
      { type: "update_reactions", message_id: @message.public_id, html: html }
    )

    # Publish Kind 7 reaction to Nostr relays
    publish_reaction_to_nostr(emoji, removing)

    head :ok
  end

  def list
    reactions = @message.reactions.includes(:user).order(:emoji)
    grouped = reactions.group_by(&:emoji).map do |emoji, rs|
      { emoji: emoji, users: rs.map { |r| r.user.display_name_for(nil) } }
    end
    render json: grouped
  end

  private

  def set_channel
    @channel = Channel.find_by!(public_id: params[:channel_id])
  end

  def set_message
    @message = @channel.messages.find_by!(public_id: params[:id])
  end

  def publish_reaction_to_nostr(emoji, removing)
    return unless current_user.nostr_public_key.present?
    return unless @message.nostr_event_id.present?
    return unless @channel.nostr_group_id.present?

    author_pubkey = @message.nostr_author_pubkey || @message.user&.nostr_public_key || ""

    signer = Nostr::Signer.new(private_key: current_user.nostr_private_key)
    event = Nostr::Event.new(
      kind: 7,
      pubkey: current_user.nostr_public_key,
      content: removing ? "-" : emoji,
      tags: [
        [ "e", @message.nostr_event_id ],
        [ "p", author_pubkey ],
        [ "k", "9" ],
        [ "h", @channel.nostr_group_id ]
      ]
    )
    signed = signer.sign(event)
    RelayService.publish_to_all(signed.to_json)

    NostrEventLog.create!(
      event_id: signed.id,
      kind: 7,
      pubkey: current_user.nostr_public_key,
      direction: "outbound",
      event_created_at: Time.at(signed[:created_at] || signed["created_at"] || Time.current.to_i)
    )
  rescue ActiveRecord::RecordNotUnique
    # Already logged
  rescue => e
    Rails.logger.warn("[ReactionsController] Failed to publish reaction to Nostr: #{e.message}")
  end
end
