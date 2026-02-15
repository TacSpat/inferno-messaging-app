class Users::ConfirmationsController < Devise::ConfirmationsController
  def show
    self.resource = resource_class.confirm_by_token(params[:confirmation_token])

    if resource.errors.empty?
      sign_in(resource)
      # Auto-join server if they came from an invite
      if session[:pending_invite_code].present?
        invite = Invite.find_by(code: session.delete(:pending_invite_code))
        if invite&.usable?
          server = invite.server
          unless resource.servers.include?(server)
            invite.increment_uses!
            server.server_memberships.create!(user: resource)
          end
          redirect_to server_channel_path(server, server.channels.ordered.first), notice: "Welcome to #{server.name}!"
          return
        end
      end
      redirect_to authenticated_root_path, notice: "Email confirmed! Welcome to Inferno"
    else
      respond_with_navigational(resource.errors, status: :unprocessable_entity) { render :new }
    end
  end
end
