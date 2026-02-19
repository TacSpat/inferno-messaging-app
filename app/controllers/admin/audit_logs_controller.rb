module Admin
  class AuditLogsController < BaseController
    def index
      @federation_logs = FederationAuditLog.includes(:actor).recent(100)
      @federation_logs = @federation_logs.by_event(params[:event_type]) if params[:event_type].present?
      @federation_logs = @federation_logs.by_domain(params[:domain]) if params[:domain].present?

      if params[:date_from].present?
        from = Time.zone.parse(params[:date_from]).beginning_of_day
        to = params[:date_to].present? ? Time.zone.parse(params[:date_to]).end_of_day : Time.current
        @federation_logs = @federation_logs.in_range(from, to)
      end

      @model_versions = PaperTrail::Version
        .where(item_type: %w[InstanceConfig InstanceBlocklist ModerationReport LegalHold])
        .order(created_at: :desc)
        .limit(100)

      # Preload pubkey → user lookups to avoid N+1 in view
      pubkeys = @federation_logs.filter_map { |l| l.metadata&.dig("pubkey") }.uniq
      @pubkey_users = {}
      if pubkeys.any?
        User.where(nostr_public_key: pubkeys).each { |u| @pubkey_users[u.nostr_public_key] = u }
        remaining = pubkeys - @pubkey_users.keys
        if remaining.any?
          User.joins(:remote_user_detail).where(remote_users: { nostr_public_key: remaining }).each do |u|
            @pubkey_users[u.remote_user_detail.nostr_public_key] = u
          end
        end
      end

      # Preload whodunnit users for PaperTrail versions
      whodunnit_ids = @model_versions.filter_map(&:whodunnit).uniq
      @whodunnit_users = User.where(id: whodunnit_ids).index_by { |u| u.id.to_s }

      @event_types = FederationAuditLog::EVENT_TYPES
      @domains = FederationAuditLog.distinct.pluck(:remote_domain).compact.sort
    end
  end
end
