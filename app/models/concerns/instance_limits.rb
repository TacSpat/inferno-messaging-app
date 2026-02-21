module InstanceLimits
  extend ActiveSupport::Concern

  private

  def instance_config
    LocalConfig.current
  end
end
