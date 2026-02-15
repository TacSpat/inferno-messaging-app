module Admin
  class RelayConnectionsController < BaseController
    def create
      relay = RelayConnection.new(
        url: params[:url]&.strip,
        status: "active"
      )

      if relay.save
        redirect_to admin_instance_config_path, notice: "Relay #{relay.url} added."
      else
        redirect_to admin_instance_config_path, alert: relay.errors.full_messages.join(", ")
      end
    end

    def destroy
      relay = RelayConnection.find(params[:id])
      url = relay.url
      relay.destroy
      redirect_to admin_instance_config_path, notice: "Relay #{url} removed."
    end

    def toggle
      relay = RelayConnection.find(params[:id])
      if relay.active?
        relay.disable!
        redirect_to admin_instance_config_path, notice: "Relay #{relay.url} disabled."
      else
        relay.enable!
        redirect_to admin_instance_config_path, notice: "Relay #{relay.url} enabled."
      end
    end
  end
end
