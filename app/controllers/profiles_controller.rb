class ProfilesController < ApplicationController
  before_action :authenticate_user!

  def show
    @user = current_user
  end

  def edit
    @user = current_user
  end

  def update
    @user = current_user
    if @user.update(profile_params)
      if profile_params[:avatar].present? || profile_params[:banner].present?
        @user.broadcast_profile_update
        if @user.nostr_public_key.present?
          NostrPublishJob.perform_later(@user.id, :profile)
          @user.publish_member_events
        end
      end
      redirect_to profile_path, notice: "Profile updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def profile_params
    params.require(:user).permit(:username, :display_name, :bio, :status, :status_emoji, :avatar, :banner)
  end
end
