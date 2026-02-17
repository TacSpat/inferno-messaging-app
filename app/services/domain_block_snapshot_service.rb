class DomainBlockSnapshotService
  def self.call(blocklist_entry)
    domain = blocklist_entry.domain

    snapshot_data = {
      domain: domain,
      blocked_at: blocklist_entry.blocked_at&.iso8601,
      remote_user_count: RemoteUser.where(home_instance: domain).count,
      server_membership_count: ServerMembership
        .joins("INNER JOIN users ON users.id = server_memberships.user_id")
        .joins("INNER JOIN remote_users ON remote_users.id = users.remote_user_detail_id")
        .where(remote_users: { home_instance: domain })
        .count,
      recent_audit_events: FederationAuditLog
        .by_domain(domain)
        .recent(20)
        .pluck(:event_type, :created_at)
        .map { |type, at| { event_type: type, created_at: at.iso8601 } }
    }

    DomainBlockSnapshot.create!(
      instance_blocklist: blocklist_entry,
      snapshot_data: snapshot_data
    )
  end
end
