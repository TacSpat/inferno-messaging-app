import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../crypto/nostr_event.dart';
import 'nostr_filter.dart';
import 'relay_auth.dart';
import 'relay_connection.dart' as rc;
import 'subscription.dart';

/// Top-level function for compute() — parses NostrEvent JSON on a background isolate.
List<NostrEvent> _parseEventsInBackground(List<Map<String, dynamic>> jsons) {
  return jsons.map((j) => NostrEvent.fromJson(j)).toList();
}

typedef EventHandler = void Function(String relayUrl, NostrEvent event);
typedef EoseHandler = void Function(String relayUrl, String subscriptionId);

class RelayPool {
  final Map<String, rc.RelayConnection> _connections = {};
  final Map<String, Subscription> _subscriptions = {};

  /// URLs of currently connected relays
  List<String> get connectedRelayUrls =>
      _connections.values.where((c) => c.isConnected).map((c) => c.url).toList();

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

  // Track relay failures for fetchFresh — skip after 3 consecutive failures
  final Map<String, int> _freshFetchFailures = {};

  // Auth credentials for NIP-42 (used by fetchFresh for throwaway connections)
  String? authPrivateKeyHex;
  String? authPublicKeyHex;

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

  /// Fetch using brand new throwaway WebSocket connections (matches Rails fetch_from_all).
  /// Opens independent WebSockets, sends REQ, collects events until EOSE, then closes.
  Future<List<NostrEvent>> fetchFresh(NostrFilter filter, {Duration timeout = const Duration(seconds: 15)}) async {
    final urls = _connections.keys.toList();
    if (urls.isEmpty) return [];

    final events = <String, NostrEvent>{};

    // Fetch from each relay independently in parallel (skip relays with 3+ consecutive failures)
    final activeUrls = urls.where((url) => (_freshFetchFailures[url] ?? 0) < 3).toList();
    if (activeUrls.isEmpty) {
      // Reset all failures and try again
      _freshFetchFailures.clear();
      activeUrls.addAll(urls);
    }
    final futures = activeUrls.map((url) => _fetchFromSingleRelay(url, filter, events, timeout));
    await Future.wait(futures);

    debugPrint('[RelayPool] fetchFresh: ${events.length} events from ${urls.length} relays (filter: kinds=${filter.kinds} tags=${filter.tags})');
    return events.values.toList();
  }

