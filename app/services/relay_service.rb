require "faye/websocket"
require "eventmachine"

class RelayService
  CONNECT_TIMEOUT = 10 # seconds
  RESPONSE_TIMEOUT = 15 # seconds

  class ConnectionError < StandardError; end
  class PublishError < StandardError; end
  class TimeoutError < StandardError; end

  # Publish a signed event to all active relays
  # Returns hash of { relay_url => { success: bool, message: str } }
  def self.publish_to_all(signed_event)
    relays = RelayConnection.active
    return {} if relays.empty?

    results = {}
    relays.find_each do |relay|
      results[relay.url] = publish_to_relay(relay, signed_event)
    end
    results
  end

  # Publish a signed event to a specific relay
  def self.publish_to_relay(relay, signed_event)
    event_message = JSON.generate([ "EVENT", signed_event ])
    result = { success: false, message: "Not attempted" }

    run_with_eventmachine do |done|
      ws = Faye::WebSocket::Client.new(relay.url)

      timer = EventMachine.add_timer(RESPONSE_TIMEOUT) do
        result = { success: false, message: "Timeout waiting for relay response" }
        ws.close
        done.call
      end

      ws.on :open do |_event|
        relay.mark_connected!
        ws.send(event_message)
      end

      ws.on :message do |event|
        data = JSON.parse(event.data) rescue nil
        if data.is_a?(Array) && data[0] == "OK"
          EventMachine.cancel_timer(timer)
          result = { success: data[2], message: data[3] || "OK" }
          ws.close
          done.call
        end
      end

      ws.on :error do |event|
        EventMachine.cancel_timer(timer)
        error_msg = "WebSocket error: #{event.message rescue 'unknown'}"
        relay.mark_error!(error_msg)
        result = { success: false, message: error_msg }
        done.call
      end

      ws.on :close do |_event|
        EventMachine.cancel_timer(timer) rescue nil
        done.call
      end
    end

    result
  rescue StandardError => e
    relay.mark_error!(e.message) if relay.respond_to?(:mark_error!)
    { success: false, message: e.message }
  end

  # Fetch events matching a filter from a specific relay
  # Returns an array of event hashes
  def self.fetch_from_relay(relay_url, filter, timeout: RESPONSE_TIMEOUT)
    events = []
    sub_id = SecureRandom.hex(8)
    req_message = JSON.generate([ "REQ", sub_id, filter ])
    close_message = JSON.generate([ "CLOSE", sub_id ])

    run_with_eventmachine do |done|
      ws = Faye::WebSocket::Client.new(relay_url)

      timer = EventMachine.add_timer(timeout) do
        ws.send(close_message) rescue nil
        ws.close
        done.call
      end

      ws.on :open do |_event|
        ws.send(req_message)
      end

      ws.on :message do |event|
        data = JSON.parse(event.data) rescue nil
        next unless data.is_a?(Array)

        case data[0]
        when "EVENT"
          events << data[2] if data[2].is_a?(Hash)
        when "EOSE"
          # End of stored events — we have all results
          EventMachine.cancel_timer(timer)
          ws.send(close_message)
          ws.close
          done.call
        end
      end

      ws.on :error do |_event|
        EventMachine.cancel_timer(timer)
        done.call
      end

      ws.on :close do |_event|
        EventMachine.cancel_timer(timer) rescue nil
        done.call
      end
    end

    events
  end

  # Fetch events from all active relays, deduplicating by event id
  def self.fetch_from_all(filter, timeout: RESPONSE_TIMEOUT)
    relays = RelayConnection.active
    return [] if relays.empty?

    all_events = {}
    relays.find_each do |relay|
      events = fetch_from_relay(relay.url, filter, timeout: timeout)
      events.each do |event|
        # Keep the most recent version (dedup by event id)
        all_events[event["id"]] = event
      end
    end
    all_events.values
  end

  private_class_method def self.run_with_eventmachine(&block)
    if EventMachine.reactor_running?
      # Already inside an EM reactor (e.g. nested call)
      done = -> { }
      block.call(done)
    else
      EventMachine.run do
        done = -> { EventMachine.stop }
        block.call(done)
      end
    end
  end
end
