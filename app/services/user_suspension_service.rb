class UserSuspensionService
  def self.suspend!(user, suspended_by:, type:, reason:, reason_category: nil, expires_at: nil, auto_triggered: false)
    suspension = UserSuspension.create!(
      user: user,
      suspended_by: suspended_by,
      suspension_type: type,
      reason: reason,
      reason_category: reason_category,
      expires_at: expires_at,
      auto_triggered: auto_triggered
    )

    user.update!(suspended_at: Time.current)

    AuditService.log(
      event_type: "user_suspended",
      actor: suspended_by,
      target: user,
      metadata: { reason_category: reason_category, suspension_type: type }
    )

    suspension
  end

  def self.lift!(suspension, lifted_by:, reason: nil)
    suspension.lift!(lifted_by, reason: reason)

    AuditService.log(
      event_type: "user_suspension_lifted",
      actor: lifted_by,
      target: suspension.user,
      metadata: { lift_reason: reason }
    )
  end
end
