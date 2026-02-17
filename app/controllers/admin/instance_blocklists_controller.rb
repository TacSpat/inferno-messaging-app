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
        AuditService.log(
          event_type: "domain_block",
          actor: current_user,
          target: entry,
          remote_domain: entry.domain,
          ip_address: request.remote_ip,
          metadata: { reason: entry.reason }
        )
        redirect_to admin_instance_config_path, notice: "#{entry.domain} has been blocked."
      else
        redirect_to admin_instance_config_path, alert: entry.errors.full_messages.join(", ")
      end
    end

    def destroy
      entry = InstanceBlocklist.find(params[:id])
      domain = entry.domain
      AuditService.log(
        event_type: "domain_unblock",
        actor: current_user,
        remote_domain: domain,
        ip_address: request.remote_ip
      )
      entry.destroy
      redirect_to admin_instance_config_path, notice: "#{domain} has been unblocked."
    end
  end
end
