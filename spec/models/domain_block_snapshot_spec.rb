require 'rails_helper'

RSpec.describe DomainBlockSnapshot, type: :model do
  describe "associations" do
    it { should belong_to(:instance_blocklist) }
  end

  describe "creation via InstanceBlocklist callback" do
    it "is created automatically when a domain is blocked" do
      expect {
        create(:instance_blocklist)
      }.to change(DomainBlockSnapshot, :count).by(1)
    end

    it "captures snapshot data" do
      blocklist = create(:instance_blocklist, domain: "evil.example.com")
      snapshot = blocklist.domain_block_snapshot

      expect(snapshot).to be_present
      expect(snapshot.snapshot_data["domain"]).to eq("evil.example.com")
      expect(snapshot.snapshot_data).to have_key("remote_user_count")
      expect(snapshot.snapshot_data).to have_key("server_membership_count")
      expect(snapshot.snapshot_data).to have_key("recent_audit_events")
    end
  end
end
