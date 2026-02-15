class HomeController < ApplicationController
  def index
    if user_signed_in?
      first_server = current_user.servers.first
      if first_server
        channel = first_server.channels.ordered.first
        redirect_to server_channel_path(first_server, channel)
      else
        render :index
      end
    end
  end

  def check_email
    # If already confirmed and signed in, no reason to be here
    if user_signed_in?
      redirect_to authenticated_root_path
      return
    end
    # Prevent direct navigation with no context
    redirect_to root_path unless session["warden.user.user.key"] || flash[:notice] || request.referer&.include?("users")
  end
end
