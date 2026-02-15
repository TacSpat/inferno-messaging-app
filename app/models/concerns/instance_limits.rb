module InstanceLimits
  extend ActiveSupport::Concern

  private

  def instance_config
    InstanceConfig.current
  end
end
