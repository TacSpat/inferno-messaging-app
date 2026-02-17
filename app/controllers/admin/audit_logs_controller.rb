module Admin
  class AuditLogsController < BaseController
    def index
      @federation_logs = FederationAuditLog.recent(100)
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

      @event_types = FederationAuditLog::EVENT_TYPES
      @domains = FederationAuditLog.distinct.pluck(:remote_domain).compact.sort
    end
  end
end
