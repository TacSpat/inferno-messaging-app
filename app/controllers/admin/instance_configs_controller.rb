module Admin
  class InstanceConfigsController < BaseController
    def show
      @config = InstanceConfig.current
      @stats = {
        total_users: User.count,
        total_servers: Server.count,
        total_messages: Message.count,
        total_channels: Channel.count,
        storage_used_mb: active_storage_total_mb
      }
    end

    def update
      @config = InstanceConfig.current
      if @config.update(config_params)
        redirect_to admin_instance_config_path, notice: "Instance settings saved."
      else
        @stats = {
          total_users: User.count,
          total_servers: Server.count,
          total_messages: Message.count,
          total_channels: Channel.count,
          storage_used_mb: active_storage_total_mb
        }
        render :show, status: :unprocessable_entity
      end
    end

    def emergency_lockdown
      InstanceConfig.current.emergency_lockdown!
      redirect_to admin_instance_config_path, notice: "Emergency lockdown activated. All locks enabled."
    end

    def lift_lockdown
      InstanceConfig.current.lift_lockdown!
      redirect_to admin_instance_config_path, notice: "All lockdowns lifted."
    end

    private

    def config_params
      params.require(:instance_config).permit(
        :instance_name, :instance_description,
        :max_users, :max_servers, :max_servers_per_user,
        :max_channels_per_server, :max_categories_per_server,
        :max_members_per_server, :max_roles_per_server,
        :max_upload_size_mb, :max_storage_per_user_mb,
        :pruning_strategy, :message_retention_days,
        :attachment_retention_days, :keep_pinned_messages,
        :federation_mode, :lockdown_enabled, :instance_relay_url,
        :lockdown_remote_auth, :lockdown_remote_joins,
        :lockdown_local_signups, :lockdown_invite_creation
      )
    end

    def active_storage_total_mb
      bytes = ActiveStorage::Blob.sum(:byte_size)
      (bytes / 1.megabyte.to_f).round(1)
    end
  end
end
