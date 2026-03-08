class BlocksController < ApplicationController
  before_action :authenticate_user!

  # POST /blocks — block a user by pubkey or user_id
  def create
    if params[:pubkey].present?
      pubkey = params[:pubkey]
      contact = Contact.find_or_initialize_by(pubkey: pubkey)
      contact.update!(friendship_status: :blocked)

      # Also create a Block record if a local User exists with this pubkey
      local_user = User.find_by(nostr_public_key: pubkey)
      if local_user && !current_user.blocked?(local_user)
        current_user.blocks.create!(blocked: local_user)
      else
        # No local user — publish mute list directly
        NostrPublishJob.perform_later(current_user.id, :mute_list)
      end
    elsif params[:user_id].present?
      user = User.find_by!(public_id: params[:user_id])
      current_user.blocks.find_or_create_by!(blocked: user)
      # Block model's after_create handles Contact + mute list
    elsif params[:contact_id].present?
      contact = Contact.find(params[:contact_id])
      contact.update!(friendship_status: :blocked)
      NostrPublishJob.perform_later(current_user.id, :mute_list)
    else
      redirect_to conversations_path(tab: "blocked"), alert: "No user specified"
      return
    end

    respond_to do |format|
      format.html { redirect_to conversations_path(tab: "blocked"), notice: "User blocked." }
      format.json { render json: { status: "blocked" } }
    end
  end

  # DELETE /blocks/:id — unblock by Block record ID or contact pubkey
  def destroy
    if params[:pubkey].present?
      # Unblock by pubkey
      contact = Contact.find_by(pubkey: params[:pubkey])
      contact&.update!(friendship_status: :not_friend)

      local_user = User.find_by(nostr_public_key: params[:pubkey])
      current_user.blocks.find_by(blocked: local_user)&.destroy if local_user

      NostrPublishJob.perform_later(current_user.id, :mute_list)
    else
      # Unblock by Block record ID
      block = current_user.blocks.find_by(id: params[:id])
      if block
        block.destroy
        # Block model's after_destroy handles Contact + mute list
      else
        # Try treating id as a Contact id
        contact = Contact.find_by(id: params[:id], friendship_status: :blocked)
        if contact
          contact.update!(friendship_status: :not_friend)
          NostrPublishJob.perform_later(current_user.id, :mute_list)
        end
      end
    end

    respond_to do |format|
      format.html { redirect_to conversations_path(tab: "blocked"), notice: "User unblocked." }
      format.json { render json: { status: "unblocked" } }
    end
  end
end
