class NotificationChannel < ApplicationCable::Channel
  def subscribed
    stream_from "user_notifications_#{current_user.id}"
  end
end
