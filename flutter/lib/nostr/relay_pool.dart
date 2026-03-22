import 'dart:async';
import '../crypto/nostr_event.dart';
import 'nostr_filter.dart';
import 'relay_connection.dart' as rc;
import 'subscription.dart';

typedef EventHandler = void Function(String relayUrl, NostrEvent event);
typedef EoseHandler = void Function(String relayUrl, String subscriptionId);

class RelayPool {
  final Map<String, rc.RelayConnection> _connections = {};
  final Map<String, Subscription> _subscriptions = {};

  // Event handlers by kind
  final Map<int, List<EventHandler>> _kindHandlers = {};
  // Catch-all handler
  final List<EventHandler> _globalHandlers = [];
  // EOSE handlers
  final Map<String, EoseHandler> _eoseHandlers = {};
  // AUTH handler
  void Function(String relayUrl, String challenge)? onAuthChallenge;
  // Deduplication: set of event IDs already processed
  final Set<String> _processedEventIds = {};

  // OK response completers for publish tracking
  final Map<String, Completer<bool>> _publishCompleters = {};

  bool _running = false;
  bool get isRunning => _running;

  /// Start the pool with a list of relay URLs
  Future<void> start(List<String> relayUrls) async {
    _running = true;
    for (final url in relayUrls) {
      await addRelay(url);
    }
  }

  /// Add a relay and connect
  Future<void> addRelay(String url) async {
    if (_connections.containsKey(url)) return;

    final conn = rc.RelayConnection(
      url: url,
      onMessage: _handleRelayMessage,
      onStateChange: _handleStateChange,
    );
    _connections[url] = conn;
    await conn.connect();
  }

  /// Remove a relay
  void removeRelay(String url) {
    final conn = _connections.remove(url);
    conn?.disconnect();
  }

  /// Stop all connections
  void stop() {
    _running = false;
    for (final conn in _connections.values) {
      conn.disconnect();
    }
    _connections.clear();
    _subscriptions.clear();
    _processedEventIds.clear();
  }

  /// Subscribe to events matching filters on all connected relays
  /// Returns the subscription ID
  String subscribe({
    required List<NostrFilter> filters,
    EventHandler? onEvent,
    EoseHandler? onEose,
  }) {
    final sub = Subscription(filters: filters);

    if (onEvent != null) {
      _kindHandlers.putIfAbsent(-1, () => []);
      // Store per-subscription handler via a wrapper
    }
    if (onEose != null) {
      _eoseHandlers[sub.id] = onEose;
    }

    _subscriptions[sub.id] = sub;

    for (final conn in _connections.values) {
      conn.subscribe(sub);
    }

    return sub.id;
  }

  /// Unsubscribe from a subscription
  void unsubscribe(String subscriptionId) {
    _subscriptions.remove(subscriptionId);
    _eoseHandlers.remove(subscriptionId);
    for (final conn in _connections.values) {
      conn.unsubscribe(subscriptionId);
    }
  }

  /// Publish a signed event to all connected relays
  /// Returns a map of relay URL -> success boolean
  Future<Map<String, bool>> publish(NostrEvent signedEvent) async {
    final results = <String, bool>{};
    final futures = <Future>[];

    for (final conn in _connections.values) {
      if (!conn.isConnected) {
        results[conn.url] = false;
        continue;
      }

      final completer = Completer<bool>();
      final eventId = signedEvent.id!;
      final key = '${conn.url}:$eventId';
      _publishCompleters[key] = completer;

      conn.sendEvent(signedEvent);

      // Timeout after 15 seconds
      futures.add(
        completer.future.timeout(
          const Duration(seconds: 15),
          onTimeout: () => false,
        ).then((success) {
          results[conn.url] = success;
          _publishCompleters.remove(key);
        }),
      );
    }

    await Future.wait(futures);
    return results;
  }

