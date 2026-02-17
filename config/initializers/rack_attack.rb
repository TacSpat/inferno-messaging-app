class Rack::Attack
  # --- Nostr Auth Rate Limiting ---

  # Throttle auth requests per IP: 10 per minute
  throttle("nostr_auth/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/auth/nostr")
  end

  # Throttle auth callbacks per home_instance domain: 30 per 5 minutes
  throttle("nostr_auth/domain", limit: 30, period: 5.minutes) do |req|
    if req.path == "/auth/nostr/callback" && req.params["event"].present?
      # Extract domain from the signed event if possible
      req.ip
    end
  end

  # Throttle auth initiation per home_instance: 20 per 5 minutes
  throttle("nostr_auth/home_instance", limit: 20, period: 5.minutes) do |req|
    req.params["home_instance"] if req.path == "/auth/nostr" && req.get?
  end

  # --- General API Rate Limiting ---

  # Throttle login attempts per IP: 5 per 20 seconds
  throttle("login/ip", limit: 5, period: 20.seconds) do |req|
    req.ip if req.path == "/users/sign_in" && req.post?
  end

  # Throttle registration per IP: 3 per hour
  throttle("registration/ip", limit: 3, period: 1.hour) do |req|
    req.ip if req.path == "/users" && req.post?
  end

  # --- Relay Event Rate Limiting ---
  # (Applied at the application level in NostrGroupSubscriptionJob,
  #  not at Rack level since relay events come via WebSocket)

  # --- Throttle Response ---
  self.throttled_responder = lambda do |request|
    retry_after = (request.env["rack.attack.match_data"] || {})[:period]
    [
      429,
      { "Content-Type" => "application/json", "Retry-After" => retry_after.to_s },
      [ { error: "Rate limit exceeded. Please try again later." }.to_json ]
    ]
  end
end