  /// Fetch from a single relay using a brand new WebSocket connection.
  /// Collects raw JSON strings and parses them on a background isolate to
  /// keep the UI thread free during large fetches.
  Future<void> _fetchFromSingleRelay(String url, NostrFilter filter, Map<String, NostrEvent> events, Duration timeout) async {
    final completer = Completer<void>();
    WebSocketChannel? ws;
    final rawEventJsons = <Map<String, dynamic>>[];

    try {
      ws = WebSocketChannel.connect(Uri.parse(url));
      await ws.ready;

      final subId = 'f-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
      final reqMsg = json.encode(['REQ', subId, filter.toJson()]);
      bool done = false;

      ws.stream.listen((data) {
        if (done) return;
        try {
          final parsed = json.decode(data as String) as List<dynamic>;
          if (parsed[0] == 'EVENT' && parsed.length >= 3) {
            // Collect raw JSON — parse on background isolate later
            rawEventJsons.add(Map<String, dynamic>.from(parsed[2] as Map));
          } else if (parsed[0] == 'EOSE') {
            done = true;
            try { ws?.sink.close(); } catch (_) {}
            if (!completer.isCompleted) completer.complete();
          } else if (parsed[0] == 'AUTH' && parsed.length >= 2) {
            // NIP-42: relay wants auth — respond if we have credentials
            if (authPrivateKeyHex != null && authPublicKeyHex != null) {
              final challenge = parsed[1] as String;
              try {
                final authEvent = RelayAuth.buildAuthEvent(
                  challenge: challenge,
                  relayUrl: url,
                  privateKeyHex: authPrivateKeyHex!,
                  publicKeyHex: authPublicKeyHex!,
                );
                ws?.sink.add(json.encode(['AUTH', authEvent.toJson()]));
                ws?.sink.add(reqMsg);
                debugPrint('[fetchFresh] $url: authenticated and re-sent REQ');
              } catch (e) {
                debugPrint('[fetchFresh] $url: AUTH failed: $e');
              }
            } else {
              debugPrint('[fetchFresh] $url wants AUTH but no credentials available');
            }
          }
        } catch (_) {}
      }, onError: (_) {
        if (!completer.isCompleted) completer.complete();
      }, onDone: () {
        if (!completer.isCompleted) completer.complete();
      });

      ws.sink.add(reqMsg);

      await completer.future.timeout(timeout, onTimeout: () {
        debugPrint('[fetchFresh] $url timed out');
        _freshFetchFailures[url] = (_freshFetchFailures[url] ?? 0) + 1;
      });

      if (completer.isCompleted) _freshFetchFailures.remove(url);

      // Parse collected events on a background isolate for large batches
      if (rawEventJsons.isNotEmpty) {
        final parsed = rawEventJsons.length > 20
            ? await compute(_parseEventsInBackground, rawEventJsons)
            : rawEventJsons.map((j) => NostrEvent.fromJson(j)).toList();
        for (final event in parsed) {
          if (event.id != null) events[event.id!] = event;
        }
      }
    } catch (e) {
      debugPrint('[fetchFresh] $url error: $e');
      _freshFetchFailures[url] = (_freshFetchFailures[url] ?? 0) + 1;
    } finally {
      try { ws?.sink.close(); } catch (_) {}
    }
  }

  /// Reconnect all relays (forces fresh WebSocket connections).
  /// Use before fetching data that relays may have already sent on existing connections.
  Future<void> reconnect() async {
    final urls = _connections.keys.toList();
    debugPrint('[RelayPool] Reconnecting ${urls.length} relays...');
    // Clear all existing state
    for (final url in urls) {
      _connections[url]?.disconnect();
    }
    _connections.clear();
    _subscriptions.clear();
    // Wait for WebSockets to fully close
    await Future.delayed(const Duration(milliseconds: 500));
    // Create brand new connections
    for (final url in urls) {
      await addRelay(url);
    }
    // Wait for connections to establish
    await Future.delayed(const Duration(milliseconds: 500));
    final connected = _connections.values.where((c) => c.isConnected).length;
    debugPrint('[RelayPool] Reconnected: $connected/${urls.length} relays');
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

      // Dispatch handlers asynchronously — don't block the relay stream
      // This lets the WebSocket listener return immediately and process more
      // messages while DB-heavy handlers run in the background.
      final handlers = _kindHandlers[event.kind];
      if (handlers != null) {
        for (final handler in handlers) {
          Future.microtask(() => handler(relayUrl, event));
        }
      }
      for (final handler in _globalHandlers) {
        Future.microtask(() => handler(relayUrl, event));
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
    final reason = message.length > 3 ? message[3] as String? : null;
    if (!success) {
      debugPrint('[RelayPool] OK:false from $relayUrl for $eventId: $reason');
    }
    final key = '$relayUrl:$eventId';
    _publishCompleters[key]?.complete(success);
    _publishCompleters.remove(key);
  }

  void _handleAuthMessage(String relayUrl, List<dynamic> message) {
    if (message.length < 2) return;
    final challenge = message[1] as String;
    onAuthChallenge?.call(relayUrl, challenge);
  }

  /// Send NIP-42 AUTH response to a specific relay (not broadcast)
  void sendAuthToRelay(String relayUrl, NostrEvent authEvent) {
    final conn = _connections[relayUrl];
    if (conn != null && conn.isConnected) {
      conn.sendAuth(authEvent);
    }
  }

  void _handleStateChange(String relayUrl, rc.RelayConnectionState state) {
    // Could emit to a stream for UI consumption
  }
}
