require 'rails_helper'

RSpec.describe "Blocks", type: :request do
  let(:user) { create(:user, :confirmed) }
  let(:other) { create(:user, :confirmed) }

  before do
    sign_in user
  end

  describe "POST /blocks" do
    context "with pubkey" do
      it "creates a blocked contact and enqueues NostrPublishJob" do
        post blocks_path, params: { pubkey: other.nostr_public_key }

        expect(response).to redirect_to(conversations_path(tab: "blocked"))
        contact = Contact.find_by(pubkey: other.nostr_public_key)
        expect(contact.friendship_status).to eq("blocked")
        expect(NostrPublishJob).to have_been_enqueued
      end
    end

    context "with user_id" do
      it "creates a Block record" do
        post blocks_path, params: { user_id: other.public_id }

        expect(response).to redirect_to(conversations_path(tab: "blocked"))
        expect(user.blocks.where(blocked: other)).to exist
      end
    end

    context "with contact_id" do
      let(:contact) { Contact.create!(pubkey: "abc123", friendship_status: :not_friend) }

      it "updates contact status to blocked" do
        post blocks_path, params: { contact_id: contact.id }

        expect(response).to redirect_to(conversations_path(tab: "blocked"))
        expect(contact.reload.friendship_status).to eq("blocked")
      end
    end

    context "with nothing" do
      it "redirects with alert" do
        post blocks_path, params: {}

        expect(response).to redirect_to(conversations_path(tab: "blocked"))
        expect(flash[:alert]).to eq("No user specified")
      end
    end
  end

  describe "DELETE /blocks/:id" do
    context "by block record id" do
      let!(:block_record) { user.blocks.create!(blocked: other) }

      it "destroys the block" do
        delete block_path(block_record)

        expect(response).to redirect_to(conversations_path(tab: "blocked"))
        expect(user.blocks.where(blocked: other)).not_to exist
      end
    end

    context "by pubkey" do
      before do
        Contact.create!(pubkey: other.nostr_public_key, friendship_status: :blocked)
        user.blocks.create!(blocked: other)
      end

      it "unblocks the contact" do
        delete block_path(0), params: { pubkey: other.nostr_public_key }

        expect(response).to redirect_to(conversations_path(tab: "blocked"))
        contact = Contact.find_by(pubkey: other.nostr_public_key)
        expect(contact.friendship_status).to eq("not_friend")
      end
    end
  end
end
