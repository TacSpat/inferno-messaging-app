class LiftExpiredSuspensionsJob < ApplicationJob
  queue_as :default

  def perform
    UserSuspension.expired.find_each do |suspension|
      UserSuspensionService.lift!(suspension, lifted_by: nil, reason: "Automatic expiry")
    end
  end
end
