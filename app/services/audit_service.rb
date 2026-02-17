class AuditService
  def self.log(event_type:, actor: nil, target: nil, remote_domain: nil, ip_address: nil, metadata: {})
    FederationAuditLog.create!(
      event_type: event_type,
      actor: actor,
      target: target,
      remote_domain: remote_domain,
      ip_address: ip_address,
      metadata: metadata
    )
  rescue StandardError => e
    if Rails.env.local?
      raise
    else
      Rails.logger.error("[AuditService] Failed to log #{event_type}: #{e.message}")
    end
  end
end
