module Admin
  class InstanceBlocklistsController < BaseController
    def create
      entry = InstanceBlocklist.new(
        domain: params[:domain],
        reason: params[:reason],
        blocked_by: current_user,
        blocked_at: Time.current
      )

      if entry.save
        redirect_to admin_instance_config_path, notice: "#{entry.domain} has been blocked."
      else
        redirect_to admin_instance_config_path, alert: entry.errors.full_messages.join(", ")
      end
    end

    def destroy
      entry = InstanceBlocklist.find(params[:id])
      domain = entry.domain
      entry.destroy
      redirect_to admin_instance_config_path, notice: "#{domain} has been unblocked."
    end
  end
end
