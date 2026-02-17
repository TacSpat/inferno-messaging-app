module Admin
  class LegalHoldsController < BaseController
    def index
      @active_holds = LegalHold.active.includes(:placed_by).order(placed_at: :desc)
      @recent_lifted = LegalHold.lifted.includes(:placed_by).order(lifted_at: :desc).limit(20)
    end

    def create
      holdable = find_holdable
      unless holdable
        redirect_to admin_legal_holds_path, alert: "Record not found."
        return
      end

      if LegalHold.held?(holdable)
        redirect_to admin_legal_holds_path, alert: "An active hold already exists for this record."
        return
      end

      hold = LegalHold.create!(
        holdable: holdable,
        placed_by: current_user,
        placed_at: Time.current,
        reason: params[:reason]
      )

      AuditService.log(
        event_type: "lockdown_activated",
        actor: current_user,
        target: holdable,
        ip_address: request.remote_ip,
        metadata: { legal_hold_id: hold.id, reason: params[:reason] }
      )

      redirect_to admin_legal_holds_path, notice: "Legal hold placed on #{holdable.class.name} ##{holdable.id}."
    end

    def destroy
      hold = LegalHold.find(params[:id])
      hold.lift!
      redirect_to admin_legal_holds_path, notice: "Legal hold lifted."
    end

    private

    def find_holdable
      case params[:holdable_type]
      when "User" then User.find_by(id: params[:holdable_id])
      when "Server" then Server.find_by(id: params[:holdable_id])
      when "Channel" then Channel.find_by(id: params[:holdable_id])
      end
    end
  end
end
