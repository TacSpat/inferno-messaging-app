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

    broadcast_friend_update

    # Send friend request as NIP-44 encrypted DM (in background, don't block response)
    user = current_user
    Thread.new { send_friend_request_dm_async(user, pubkey) }

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

    # Send acceptance DM in background thread (don't block the response)
    pubkey = contact.pubkey
    user = current_user
    Thread.new { send_friend_response_dm_async(user, pubkey, "accepted") }

    broadcast_friend_update

    respond_to do |format|
      format.html { redirect_to conversations_path(tab: "all"), notice: "Friend request accepted!" }
      format.json { render json: { status: "accepted" } }
    end
  end

  def decline
    contact = Contact.find(params[:id])
    contact.update!(friendship_status: :declined)

    pubkey = contact.pubkey
    user = current_user
    Thread.new { send_friend_response_dm_async(user, pubkey, "declined") }

    broadcast_friend_update

    respond_to do |format|
      format.html { redirect_to conversations_path(tab: "pending"), notice: "Friend request declined." }
      format.json { render json: { status: "declined" } }
    end
  end

  def ignore
    contact = Contact.find(params[:id])
    contact.update!(friendship_status: :not_friend)

    broadcast_friend_update

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

    # Notify the other party via Nostr DM
    pubkey = contact.pubkey
    user = current_user
    Thread.new { send_friend_response_dm_async(user, pubkey, "removed") }

    broadcast_friend_update

    tab = was_pending ? "pending" : "all"
    notice = was_pending ? "Friend request to #{name} cancelled." : "Removed #{name} from contacts."

    respond_to do |format|
      format.html { redirect_to conversations_path(tab: tab), notice: notice }
      format.json { render json: { status: "removed" } }
    end
  end

  private

  def broadcast_friend_update
    ActionCable.server.broadcast("user_notifications_#{current_user.id}", {
      type: "friend_update",
      pending_count: Contact.pending_incoming.count
    })
    # Refresh relay subscriptions to include/exclude the contact's presence
    RelaySubscriptionManager.instance.refresh_subscriptions
  end

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

  def send_friend_request_dm_async(user, pubkey)
    return unless user.nostr_private_key.present?

    conversation_key = Nip44Service.conversation_key(user.nostr_private_key, pubkey)
    payload = { type: "friend_request", from: user.nostr_public_key }.to_json
    encrypted = Nip44Service.encrypt(payload, conversation_key)

    event = build_nostr_event(
      kind: 14, content: encrypted, tags: [ [ "p", pubkey ] ],
      privkey: user.nostr_private_key, pubkey: user.nostr_public_key
    )
    RelayService.publish_to_all(event)
  rescue => e
    Rails.logger.error("Failed to send friend request DM: #{e.message}")
  end

  def send_friend_response_dm_async(user, pubkey, status)
    return unless user.nostr_private_key.present?

    conversation_key = Nip44Service.conversation_key(user.nostr_private_key, pubkey)
    payload = { type: "friend_response", status: status, from: user.nostr_public_key }.to_json
    encrypted = Nip44Service.encrypt(payload, conversation_key)

    event = build_nostr_event(
      kind: 14, content: encrypted, tags: [ [ "p", pubkey ] ],
      privkey: user.nostr_private_key, pubkey: user.nostr_public_key
    )
    RelayService.publish_to_all(event)
  rescue => e
    Rails.logger.error("Failed to send friend response DM: #{e.message}")
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
