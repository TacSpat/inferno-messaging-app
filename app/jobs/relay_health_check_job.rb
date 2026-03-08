class RelayHealthCheckJob < ApplicationJob
  queue_as :default

  def perform
    RelayConnection.where(status: %w[active error]).find_each do |relay|
      check_relay(relay)
    end

    # Re-enqueue for next check cycle
    self.class.set(wait: 5.minutes).perform_later
  end

  private

  def check_relay(relay)
    events = RelayService.fetch_from_relay(relay.url, { kinds: [0], limit: 1 }, timeout: 8)
    relay.mark_connected!
  rescue => e
    new_retry_count = (relay.retry_count || 0) + 1

    attrs = {
      last_error_at: Time.current,
      last_error_message: e.message.to_s.truncate(200)
    }
    attrs[:retry_count] = new_retry_count

    # After 3 consecutive failures, mark as error
    if new_retry_count >= 3 && relay.active?
      attrs[:status] = "error"
    end

    relay.update!(attrs)

    # After 6+ hours continuous failure (retry_count >= 6), auto-disable
    if new_retry_count >= 6 && relay.last_connected_at.present? && relay.last_connected_at < 6.hours.ago
      relay.update!(status: "disabled", last_error_message: "Auto-disabled — unreachable for 6+ hours")
      Rails.logger.warn("[RelayHealthCheck] Auto-disabled relay #{relay.url} — unreachable for 6+ hours")
    end
  end
end
