class MentionsController < ApplicationController
  before_action :authenticate_user!

  def search
    server = Server.find_by!(public_id: params[:server_id])
    query = params[:q].to_s.downcase

    results = []

    # Special mentions
    if "everyone".start_with?(query)
      results << { type: "special", name: "everyone", display: "@everyone", description: "Mention everyone" }
    end
    if "here".start_with?(query)
      results << { type: "special", name: "here", display: "@here", description: "Mention online users" }
    end

    # Users
    server.members.where("LOWER(username) LIKE ?", "%#{query}%").limit(8).each do |user|
      results << { type: "user", id: user.public_id, name: user.username, display: "@#{user.username}" }
    end

    # Roles
    server.roles.where("LOWER(name) LIKE ?", "%#{query}%").where.not(name: "@everyone").limit(5).each do |role|
      role_name = role.name.delete_prefix("@")
      results << { type: "role", id: role.public_id, name: role_name, display: "@#{role_name}", color: role.color }
    end

    render json: results
  end
end
