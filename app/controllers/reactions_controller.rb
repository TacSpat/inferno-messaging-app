class ReactionsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_channel
  before_action :set_message

  def toggle
    emoji = params[:emoji]
    return head :bad_request unless emoji.present?

    existing = @message.reactions.find_by(user: current_user, emoji: emoji)

    if existing
      existing.destroy
    else
      @message.reactions.create!(user: current_user, emoji: emoji)
    end

    html = render_to_string(partial: "messages/reactions", locals: { message: @message.reload, reaction_controller: "message-form" })
    ChannelChatChannel.broadcast_to(
      @channel,
      { type: "update_reactions", message_id: @message.public_id, html: html }
    )

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
end
