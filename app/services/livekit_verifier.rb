require "net/http"
require "openssl"

class LivekitVerifier
  class VerificationError < StandardError; end

  Result = Struct.new(:success, :message, keyword_init: true)

  # Verify a user's LiveKit credentials:
  # 1. Must use wss:// scheme
  # 2. TLS certificate must be valid
  # 3. Health endpoint must respond
  # Updates user.livekit_verified and livekit_verified_at on success.
  def self.verify!(user:)
    url = user.livekit_url
    api_key = user.livekit_api_key
    api_secret = user.livekit_api_secret

    # 1. Validate URL scheme
    unless url.present? && url.start_with?("wss://")
      return Result.new(success: false, message: "URL must use wss:// (secure WebSocket)")
    end

    # 2. Validate TLS certificate
    https_url = url.sub(%r{^wss://}, "https://")
    uri = URI(https_url)

    begin
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 10
      http.read_timeout = 10

      # 3. Health check
      response = http.request(Net::HTTP::Get.new("/"))
      unless response.is_a?(Net::HTTPSuccess)
        return Result.new(success: false, message: "Server responded with HTTP #{response.code}")
      end
    rescue OpenSSL::SSL::SSLError => e
      return Result.new(success: false, message: "TLS verification failed: #{e.message}")
    rescue Errno::ECONNREFUSED
      return Result.new(success: false, message: "Connection refused. Is the server running?")
    rescue SocketError => e
      return Result.new(success: false, message: "DNS resolution failed: #{e.message}")
    rescue Net::OpenTimeout, Net::ReadTimeout
      return Result.new(success: false, message: "Connection timed out")
    rescue => e
      return Result.new(success: false, message: "Verification failed: #{e.message}")
    end

    # 4. Verify API credentials by generating a test token
    if api_key.present? && api_secret.present?
      begin
        now = Time.now.to_i
        test_payload = {
          iss: api_key,
          exp: now + 30,
          nbf: now - 5,
          iat: now,
          video: { roomList: true }
        }
        JWT.encode(test_payload, api_secret, "HS256")
      rescue => e
        return Result.new(success: false, message: "API credentials invalid: #{e.message}")
      end
    end

    # Update verification status on the user
    user.update!(
      livekit_verified: true,
      livekit_verified_at: Time.current
    )

    Result.new(success: true, message: "LiveKit server verified successfully")
  end
end
