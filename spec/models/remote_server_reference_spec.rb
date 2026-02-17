require 'rails_helper'

RSpec.describe RemoteServerReference, type: :model do
  describe "validations" do
    subject { build(:remote_server_reference) }

    it { should validate_presence_of(:remote_instance_url) }
    it { should validate_presence_of(:remote_server_id) }
    it { should validate_uniqueness_of(:remote_server_id).scoped_to(:user_id, :remote_instance_url) }
    it { should belong_to(:user) }
  end

  describe ".ordered" do
    it "orders by position then created_at" do
      user = create(:user, :confirmed)
      ref_b = create(:remote_server_reference, user: user, position: 2)
      ref_a = create(:remote_server_reference, user: user, position: 1)
      ref_c = create(:remote_server_reference, user: user, position: 2,
                     created_at: ref_b.created_at + 1.second)

      expect(user.remote_server_references.ordered).to eq([ ref_a, ref_b, ref_c ])
    end
  end

  describe "#instance_domain" do
    it "extracts the host from remote_instance_url" do
      ref = build(:remote_server_reference, remote_instance_url: "https://cool.chat")
      expect(ref.instance_domain).to eq("cool.chat")
    end

    it "handles URLs with ports" do
      ref = build(:remote_server_reference, remote_instance_url: "https://cool.chat:3000")
      expect(ref.instance_domain).to eq("cool.chat")
    end

    it "returns raw string for invalid URIs" do
      ref = build(:remote_server_reference, remote_instance_url: "not a url")
      expect(ref.instance_domain).to eq("not a url")
    end
  end

  describe "#remote_server_url" do
    it "builds invite URL when invite_code is present" do
      ref = build(:remote_server_reference,
                  remote_instance_url: "https://cool.chat",
                  invite_code: "abc123")
      expect(ref.remote_server_url).to eq("https://cool.chat/invite/abc123")
    end

    it "returns nil when invite_code is blank" do
      ref = build(:remote_server_reference, invite_code: nil)
      expect(ref.remote_server_url).to be_nil
    end
  end
end
