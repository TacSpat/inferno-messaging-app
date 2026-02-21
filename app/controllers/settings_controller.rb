class SettingsController < ApplicationController
  before_action :authenticate_user!
  layout "user_settings"

  def my_account
    @user = current_user
  end

  def profile
    @user = current_user
  end

  def update_profile
    @user = current_user
    if @user.update(profile_params)
      redirect_to user_settings_profile_path, notice: "Profile updated!"
    else
      render :profile, status: :unprocessable_entity
    end
  end

  def appearance
    @user = current_user
  end

  def update_appearance
    @user = current_user
    if @user.update(theme: params[:theme])
      redirect_to user_settings_appearance_path, notice: "Appearance updated!"
    else
      render :appearance, status: :unprocessable_entity
    end
  end

  def notifications
    @user = current_user
  end

  def keybinds
    @user = current_user
  end

  def change_password
    @user = current_user
  end

  def update_password
    @user = current_user

    unless @user.valid_password?(params[:current_password])
      flash.now[:alert] = "Current password is incorrect."
      render :change_password, status: :unprocessable_entity
      return
    end

    if params[:new_password].blank?
      flash.now[:alert] = "New password can't be blank."
      render :change_password, status: :unprocessable_entity
      return
    end

    if params[:new_password] != params[:new_password_confirmation]
      flash.now[:alert] = "New passwords don't match."
      render :change_password, status: :unprocessable_entity
      return
    end

    if @user.update(password: params[:new_password], password_confirmation: params[:new_password_confirmation])
      bypass_sign_in(@user)
      redirect_to user_settings_account_path, notice: "Password updated successfully."
    else
      flash.now[:alert] = @user.errors.full_messages.join(", ")
      render :change_password, status: :unprocessable_entity
    end
  end

  def reveal_nostr_key
    if current_user.valid_password?(params[:password])
      render json: { nsec: current_user.nsec }, layout: false
    else
      render json: { error: "Incorrect password" }, status: :unprocessable_entity, layout: false
    end
  end

  def export_encrypted_key
    unless current_user.valid_password?(params[:password])
      render json: { error: "Incorrect password" }, status: :unprocessable_entity, layout: false
      return
    end

    backup_password = params[:backup_password]
    if backup_password.blank? || backup_password.length < 8
      render json: { error: "Backup password must be at least 8 characters" }, status: :unprocessable_entity, layout: false
      return
    end

    ncryptsec = Nip49Service.encrypt(
      current_user.nostr_private_key,
      backup_password,
      log_n: 16,
      key_security: 0x02
    )

    render json: { ncryptsec: ncryptsec }, layout: false
  rescue => e
    render json: { error: "Encryption failed: #{e.message}" }, status: :internal_server_error, layout: false
  end

  private

  def profile_params
    params.require(:user).permit(:username, :display_name, :bio, :status, :status_emoji, :avatar, :banner, :profile_color, :profile_color_2, :banner_offset_y)
  end
end
