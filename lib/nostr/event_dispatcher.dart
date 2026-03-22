import 'dart:async';
import '../crypto/nostr_event.dart';

typedef NostrEventCallback = void Function(String relayUrl, NostrEvent event);

class NostrEventDispatcher {
  final Map<int, List<NostrEventCallback>> _handlers = {};
  final List<NostrEventCallback> _globalHandlers = [];
  final StreamController<NostrEvent> _eventStreamController =
      StreamController<NostrEvent>.broadcast();

  /// Stream of all incoming events (for reactive UI)
  Stream<NostrEvent> get eventStream => _eventStreamController.stream;

  /// Register a handler for a specific event kind
  void on(int kind, NostrEventCallback callback) {
    _handlers.putIfAbsent(kind, () => []).add(callback);
  }

  /// Register a handler for multiple kinds at once
  void onKinds(List<int> kinds, NostrEventCallback callback) {
    for (final kind in kinds) {
      on(kind, callback);
    }
  }

  /// Register a handler that receives ALL events
  void onAll(NostrEventCallback callback) {
    _globalHandlers.add(callback);
  }

  /// Remove a handler for a specific kind
  void off(int kind, NostrEventCallback callback) {
    _handlers[kind]?.remove(callback);
  }

  /// Remove all handlers for a kind
  void offAll(int kind) {
    _handlers.remove(kind);
  }

  /// Dispatch an event to all registered handlers
  void dispatch(String relayUrl, NostrEvent event) {
    // Kind-specific handlers
    final handlers = _handlers[event.kind];
    if (handlers != null) {
      for (final handler in List.of(handlers)) {
        handler(relayUrl, event);
      }
    }

    // Global handlers
    for (final handler in List.of(_globalHandlers)) {
      handler(relayUrl, event);
    }

    // Stream for reactive listeners
    _eventStreamController.add(event);
  }

  /// Convenience: get a filtered stream for a specific kind
  Stream<NostrEvent> streamForKind(int kind) {
    return eventStream.where((e) => e.kind == kind);
  }

  /// Convenience: get a filtered stream for multiple kinds
  Stream<NostrEvent> streamForKinds(List<int> kinds) {
    final kindSet = kinds.toSet();
    return eventStream.where((e) => kindSet.contains(e.kind));
  }

  void dispose() {
    _eventStreamController.close();
    _handlers.clear();
    _globalHandlers.clear();
  }
}
