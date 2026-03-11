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

    # Local users
    server.members.where("LOWER(username) LIKE ?", "%#{query}%").limit(6).each do |user|
      results << { type: "user", id: user.public_id, name: user.username, display: "@#{user.username}" }
    end

    # Remote users
    server.remote_members
      .where("LOWER(username) LIKE ? OR LOWER(display_name) LIKE ?", "%#{query}%", "%#{query}%")
      .limit(4).each do |rm|
      name = rm.username.presence || rm.display_name.presence || rm.pubkey[0..11]
      results << { type: "user", id: rm.public_id, name: name, display: "@#{name}" }
    end

    # Roles (exclude @everyone and owner roles)
    server.roles
      .where("LOWER(name) LIKE ?", "%#{query}%")
      .where.not(name: "@everyone")
      .where("json_extract(permissions, '$.owner') IS NOT TRUE")
      .limit(5).each do |role|
      role_name = role.name.delete_prefix("@")
      results << { type: "role", id: role.public_id, name: role_name, display: "@#{role_name}", color: role.color }
    end

    render json: results
  end

  # Autocomplete for search filters (users + channels)
  def search_autocomplete
    server = Server.find_by!(public_id: params[:server_id])
    query = params[:q].to_s.downcase.strip
    filter_type = params[:type].to_s # "from" or "in"
    results = []

    if filter_type == "from"
      # Local members
      server.members
        .includes(avatar_attachment: :blob)
        .where("LOWER(username) LIKE ? OR LOWER(display_name) LIKE ?", "%#{query}%", "%#{query}%")
        .limit(6).each do |user|
        results << {
          type: "user",
          value: user.username,
          name: user.display_name.presence || user.username,
          subtitle: user.username,
          avatar: user.effective_avatar_url,
          color: user.profile_color
        }
      end
      # Remote members
      server.remote_members
        .where("LOWER(username) LIKE ? OR LOWER(display_name) LIKE ?", "%#{query}%", "%#{query}%")
        .limit(4).each do |rm|
        results << {
          type: "user",
          value: rm.pubkey,
          name: rm.display_name_for,
          subtitle: rm.username.presence || rm.pubkey[0..11] + "...",
          avatar: rm.effective_avatar_url,
          color: nil
        }
      end
    elsif filter_type == "in"
      server.channels.accessible_to(current_user)
        .where("LOWER(name) LIKE ?", "%#{query}%")
        .where(channel_type: [ :text ])
        .ordered.limit(8).each do |channel|
        results << {
          type: "channel",
          value: channel.name,
          name: channel.name,
          encrypted: channel.encrypted?
        }
      end
    end

    render json: results
  end
end
