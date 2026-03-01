# Embedded Nostr relay via ActionCable WebSocket.
# Handles NIP-01 protocol: REQ, EVENT, CLOSE.
# Clients connect to wss://host/relay
class RelayChannel < ApplicationCable::Channel
  def subscribed
    @subscriptions = {}
    stream_from "relay_broadcast"
  end

  def unsubscribed
    @subscriptions = {}
  end

  # Handle incoming messages (NIP-01 protocol)
  def receive(data)
    return unless data.is_a?(Array) && data.length >= 2

    case data[0]
    when "REQ"
      handle_req(data)
    when "EVENT"
      handle_event(data)
    when "CLOSE"
      handle_close(data)
    end
  rescue => e
    Rails.logger.error("[RelayChannel] Error: #{e.message}")
    transmit [ "NOTICE", "error: #{e.message}" ]
  end

  private

  def handle_req(data)
    sub_id = data[1]
    return transmit([ "NOTICE", "missing subscription id" ]) unless sub_id.present?

    # Support multiple filters per REQ
    filters = data[2..].select { |f| f.is_a?(Hash) }
    return transmit([ "NOTICE", "missing filter" ]) if filters.empty?

    # Query stored events matching filters
    filters.each do |filter|
      events = NostrEvent.apply_filter(filter)
      events.each do |event|
        transmit [ "EVENT", sub_id, event.to_nostr_event ]
      end
    end

    # Send EOSE (End of Stored Events)
    transmit [ "EOSE", sub_id ]

    # Register subscription for live events
    @subscriptions[sub_id] = filters
    stream_from "relay_live_#{sub_id}_#{connection.connection_identifier}"
  end

  def handle_event(data)
    event = data[1]
    return transmit([ "NOTICE", "invalid event" ]) unless event.is_a?(Hash)

    event_id = event["id"]
    return transmit([ "OK", "", false, "missing event id" ]) unless event_id.present?

    # Validate required fields
    %w[pubkey created_at kind tags content sig].each do |field|
      unless event.key?(field)
        return transmit([ "OK", event_id, false, "missing field: #{field}" ])
      end
    end

    # Store the event
    stored = NostrEvent.store_event(event)
    if stored
      transmit [ "OK", event_id, true, "" ]

      # Broadcast to other subscribers
      ActionCable.server.broadcast("relay_broadcast", [ "EVENT", nil, stored.to_nostr_event ])
    else
      transmit [ "OK", event_id, false, "error: could not store event" ]
    end
  end

  def handle_close(data)
    sub_id = data[1]
    @subscriptions.delete(sub_id) if sub_id
    stop_stream_from "relay_live_#{sub_id}_#{connection.connection_identifier}" if sub_id
    transmit [ "CLOSED", sub_id, "" ]
  end
end
