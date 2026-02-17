require 'rails_helper'

RSpec.describe "PaperTrail metadata via info_for_paper_trail", type: :request do
  it "records ip_address on PaperTrail versions when admin updates config" do
    sign_in_as_admin

    patch admin_instance_config_path, params: {
      instance_config: { federation_mode: "closed" }
    }

    version = PaperTrail::Version.where(item_type: "InstanceConfig").last
    expect(version).to be_present
    expect(version.ip_address).to be_present
  end

  it "records whodunnit on PaperTrail versions" do
    admin = sign_in_as_admin

    patch admin_instance_config_path, params: {
      instance_config: { lockdown_enabled: true }
    }

    version = PaperTrail::Version.where(item_type: "InstanceConfig").last
    expect(version.whodunnit).to eq(admin.id.to_s)
  end
end
