class NostrReportPublishJob < ApplicationJob
  queue_as :default

  # Publish a NIP-56 Kind 1984 reporting event to relays
  def perform(moderation_report_id)
    report = ModerationReport.find_by(id: moderation_report_id)
    return unless report

    # Use instance keypair for signing reports
    config = InstanceConfig.current
    instance_key = Rails.application.config.nostr[:instance_private_key]
    instance_pubkey = Rails.application.config.nostr[:instance_public_key]

    return if instance_key.blank?

    tags = [
      ["p", report.reported_pubkey, report.report_type]
    ]

    # If reporting a specific event, add the "e" tag
    if report.reported_event_id.present?
      tags << ["e", report.reported_event_id, report.report_type]
    end

    # NIP-56 report type tag
    tags << ["L", "MOD"]
    tags << ["l", report.report_type, "MOD"]

    event = Nostr::Event.new(
      kind: 1984,
      pubkey: instance_pubkey,
      content: report.reason.presence || "",
      tags: tags,
      created_at: Time.now.to_i
    )

    signer = Nostr::Signer.new(private_key: instance_key)
    signed_event = signer.sign(event)

    RelayService.publish_to_all(signed_event.to_json)

    Rails.logger.info("Published NIP-56 report event for pubkey #{report.reported_pubkey}")
  rescue => e
    Rails.logger.error("Failed to publish NIP-56 report: #{e.message}")
  end
end
