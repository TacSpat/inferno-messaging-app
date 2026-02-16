require 'rails_helper'

RSpec.describe User, "federation methods", type: :model do
  describe "#home_instance_domain" do
    it "returns nil for local users" do
      user = create(:user, :confirmed)
      expect(user.home_instance_domain).to be_nil
    end

    it "returns the home instance for remote users" do
      remote_detail = create(:remote_user, home_instance: "other.chat")
      user = create(:user, :confirmed, remote: true, remote_user_detail: remote_detail)
      expect(user.home_instance_domain).to eq("other.chat")
    end

    it "returns nil if remote user has no detail record" do
      user = build(:user, remote: true, remote_user_detail: nil)
      expect(user.home_instance_domain).to be_nil
    end
  end

  describe "remote_server_references association" do
    it "has many remote_server_references" do
      user = create(:user, :confirmed)
      ref = create(:remote_server_reference, user: user)
      expect(user.remote_server_references).to include(ref)
    end

    it "destroys references when user is destroyed" do
      user = create(:user, :confirmed)
      create(:remote_server_reference, user: user)
      expect { user.destroy }.to change(RemoteServerReference, :count).by(-1)
    end
  end
end
