module Admin
  class UserSuspensionsController < BaseController
    def index
      @active_suspensions = UserSuspension.active.includes(:user, :suspended_by).order(created_at: :desc)
      @recent_lifted = UserSuspension.lifted.includes(:user, :suspended_by, :lifted_by).order(lifted_at: :desc).limit(20)
    end

    def create
      user = User.find_by(id: params[:user_id])
      unless user
        redirect_to admin_user_suspensions_path, alert: "User not found."
        return
      end

      if user.suspended?
        redirect_to admin_user_suspensions_path, alert: "User is already suspended."
        return
      end

      expires_at = params[:expires_at].present? ? Time.zone.parse(params[:expires_at]) : nil

      UserSuspensionService.suspend!(
        user,
        suspended_by: current_user,
        type: params[:suspension_type],
        reason: params[:reason],
        reason_category: params[:reason_category].presence,
        expires_at: expires_at
      )

      redirect_to admin_user_suspensions_path, notice: "User #{user.username} has been suspended."
    end

    def destroy
      suspension = UserSuspension.find(params[:id])

      UserSuspensionService.lift!(suspension, lifted_by: current_user, reason: params[:lift_reason])

      redirect_to admin_user_suspensions_path, notice: "Suspension lifted for #{suspension.user.username}."
    end
  end
end
