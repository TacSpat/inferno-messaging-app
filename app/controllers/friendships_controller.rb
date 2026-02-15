class FriendshipsController < ApplicationController
  before_action :authenticate_user!

  def index
    redirect_to conversations_path(tab: 'online')
  end

  def create
    tag = params[:tag].to_s.strip
    if tag.include?('#')
      username, discriminator = tag.split('#', 2)
      friend = User.find_by(username: username, discriminator: discriminator)
    else
      friend = User.find_by(public_id: params[:user_id])
    end

    if friend.nil?
      redirect_to conversations_path(tab: 'add_friend'), alert: 'User not found. Make sure the username and tag are correct.'
      return
    end

    if friend == current_user
      redirect_to conversations_path(tab: 'add_friend'), alert: "You can't add yourself."
      return
    end

    friendship = current_user.friendships.new(friend: friend, status: :pending)
    if friendship.save
      ActionCable.server.broadcast("user_notifications_#{friend.id}", {
        type: "friend_request",
        from_user: current_user.display_name.presence || current_user.username,
        from_user_id: current_user.public_id
      })
      redirect_to conversations_path(tab: 'pending'), notice: "Friend request sent to #{friend.tag}!"
    else
      redirect_to conversations_path(tab: 'add_friend'), alert: friendship.errors.full_messages.join(', ')
    end
  end

  def accept
    friendship = Friendship.find(params[:id])
    if friendship.friend == current_user
      friendship.accept!
      redirect_to conversations_path(tab: 'all'), notice: 'Friend request accepted!'
    else
      redirect_to conversations_path(tab: 'pending'), alert: 'Not authorized'
    end
  end

  def decline
    friendship = Friendship.find(params[:id])
    if friendship.friend == current_user
      friendship.update!(status: :declined)
      redirect_to conversations_path(tab: 'pending'), notice: 'Friend request declined.'
    else
      redirect_to conversations_path(tab: 'pending'), alert: 'Not authorized'
    end
  end

  def destroy
    friendship = current_user.friendships.find(params[:id])
    friend = friendship.friend
    Friendship.where(user_id: current_user.id, friend_id: friend.id).destroy_all
    Friendship.where(user_id: friend.id, friend_id: current_user.id).destroy_all
    redirect_to conversations_path(tab: 'all'), notice: "Removed #{friend.tag} from friends."
  end
end