  /// Fetch events matching a filter from all relays (one-shot query)
  /// Waits for EOSE from all relays, deduplicates by event ID
  Future<List<NostrEvent>> fetch(NostrFilter filter, {Duration timeout = const Duration(seconds: 15)}) async {
    final events = <String, NostrEvent>{}; // dedup by event ID
    final completer = Completer<void>();
    int pendingEose = _connections.values.where((c) => c.isConnected).length;
    if (pendingEose == 0) return [];

    final sub = Subscription(
      filters: [filter],
      onEvent: (event) {
        if (event.id != null) {
          events[event.id!] = event;
        }
      },
      onEose: (subId) {
        pendingEose--;
        if (pendingEose <= 0 && !completer.isCompleted) {
          completer.complete();
        }
      },
    );

    _subscriptions[sub.id] = sub;
    _eoseHandlers[sub.id] = (relayUrl, subId) {
      sub.onEose?.call(subId);
    };

    for (final conn in _connections.values) {
      if (conn.isConnected) {
        conn.subscribe(sub);
      }
    }

    // Wait for all EOSE or timeout
    await completer.future.timeout(timeout, onTimeout: () {});

    // Cleanup
    unsubscribe(sub.id);

    return events.values.toList();
  }

  /// Register a handler for events of a specific kind
  void onKind(int kind, EventHandler handler) {
    _kindHandlers.putIfAbsent(kind, () => []).add(handler);
  }

  /// Register a handler for all events
  void onEvent(EventHandler handler) {
    _globalHandlers.add(handler);
  }

  /// Remove all handlers for a kind
  void removeKindHandlers(int kind) {
    _kindHandlers.remove(kind);
  }

  /// Get connection state for a relay
  rc.RelayConnectionState? getRelayState(String url) {
    return _connections[url]?.state;
  }

  /// Get all relay URLs
  List<String> get relayUrls => _connections.keys.toList();

  /// Get connected relay count
  int get connectedCount => _connections.values.where((c) => c.isConnected).length;

  /// Exposed for testing — processes a relay message as if received from a relay
  void handleRelayMessageForTest(String relayUrl, List<dynamic> message) =>
      _handleRelayMessage(relayUrl, message);

  void _handleRelayMessage(String relayUrl, List<dynamic> message) {
    if (message.isEmpty) return;
    final type = message[0] as String;

    switch (type) {
      case 'EVENT':
        _handleEventMessage(relayUrl, message);
        break;
      case 'EOSE':
        _handleEoseMessage(relayUrl, message);
        break;
      case 'OK':
        _handleOkMessage(relayUrl, message);
        break;
      case 'AUTH':
        _handleAuthMessage(relayUrl, message);
        break;
      case 'NOTICE':
        // Log or ignore relay notices
        break;
    }
  }

  void _handleEventMessage(String relayUrl, List<dynamic> message) {
    if (message.length < 3) return;
    final subId = message[1] as String;
    final eventData = message[2];
    if (eventData is! Map) return;

    try {
      final event = NostrEvent.fromJson(Map<String, dynamic>.from(eventData));

      // Deduplication
      if (event.id != null && _processedEventIds.contains(event.id)) return;
      if (event.id != null) _processedEventIds.add(event.id!);

      // Per-subscription handler
      final sub = _subscriptions[subId];
      sub?.onEvent?.call(event);

      // Kind-specific handlers
      final handlers = _kindHandlers[event.kind];
      if (handlers != null) {
        for (final handler in handlers) {
          handler(relayUrl, event);
        }
      }

      // Global handlers
      for (final handler in _globalHandlers) {
        handler(relayUrl, event);
      }
    } catch (_) {}
  }

  void _handleEoseMessage(String relayUrl, List<dynamic> message) {
    if (message.length < 2) return;
    final subId = message[1] as String;
    final sub = _subscriptions[subId];
    sub?.eoseReceived = true;
    _eoseHandlers[subId]?.call(relayUrl, subId);
  }

  void _handleOkMessage(String relayUrl, List<dynamic> message) {
    if (message.length < 3) return;
    final eventId = message[1] as String;
    final success = message[2] as bool;
    final key = '$relayUrl:$eventId';
    _publishCompleters[key]?.complete(success);
    _publishCompleters.remove(key);
  }

  void _handleAuthMessage(String relayUrl, List<dynamic> message) {
    if (message.length < 2) return;
    final challenge = message[1] as String;
    onAuthChallenge?.call(relayUrl, challenge);
  }

  void _handleStateChange(String relayUrl, rc.RelayConnectionState state) {
    // Could emit to a stream for UI consumption
  }
}
