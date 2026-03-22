import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../crypto/nostr_event.dart';
import 'subscription.dart';

enum RelayConnectionState { disconnected, connecting, connected, error }

class RelayConnection {
  final String url;
  final void Function(String relayUrl, List<dynamic> message)? onMessage;
  final void Function(String relayUrl, RelayConnectionState state)? onStateChange;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  RelayConnectionState _state = RelayConnectionState.disconnected;
  int _retryCount = 0;
  Timer? _reconnectTimer;
  DateTime? _lastConnectedAt;
  String? _lastError;

  // Active subscriptions on this relay
  final Map<String, Subscription> _subscriptions = {};

  RelayConnection({
    required this.url,
    this.onMessage,
    this.onStateChange,
  });

  RelayConnectionState get state => _state;
  int get retryCount => _retryCount;
  DateTime? get lastConnectedAt => _lastConnectedAt;
  String? get lastError => _lastError;
  bool get isConnected => _state == RelayConnectionState.connected;

  /// Connect to the relay
  Future<void> connect() async {
    if (_state == RelayConnectionState.connecting || _state == RelayConnectionState.connected) {
      return;
    }
    _setState(RelayConnectionState.connecting);

    try {
      final uri = Uri.parse(url);
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;

      _setState(RelayConnectionState.connected);
      _lastConnectedAt = DateTime.now();
      _retryCount = 0;
      _lastError = null;

      // Re-subscribe all active subscriptions
      for (final sub in _subscriptions.values) {
        _channel!.sink.add(sub.toReqMessage());
      }

      // Listen for incoming messages
      _subscription = _channel!.stream.listen(
        _handleMessage,
        onError: (error) {
          _lastError = error.toString();
          _setState(RelayConnectionState.error);
          _scheduleReconnect();
        },
        onDone: () {
          _setState(RelayConnectionState.disconnected);
          _scheduleReconnect();
        },
        cancelOnError: false,
      );
    } catch (e) {
      _lastError = e.toString();
      _setState(RelayConnectionState.error);
      _scheduleReconnect();
    }
  }

  /// Disconnect from the relay
  void disconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _setState(RelayConnectionState.disconnected);
  }

  /// Send a raw string message
  void send(String message) {
    if (_state != RelayConnectionState.connected || _channel == null) return;
    try {
      _channel!.sink.add(message);
    } catch (e) {
      _lastError = e.toString();
    }
  }

  /// Send a signed event to this relay
  void sendEvent(NostrEvent event) {
    send(json.encode(['EVENT', event.toJson()]));
  }

  /// Add a subscription to this relay
  void subscribe(Subscription sub) {
    _subscriptions[sub.id] = sub;
    if (isConnected) {
      send(sub.toReqMessage());
    }
  }

  /// Remove a subscription from this relay
  void unsubscribe(String subscriptionId) {
    final sub = _subscriptions.remove(subscriptionId);
    if (sub != null && isConnected) {
      send(sub.toCloseMessage());
    }
  }

  /// Remove all subscriptions
  void clearSubscriptions() {
    for (final subId in _subscriptions.keys.toList()) {
      unsubscribe(subId);
    }
  }

  void _handleMessage(dynamic rawMessage) {
    try {
      final data = json.decode(rawMessage as String);
      if (data is! List || data.isEmpty) return;
      onMessage?.call(url, data);
    } catch (_) {}
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _retryCount++;
    // Exponential backoff: 1s, 2s, 4s, 8s, 16s, max 60s
    final delay = Duration(seconds: min(60, pow(2, min(_retryCount - 1, 5)).toInt()));
    _reconnectTimer = Timer(delay, () => connect());
  }

  void _setState(RelayConnectionState newState) {
    if (_state == newState) return;
    _state = newState;
    onStateChange?.call(url, newState);
  }
}
