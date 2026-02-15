class SettingsController < ApplicationController
  before_action :authenticate_user!
  layout false

  SECTIONS = %w[my-account profile appearance notifications keybinds].freeze

  def show
    section = params[:section]
    unless SECTIONS.include?(section)
      head :not_found
      return
    end

    @user = current_user
    render section.underscore.tr('-', '_'), layout: false
  end

  def update_profile
    @user = current_user
    if @user.update(profile_params)
      render "profile", layout: false
    else
      render "profile", layout: false, status: :unprocessable_entity
    end
  end

  private

  def profile_params
    params.require(:user).permit(:username, :display_name, :bio, :status, :status_emoji, :avatar, :banner, :profile_color, :profile_color_2, :banner_offset_y)
  end
end
