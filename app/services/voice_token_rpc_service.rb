require "concurrent"

class VoiceTokenRpcService
  class TimeoutError < StandardError; end
  class RpcError < StandardError; end

  TIMEOUT = 10 # seconds

  # Use ||= so dev hot-reload doesn't wipe pending futures
  @pending_requests ||= Concurrent::Map.new # request_id => ResolvableFuture

  class << self
    def request_token(provider_pubkey:, requesting_user:, server:, channel:)
      # Use instance owner for relay communication — the relay subscription
      # is keyed on the owner's pubkey, so responses must be addressed to them.
      owner = User.owner
      raise RpcError, "Instance owner has no Nostr identity" unless owner&.nostr_private_key.present?

      request_id = SecureRandom.hex(16)
      future = Concurrent::Promises.resolvable_future

      pending_requests[request_id] = future

      payload = {
        type: "voice_token_request",
        request_id: request_id,
        server_nostr_group_id: server.nostr_group_id,
        channel_id: channel.public_id,
        user_pubkey: requesting_user.nostr_public_key,
        user_display_name: requesting_user.display_name.presence || requesting_user.username,
        user_id: requesting_user.public_id
      }.to_json

      conversation_key = Nip44Service.conversation_key(owner.nostr_private_key, provider_pubkey)
      encrypted = Nip44Service.encrypt(payload, conversation_key)

      signer = Nostr::Signer.new(private_key: owner.nostr_private_key)
      event = Nostr::Event.new(
        kind: 14,
        pubkey: owner.nostr_public_key,
        content: encrypted,
        tags: [ [ "p", provider_pubkey ] ]
      )
      signed = signer.sign(event)
      RelayService.publish_to_all(signed.to_json)

      Rails.logger.info("[VoiceTokenRpcService] Published token request #{request_id} to #{provider_pubkey[0..15]} as #{owner.nostr_public_key[0..15]} (#{pending_requests.size} pending)")

      # Block until response arrives or timeout
      result = future.value!(TIMEOUT)

      unless future.resolved?
        Rails.logger.warn("[VoiceTokenRpcService] Timeout waiting for #{request_id} (#{pending_requests.size} pending)")
        raise TimeoutError, "Voice provider did not respond within #{TIMEOUT}s"
      end

      raise RpcError, "Voice provider returned no result" unless result

      result
    ensure
      pending_requests.delete(request_id) if request_id
    end

    def resolve_request(request_id, result)
      future = pending_requests.delete(request_id)
      if future
        future.fulfill(result)
        Rails.logger.info("[VoiceTokenRpcService] Resolved request #{request_id}")
      else
        Rails.logger.warn("[VoiceTokenRpcService] No pending request for #{request_id} (#{pending_requests.size} pending)")
      end
    end

    def pending_request?(request_id)
      pending_requests.key?(request_id)
    end

    private

    def pending_requests
      @pending_requests ||= Concurrent::Map.new
    end
  end
end
