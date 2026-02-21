class FriendshipsController < ApplicationController
  before_action :authenticate_user!

  def index
    redirect_to conversations_path(tab: "online")
  end

  # Add a contact by npub or hex pubkey
  def create
    input = params[:tag].to_s.strip

    # Parse npub or hex pubkey
    pubkey = parse_pubkey(input)
    if pubkey.nil?
      respond_to do |format|
        format.html { redirect_to conversations_path(tab: "search"), alert: "Enter a valid npub or hex public key." }
        format.json { render json: { error: "Invalid pubkey" }, status: :unprocessable_entity }
      end
      return
    end

    # Can't add yourself
    if pubkey == current_user.nostr_public_key
      respond_to do |format|
        format.html { redirect_to conversations_path(tab: "search"), alert: "You can't add yourself." }
        format.json { render json: { error: "Can't add yourself" }, status: :unprocessable_entity }
      end
      return
    end

    # Check existing contact
    existing = Contact.find_by(pubkey: pubkey)
    if existing && !existing.not_friend?
      respond_to do |format|
        format.html { redirect_to conversations_path(tab: "search"), alert: "You already have a #{existing.friendship_status} contact for this pubkey." }
        format.json { render json: { error: "Already a contact", status: existing.friendship_status }, status: :unprocessable_entity }
      end
      return
    end

    # Resolve profile from relays
    contact = NostrProfileResolver.resolve(pubkey)
    contact.friendship_status = :pending_outgoing
    contact.save!

    # Send friend request as NIP-44 encrypted DM
    send_friend_request_dm(pubkey)

    respond_to do |format|
      format.html { redirect_to conversations_path(tab: "pending"), notice: "Friend request sent to #{contact.effective_display_name}!" }
      format.json { render json: { status: "sent", name: contact.effective_display_name } }
    end
  rescue => e
    Rails.logger.error("FriendshipsController#create error: #{e.message}")
    respond_to do |format|
      format.html { redirect_to conversations_path(tab: "search"), alert: "Failed to send friend request: #{e.message}" }
      format.json { render json: { error: e.message }, status: :internal_server_error }
    end
  end

  def accept
    contact = Contact.find(params[:id])
    contact.update!(friendship_status: :accepted)

    # Publish updated Kind 3 contact list
    NostrPublishJob.perform_later(current_user.id, :contacts)

    # Send acceptance DM
    send_friend_response_dm(contact.pubkey, "accepted")

    respond_to do |format|
      format.html { redirect_to conversations_path(tab: "all"), notice: "Friend request accepted!" }
      format.json { render json: { status: "accepted" } }
    end
  end

  def decline
    contact = Contact.find(params[:id])
    contact.update!(friendship_status: :declined)

    send_friend_response_dm(contact.pubkey, "declined")

    respond_to do |format|
      format.html { redirect_to conversations_path(tab: "pending"), notice: "Friend request declined." }
      format.json { render json: { status: "declined" } }
    end
  end

  def ignore
    contact = Contact.find(params[:id])
    contact.update!(friendship_status: :not_friend)

    respond_to do |format|
      format.html { redirect_to conversations_path(tab: "pending"), notice: "Friend request ignored." }
      format.json { render json: { status: "ignored" } }
    end
  end

  def destroy
    contact = Contact.find(params[:id])
    name = contact.effective_display_name
    was_pending = contact.pending_outgoing?
    contact.update!(friendship_status: :not_friend)

    # Publish updated Kind 3 contact list
    NostrPublishJob.perform_later(current_user.id, :contacts)

    if was_pending
      redirect_to conversations_path(tab: "pending"), notice: "Friend request to #{name} cancelled."
    else
      redirect_to conversations_path(tab: "all"), notice: "Removed #{name} from contacts."
    end
  end

  private

  def parse_pubkey(input)
    return nil if input.blank?

    if input.start_with?("npub1")
      begin
        decoded = Nostr::Bech32.decode_npub(input)
        return decoded if decoded.is_a?(String) && decoded.length == 64
      rescue
        return nil
      end
    end

    # Hex pubkey (64 chars)
    return input.downcase if input.match?(/\A[0-9a-f]{64}\z/i)

    nil
  end

  def send_friend_request_dm(pubkey)
    return unless current_user.nostr_private_key.present?

    conversation_key = Nip44Service.conversation_key(
      current_user.nostr_private_key, pubkey
    )

    payload = { type: "friend_request", from: current_user.nostr_public_key }.to_json
    encrypted = Nip44Service.encrypt(payload, conversation_key)

    event = build_nostr_event(
      kind: 14,
      content: encrypted,
      tags: [["p", pubkey]],
      privkey: current_user.nostr_private_key,
      pubkey: current_user.nostr_public_key
    )

    publish_to_relays(event)
  end

  def send_friend_response_dm(pubkey, status)
    return unless current_user.nostr_private_key.present?

    conversation_key = Nip44Service.conversation_key(
      current_user.nostr_private_key, pubkey
    )

    payload = { type: "friend_response", status: status, from: current_user.nostr_public_key }.to_json
    encrypted = Nip44Service.encrypt(payload, conversation_key)

    event = build_nostr_event(
      kind: 14,
      content: encrypted,
      tags: [["p", pubkey]],
      privkey: current_user.nostr_private_key,
      pubkey: current_user.nostr_public_key
    )

    publish_to_relays(event)
  end

  def build_nostr_event(kind:, content:, tags:, privkey:, pubkey:)
    signer = Nostr::Signer.new(private_key: privkey)
    event = Nostr::Event.new(
      kind: kind,
      pubkey: pubkey,
      content: content,
      tags: tags
    )
    signed = signer.sign(event)
    signed.to_json
  end

  def publish_to_relays(event)
    RelayService.publish_to_all(event)
  end
end
