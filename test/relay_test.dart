import 'package:flutter_test/flutter_test.dart';
import 'package:inferno/nostr/nostr_filter.dart';
import 'package:inferno/nostr/subscription.dart';
import 'package:inferno/nostr/relay_pool.dart';
import 'package:inferno/nostr/relay_auth.dart';
import 'package:inferno/nostr/event_dispatcher.dart';
import 'package:inferno/crypto/nostr_event.dart';
import 'package:inferno/crypto/nostr_key.dart';
import 'package:inferno/crypto/nostr_verifier.dart';

void main() {
  group('NostrFilter', () {
    test('serializes basic filter', () {
      final filter = NostrFilter(
        kinds: [1, 9],
        authors: ['abc123'],
        since: 1000,
        limit: 50,
      );
      final json = filter.toJson();
      expect(json['kinds'], [1, 9]);
      expect(json['authors'], ['abc123']);
      expect(json['since'], 1000);
      expect(json['limit'], 50);
    });

    test('serializes tag filters', () {
      final filter = NostrFilter.byGroup('my-group', kinds: [9]);
      final json = filter.toJson();
      expect(json['#h'], ['my-group']);
      expect(json['kinds'], [9]);
    });

    test('serializes recipient filter', () {
      final filter = NostrFilter.byRecipient('deadbeef', kinds: [14, 1059]);
      final json = filter.toJson();
      expect(json['#p'], ['deadbeef']);
      expect(json['kinds'], [14, 1059]);
    });

    test('omits null fields', () {
      final filter = NostrFilter(kinds: [0]);
      final json = filter.toJson();
      expect(json.containsKey('authors'), isFalse);
      expect(json.containsKey('since'), isFalse);
      expect(json.containsKey('limit'), isFalse);
    });
  });

  group('Subscription', () {
    test('generates unique IDs', () {
      final sub1 = Subscription(filters: [NostrFilter(kinds: [1])]);
      final sub2 = Subscription(filters: [NostrFilter(kinds: [1])]);
      expect(sub1.id, isNot(sub2.id));
    });

    test('builds REQ message', () {
      final sub = Subscription(
        id: 'test-sub',
        filters: [NostrFilter(kinds: [1], limit: 10)],
      );
      final msg = sub.toReqMessage();
      expect(msg, contains('"REQ"'));
      expect(msg, contains('"test-sub"'));
    });

    test('builds CLOSE message', () {
      final sub = Subscription(
        id: 'test-sub',
        filters: [NostrFilter(kinds: [1])],
      );
      final msg = sub.toCloseMessage();
      expect(msg, contains('CLOSE'));
      expect(msg, contains('test-sub'));
    });
  });

  group('RelayAuth', () {
    test('builds valid NIP-42 auth event', () {
      final key = NostrKey.generate();
      final authEvent = RelayAuth.buildAuthEvent(
        challenge: 'test-challenge-123',
        relayUrl: 'wss://relay.example.com',
        privateKeyHex: key.privateKeyHex,
        publicKeyHex: key.publicKeyHex,
      );

      expect(authEvent.kind, 22242);
      expect(authEvent.pubkey, key.publicKeyHex);
      expect(authEvent.id, isNotNull);
      expect(authEvent.sig, isNotNull);
      expect(authEvent.content, '');

      // Check tags
      final relayTag = authEvent.tags.firstWhere((t) => t[0] == 'relay');
      expect(relayTag[1], 'wss://relay.example.com');

      final challengeTag = authEvent.tags.firstWhere((t) => t[0] == 'challenge');
      expect(challengeTag[1], 'test-challenge-123');

      // Verify signature
      expect(NostrVerifier.verifyEvent(authEvent), isTrue);
    });
  });

  group('EventDispatcher', () {
    test('dispatches to kind-specific handlers', () {
      final dispatcher = NostrEventDispatcher();
      NostrEvent? received;

      dispatcher.on(1, (relayUrl, event) {
        received = event;
      });

      final event = NostrEvent(
        id: 'test',
        pubkey: 'a' * 64,
        createdAt: 1234567890,
        kind: 1,
        tags: [],
        content: 'hello',
      );

      dispatcher.dispatch('wss://relay.test', event);
      expect(received, isNotNull);
      expect(received!.content, 'hello');

      dispatcher.dispose();
    });

    test('does not dispatch to wrong kind handler', () {
      final dispatcher = NostrEventDispatcher();
      bool called = false;

      dispatcher.on(1, (relayUrl, event) {
        called = true;
      });

      final event = NostrEvent(
        id: 'test',
        pubkey: 'a' * 64,
        createdAt: 1234567890,
        kind: 9, // different kind
        tags: [],
        content: 'hello',
      );

      dispatcher.dispatch('wss://relay.test', event);
      expect(called, isFalse);

      dispatcher.dispose();
    });

    test('stream filters by kind', () async {
      final dispatcher = NostrEventDispatcher();
      final events = <NostrEvent>[];

      final sub = dispatcher.streamForKind(9).listen((e) {
        events.add(e);
      });

      dispatcher.dispatch('wss://relay.test', NostrEvent(
        id: 'e1', pubkey: 'a' * 64, createdAt: 1, kind: 1, tags: [], content: 'skip',
      ));
      dispatcher.dispatch('wss://relay.test', NostrEvent(
        id: 'e2', pubkey: 'a' * 64, createdAt: 2, kind: 9, tags: [], content: 'match',
      ));
      dispatcher.dispatch('wss://relay.test', NostrEvent(
        id: 'e3', pubkey: 'a' * 64, createdAt: 3, kind: 9, tags: [], content: 'match2',
      ));

      await Future.delayed(Duration.zero);
      await sub.cancel();

      expect(events.length, 2);
      expect(events[0].content, 'match');
      expect(events[1].content, 'match2');

      dispatcher.dispose();
    });
  });

  group('RelayPool', () {
    test('can be created and stopped', () {
      final pool = RelayPool();
      expect(pool.isRunning, isFalse);
      expect(pool.connectedCount, 0);
      pool.stop();
    });

    // Global handlers are dispatched via Future.microtask (relay_pool.dart:414),
    // so this must await the event queue before asserting — a synchronous
    // expect() here sees an empty list and the dedup is never actually observed.
    test('deduplication prevents double processing', () async {
      final pool = RelayPool();
      final received = <String>[];

      pool.onEvent((relayUrl, event) {
        received.add(event.id!);
      });

      // Simulate two relays sending the same event
      pool.handleRelayMessageForTest('wss://r1', ['EVENT', 'sub1', {
        'id': 'same-id',
        'pubkey': 'a' * 64,
        'created_at': 1234567890,
        'kind': 1,
        'tags': [],
        'content': 'hello',
        'sig': 'b' * 128,
      }]);

      pool.handleRelayMessageForTest('wss://r2', ['EVENT', 'sub1', {
        'id': 'same-id',
        'pubkey': 'a' * 64,
        'created_at': 1234567890,
        'kind': 1,
        'tags': [],
        'content': 'hello',
        'sig': 'b' * 128,
      }]);

      await pumpEventQueue();

      expect(received.length, 1); // Deduplicated
      pool.stop();
    });
  });
}
