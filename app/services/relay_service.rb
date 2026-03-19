require "faye/websocket"
require "eventmachine"

class RelayService
  CONNECT_TIMEOUT = 10 # seconds
  RESPONSE_TIMEOUT = 15 # seconds

  class ConnectionError < StandardError; end
  class PublishError < StandardError; end
  class TimeoutError < StandardError; end

  # Publish a signed event to all active relays.
  # Uses the SubscriptionManager's existing WebSocket connections when available
  # (non-blocking fire-and-forget). Falls back to opening new connections in parallel.
  def self.publish_to_all(signed_event)
    urls = RelayConnection.active.pluck(:url)
    return {} if urls.empty?

    event_message = JSON.generate([ "EVENT", signed_event ])

    # Try to use existing SubscriptionManager connections (non-blocking)
    manager = RelaySubscriptionManager.instance
    if manager.running && EventMachine.reactor_running?
      results = {}
      EventMachine.next_tick do
        urls.each do |url|
          conn = manager.connections[url]
          if conn && conn[:ws]
            begin
              conn[:ws].send(event_message)
              Rails.logger.debug("[RelayService] Published via SubscriptionManager to #{url}")
            rescue => e
              Rails.logger.warn("[RelayService] Failed to publish to #{url}: #{e.message}")
            end
          end
        end
      end
      urls.each { |url| results[url] = { success: true, message: "Sent via persistent connection" } }
      return results
    end

    # Fallback: open new connections in parallel (all relays in one EM tick)
    publish_via_new_connections(urls, event_message)
  end

  # Publish via new WebSocket connections — all relays in parallel within one EM session
  def self.publish_via_new_connections(urls, event_message)
    results = {}
    mutex = Mutex.new
    queue = Queue.new

    do_publish = proc do
      pending = urls.size

      finish_one = lambda do
        count = mutex.synchronize { pending -= 1; pending }
        queue.push(:done) if count <= 0
      end

      urls.each do |url|
        ws = Faye::WebSocket::Client.new(url)
        finished = false

        timer = EventMachine.add_timer(RESPONSE_TIMEOUT) do
          next if finished
          finished = true
          mutex.synchronize { results[url] = { success: false, message: "Timeout" } }
          ws.close rescue nil
          finish_one.call
        end

        ws.on :open do |_event|
          ws.send(event_message)
        end

        ws.on :message do |event|
          data = JSON.parse(event.data) rescue nil
          if data.is_a?(Array) && data[0] == "OK"
            next if finished
            finished = true
            EventMachine.cancel_timer(timer)
            mutex.synchronize { results[url] = { success: data[2], message: data[3] || "OK" } }
            ws.close rescue nil
            finish_one.call
          end
        end

        ws.on :error do |event|
          next if finished
          finished = true
          EventMachine.cancel_timer(timer)
          mutex.synchronize { results[url] = { success: false, message: "Error: #{event.message rescue 'unknown'}" } }
          finish_one.call
        end

        ws.on :close do |_event|
          next if finished
          finished = true
          EventMachine.cancel_timer(timer) rescue nil
          mutex.synchronize { results[url] ||= { success: false, message: "Closed" } }
          finish_one.call
        end
      end
    end

    if EventMachine.reactor_running?
      EventMachine.next_tick(&do_publish)
    else
      Thread.new { EventMachine.run(&do_publish) }
    end

    queue.pop(timeout: RESPONSE_TIMEOUT + 3)
    results
  end
  private_class_method :publish_via_new_connections

  # Fetch events matching a filter from a specific relay
  # Returns an array of event hashes
  def self.fetch_from_relay(relay_url, filter, timeout: RESPONSE_TIMEOUT)
    events = []
    sub_id = SecureRandom.hex(8)
    req_message = JSON.generate([ "REQ", sub_id, filter ])
    close_message = JSON.generate([ "CLOSE", sub_id ])
    queue = Queue.new

    do_fetch = proc do
      ws = Faye::WebSocket::Client.new(relay_url)
      finished = false

      timer = EventMachine.add_timer(timeout) do
        next if finished
        finished = true
        ws.send(close_message) rescue nil
        ws.close rescue nil
        queue.push(:done)
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
          next if finished
          finished = true
          EventMachine.cancel_timer(timer)
          ws.send(close_message) rescue nil
          ws.close rescue nil
          queue.push(:done)
        end
      end

      ws.on :error do |_event|
        next if finished
        finished = true
        EventMachine.cancel_timer(timer)
        queue.push(:done)
      end

      ws.on :close do |_event|
        next if finished
        finished = true
        EventMachine.cancel_timer(timer) rescue nil
        queue.push(:done)
      end
    end

    if EventMachine.reactor_running?
      EventMachine.next_tick(&do_fetch)
    else
      Thread.new { EventMachine.run(&do_fetch) }
    end

    queue.pop(timeout: timeout + 3)
    events
  end

  # Fetch events from all active relays in parallel, deduplicating by event id.
  # Safe to call whether or not EM is already running.
  def self.fetch_from_all(filter, timeout: RESPONSE_TIMEOUT)
    urls = RelayConnection.active.pluck(:url)
    return [] if urls.empty?

    all_events = {}
    mutex = Mutex.new
    queue = Queue.new

    do_fetch = proc do
      pending = urls.size

      finish_one = lambda do
        count = mutex.synchronize { pending -= 1; pending }
        queue.push(:done) if count <= 0
      end

      urls.each do |url|
        sub_id = SecureRandom.hex(8)
        req_message = JSON.generate([ "REQ", sub_id, filter ])
        close_message = JSON.generate([ "CLOSE", sub_id ])

        ws = Faye::WebSocket::Client.new(url)
        finished = false

        timer = EventMachine.add_timer(timeout) do
          next if finished
          finished = true
          ws.send(close_message) rescue nil
          ws.close rescue nil
          finish_one.call
        end

        ws.on :open do |_event|
          ws.send(req_message)
        end

        ws.on :message do |event|
          data = JSON.parse(event.data) rescue nil
          next unless data.is_a?(Array)

          case data[0]
          when "EVENT"
            if data[2].is_a?(Hash)
              mutex.synchronize { all_events[data[2]["id"]] = data[2] }
            end
          when "EOSE"
            next if finished
            finished = true
            EventMachine.cancel_timer(timer)
            ws.send(close_message) rescue nil
            ws.close rescue nil
            finish_one.call
          end
        end

        ws.on :error do |_event|
          next if finished
          finished = true
          EventMachine.cancel_timer(timer)
          finish_one.call
        end

        ws.on :close do |_event|
          next if finished
          finished = true
          EventMachine.cancel_timer(timer) rescue nil
          finish_one.call
        end
      end
    end

    if EventMachine.reactor_running?
      EventMachine.next_tick(&do_fetch)
    else
      Thread.new do
        EventMachine.run(&do_fetch)
      end
    end

    queue.pop(timeout: timeout + 3)
    all_events.values
  end
end
