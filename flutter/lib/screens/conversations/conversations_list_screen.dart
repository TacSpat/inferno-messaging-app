import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/conversations_provider.dart';
import '../../providers/auth_provider.dart';
import '../../database/database.dart';
import '../../providers/database_provider.dart';
import '../../theme/all_themes.dart';
import '../../theme/theme_provider.dart';
import '../../providers/realtime_provider.dart';
import '../../services/presence_service.dart';
import '../../nostr/nostr_filter.dart';
import '../../crypto/bech32_nostr.dart';
import 'package:drift/drift.dart' show Value;
import 'package:http/http.dart' as http;

class ConversationsListScreen extends ConsumerStatefulWidget {
  final String? initialTab;
  const ConversationsListScreen({super.key, this.initialTab});

  @override
  ConsumerState<ConversationsListScreen> createState() => _ConversationsListScreenState();
}

class _ConversationsListScreenState extends ConsumerState<ConversationsListScreen> {
  late String _tab = widget.initialTab ?? 'all';

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);

    return Material(
      color: c.gray700,
      child: Column(
      children: [
        // Header
        Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.gray900)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(Icons.person, size: 20, color: c.gray400),
                    const SizedBox(width: 8),
                    Text('Contacts', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                child: Row(
                  children: [
                    _TabPill('Online', 'online', c),
                    const SizedBox(width: 4),
                    _TabPill('All', 'all', c),
                    const SizedBox(width: 4),
                    _TabPill('Pending', 'pending', c),
                    const SizedBox(width: 4),
                    _TabPill('Blocked', 'blocked', c),
                    const SizedBox(width: 4),
                    _TabPill('Search', 'search', c, isSearch: true),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(child: _buildTabContent(c)),
      ],
    ),
    );
  }

  Widget _TabPill(String label, String tab, InfernoColors c, {bool isSearch = false}) {
    final active = _tab == tab;
    return GestureDetector(
      onTap: () => setState(() => _tab = tab),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: isSearch
                ? (active ? const Color(0xFF16A34A) : const Color(0xFF16A34A).withValues(alpha: 0.8))
                : (active ? c.gray600 : Colors.transparent),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(label, style: TextStyle(
            color: active || isSearch ? Colors.white : c.gray400,
            fontSize: 14, fontWeight: FontWeight.w500,
          )),
        ),
      ),
    );
  }

  Widget _buildTabContent(InfernoColors c) {
    switch (_tab) {
      case 'search':
        return _SearchTab(colors: c);
      case 'pending':
        return _PendingTab(colors: c);
      case 'blocked':
        return _BlockedTab(colors: c);
      default:
        return _ContactsTab(tab: _tab, colors: c);
    }
  }
}

class _ContactsTab extends ConsumerWidget {
  final String tab;
  final InfernoColors colors;
  const _ContactsTab({required this.tab, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final friendsAsync = ref.watch(friendsStreamProvider);
    final presenceSvc = ref.watch(presenceServiceProvider);

    return friendsAsync.when(
      data: (allContacts) {
        // Filter by online status if on the Online tab
        final contacts = tab == 'online'
            ? allContacts.where((c) => presenceSvc.getPresence(c.pubkey) != OnlineState.offline).toList()
            : allContacts;

        if (contacts.isEmpty) {
          return _EmptyState(
            icon: Icons.people_outline,
            text: tab == 'online'
                ? "No contacts are online right now."
                : "You don't have any contacts yet. Add some!",
            colors: colors,
          );
        }
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 8),
              child: Text(
                '${tab == 'online' ? 'ONLINE' : 'ALL CONTACTS'} \u2014 ${contacts.length}',
                style: TextStyle(color: colors.gray400, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5),
              ),
            ),
            ...contacts.map((contact) => _ContactItem(
              contact: contact,
              colors: colors,
              presenceState: presenceSvc.getPresence(contact.pubkey),
              onTap: () async {
                // Open or create a DM conversation
                final db = ref.read(databaseProvider);
                var conv = await db.contactsDao.getConversationByPubkey(contact.pubkey);
                if (conv == null) {
                  final now = DateTime.now();
                  final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
                  await db.contactsDao.insertConversation(ConversationsCompanion.insert(
                    publicId: publicId,
                    kind: const Value(0),
                    counterpartyPubkey: Value(contact.pubkey),
                    counterpartyDisplayName: Value(contact.displayName ?? contact.username),
                    createdAt: now,
                    updatedAt: now,
                  ));
                  conv = await db.contactsDao.getConversationByPubkey(contact.pubkey);
                }
                if (conv != null && context.mounted) {
                  GoRouter.of(context).go('/conversations/${conv.publicId}');
                }
              },
              onRemove: () async {
                final contactService = ref.read(contactServiceProvider);
                await contactService.removeContact(contact.pubkey);
              },
            )),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
    );
  }
}

class _ContactItem extends StatefulWidget {
  final Contact contact;
  final InfernoColors colors;
  final OnlineState presenceState;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  const _ContactItem({required this.contact, required this.colors, this.presenceState = OnlineState.offline, this.onTap, this.onRemove});

  @override
  State<_ContactItem> createState() => _ContactItemState();
}

class _ContactItemState extends State<_ContactItem> {
  bool _hovering = false;

  static Color _presenceColor(OnlineState state, InfernoColors c) {
    switch (state) {
      case OnlineState.online: return c.online;
      case OnlineState.idle: return c.idle;
      case OnlineState.dnd: return c.dnd;
      default: return c.offline;
    }
  }

  static String _presenceLabel(OnlineState state) {
    switch (state) {
      case OnlineState.online: return 'Online';
      case OnlineState.idle: return 'Idle';
      case OnlineState.dnd: return 'Do Not Disturb';
      default: return 'Offline';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final contact = widget.contact;
    final name = contact.displayName ?? contact.username ?? '${contact.pubkey.substring(0, 12)}...';

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            gradient: _hovering ? LinearGradient(colors: [c.accent.withValues(alpha: 0.08), Colors.transparent]) : null,
            borderRadius: BorderRadius.circular(4),
            border: Border(bottom: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
          ),
          child: Row(
            children: [
              Stack(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: c.gray600,
                    backgroundImage: contact.avatarUrl != null ? NetworkImage(contact.avatarUrl!) : null,
                    child: contact.avatarUrl == null
                        ? Text(name[0].toUpperCase(), style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.bold))
                        : null,
                  ),
                  Positioned(
                    right: -1, bottom: -1,
                    child: Container(
                      width: 14, height: 14,
                      decoration: BoxDecoration(
                        color: _presenceColor(widget.presenceState, c),
                        shape: BoxShape.circle,
                        border: Border.all(color: c.gray700, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
                    Text(_presenceLabel(widget.presenceState), style: TextStyle(color: c.gray400, fontSize: 12)),
                  ],
                ),
              ),
              if (_hovering && widget.onRemove != null)
                GestureDetector(
                  onTap: widget.onRemove,
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(color: c.gray700, shape: BoxShape.circle),
                    child: Icon(Icons.close, size: 20, color: c.gray400),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PendingTab extends ConsumerWidget {
  final InfernoColors colors;
  const _PendingTab({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pendingAsync = ref.watch(pendingRequestsStreamProvider);
    return pendingAsync.when(
      data: (pending) {
        if (pending.isEmpty) {
          return _EmptyState(icon: Icons.people_outline, text: 'There are no pending friend requests.', colors: colors);
        }
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 8),
              child: Text('INCOMING \u2014 ${pending.length}',
                style: TextStyle(color: colors.gray400, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
            ),
            ...pending.map((contact) {
              final name = contact.displayName ?? contact.username ?? '${contact.pubkey.substring(0, 12)}...';
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: colors.gray700.withValues(alpha: 0.5))),
                ),
                child: Row(
                  children: [
                    CircleAvatar(radius: 18, backgroundColor: colors.gray600,
                      child: Text(name[0].toUpperCase(), style: TextStyle(color: colors.gray200, fontSize: 14, fontWeight: FontWeight.bold))),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name, style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
                          Text('Incoming Friend Request', style: TextStyle(color: colors.gray400, fontSize: 12)),
                        ],
                      ),
                    ),
                    GestureDetector(
                      onTap: () async {
                        final dmService = ref.read(dmServiceProvider);
                        final auth = ref.read(authServiceProvider);
                        if (auth.privateKeyHex == null || auth.publicKeyHex == null) return;
                        await dmService.sendFriendResponse(
                          privateKeyHex: auth.privateKeyHex!,
                          publicKeyHex: auth.publicKeyHex!,
                          recipientPubkey: contact.pubkey,
                          status: 'accepted',
                        );
                      },
                      child: Container(
                        width: 36, height: 36, margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(color: colors.gray700, shape: BoxShape.circle),
                        child: Icon(Icons.check, size: 20, color: colors.online),
                      ),
                    ),
                    GestureDetector(
                      onTap: () async {
                        final dmService = ref.read(dmServiceProvider);
                        final auth = ref.read(authServiceProvider);
                        if (auth.privateKeyHex == null || auth.publicKeyHex == null) return;
                        await dmService.sendFriendResponse(
                          privateKeyHex: auth.privateKeyHex!,
                          publicKeyHex: auth.publicKeyHex!,
                          recipientPubkey: contact.pubkey,
                          status: 'declined',
                        );
                      },
                      child: Container(
                        width: 36, height: 36,
                        decoration: BoxDecoration(color: colors.gray700, shape: BoxShape.circle),
                        child: Icon(Icons.close, size: 20, color: colors.accent),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
    );
  }
}

class _BlockedTab extends ConsumerWidget {
  final InfernoColors colors;
  const _BlockedTab({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blockedAsync = ref.watch(blockedContactsStreamProvider);
    return blockedAsync.when(
      data: (blocked) {
        if (blocked.isEmpty) {
          return _EmptyState(icon: Icons.block, text: "You haven't blocked anyone.", colors: colors);
        }
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 8),
              child: Text('BLOCKED \u2014 ${blocked.length}',
                style: TextStyle(color: colors.gray400, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
            ),
            ...blocked.map((contact) {
              final name = contact.displayName ?? contact.username ?? '${contact.pubkey.substring(0, 12)}...';
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: colors.gray700.withValues(alpha: 0.5))),
                ),
                child: Row(
                  children: [
                    CircleAvatar(radius: 18, backgroundColor: colors.gray600,
                      child: Text(name[0].toUpperCase(), style: TextStyle(color: colors.gray200, fontSize: 14, fontWeight: FontWeight.bold))),
                    const SizedBox(width: 12),
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
                        Text('Blocked', style: TextStyle(color: colors.gray400, fontSize: 12)),
                      ],
                    )),
                    GestureDetector(
                      onTap: () async {
                        final contactService = ref.read(contactServiceProvider);
                        await contactService.unblockContact(contact.pubkey);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: colors.gray700, borderRadius: BorderRadius.circular(4)),
                        child: Text('Unblock', style: TextStyle(color: colors.gray400, fontSize: 13)),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
    );
  }
}

/// Search tab — matches Rails NostrSearchService logic:
/// 1. npub → direct resolve
/// 2. hex pubkey → direct resolve
/// 3. user@domain → NIP-05 resolution
/// 4. text → NIP-50 relay search
class _SearchTab extends ConsumerStatefulWidget {
  final InfernoColors colors;
  const _SearchTab({required this.colors});

  @override
  ConsumerState<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends ConsumerState<_SearchTab> {
  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(query));
  }

  Future<void> _search(String query) async {
    query = query.trim();
    if (query.length < 2) {
      setState(() => _results = []);
      return;
    }
    setState(() => _searching = true);

    final pool = ref.read(relayPoolProvider);
    final auth = ref.read(authServiceProvider);
    final db = ref.read(databaseProvider);
    final results = <String, Map<String, dynamic>>{}; // dedup by pubkey

    try {
      // 1. If npub, resolve directly
      if (query.startsWith('npub1')) {
        try {
          final pubkey = Bech32Nostr.npubDecode(query);
          await _resolveAndAdd(results, pubkey, pool);
          if (mounted) setState(() { _results = _finalize(results, auth, db); _searching = false; });
          return;
        } catch (_) {}
      }

      // 2. If hex pubkey (64 hex chars), resolve directly
      if (RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(query)) {
        await _resolveAndAdd(results, query.toLowerCase(), pool);
        if (mounted) setState(() { _results = _finalize(results, auth, db); _searching = false; });
        return;
      }

      // 3. If NIP-05 (contains @), try resolution
      if (query.contains('@')) {
        await _resolveNip05(results, query);
      }

      // 4. NIP-50 search on relays
      final filter = NostrFilter(kinds: [0], search: query, limit: 20);
      final events = await pool.fetch(filter, timeout: const Duration(seconds: 8));
      for (final event in events) {
        _parseKind0(results, event.pubkey, event.content);
      }

      // 5. Also search local contacts DB
      final lowerQuery = query.toLowerCase();
      final localContacts = await db.select(db.contacts).get();
      final matchedContacts = localContacts.where((c) =>
          (c.username ?? '').toLowerCase().contains(lowerQuery) ||
          (c.displayName ?? '').toLowerCase().contains(lowerQuery) ||
          (c.nip05 ?? '').toLowerCase().contains(lowerQuery) ||
          c.pubkey.toLowerCase().contains(lowerQuery));
      for (final c in matchedContacts) {
        if (!results.containsKey(c.pubkey)) {
          results[c.pubkey] = {
            'pubkey': c.pubkey,
            'name': c.displayName ?? c.username ?? '${c.pubkey.substring(0, 12)}...',
            'nip05': c.nip05,
            'picture': c.avatarUrl,
            'npub': Bech32Nostr.npubEncode(c.pubkey),
          };
        }
      }
    } catch (_) {}

    if (mounted) setState(() { _results = _finalize(results, auth, db); _searching = false; });
  }

  Future<void> _resolveAndAdd(Map<String, Map<String, dynamic>> results, String pubkey, dynamic pool) async {
    final filter = NostrFilter(kinds: [0], authors: [pubkey], limit: 1);
    final events = await pool.fetch(filter, timeout: const Duration(seconds: 10));
    if (events.isNotEmpty) {
      _parseKind0(results, pubkey, events.first.content);
    } else {
      // Minimal result even without metadata
      results[pubkey] = {
        'pubkey': pubkey,
        'name': '${pubkey.substring(0, 12)}...',
        'nip05': null,
        'picture': null,
        'npub': Bech32Nostr.npubEncode(pubkey),
      };
    }
  }

  void _parseKind0(Map<String, Map<String, dynamic>> results, String pubkey, String content) {
    try {
      final profile = jsonDecode(content) as Map<String, dynamic>;
      results[pubkey] = {
        'pubkey': pubkey,
        'name': profile['display_name'] ?? profile['name'] ?? '${pubkey.substring(0, 12)}...',
        'nip05': profile['nip05'],
        'picture': profile['picture'],
        'npub': Bech32Nostr.npubEncode(pubkey),
      };
    } catch (_) {
      results[pubkey] ??= {
        'pubkey': pubkey,
        'name': '${pubkey.substring(0, 12)}...',
        'nip05': null,
        'picture': null,
        'npub': Bech32Nostr.npubEncode(pubkey),
      };
    }
  }

  Future<void> _resolveNip05(Map<String, Map<String, dynamic>> results, String identifier) async {
    final parts = identifier.split('@');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return;

    final name = parts[0];
    final domain = parts[1];

    try {
      final url = Uri.parse('https://$domain/.well-known/nostr.json?name=${Uri.encodeComponent(name)}');
      final response = await http.get(url).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final names = data['names'] as Map<String, dynamic>?;
      if (names == null) return;

      final pubkey = (names[name] ?? names[name.toLowerCase()]) as String?;
      if (pubkey == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(pubkey)) return;

      // Fetch the full profile
      final pool = ref.read(relayPoolProvider);
      await _resolveAndAdd(results, pubkey, pool);
    } catch (_) {}
  }

  List<Map<String, dynamic>> _finalize(Map<String, Map<String, dynamic>> results, dynamic auth, dynamic db) {
    final ownPubkey = auth.publicKeyHex;
    return results.values.where((r) => r['pubkey'] != ownPubkey).toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Find People', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
        const SizedBox(height: 4),
        Text('Search by name, npub, hex public key, or NIP-05 address (user@domain).',
          style: TextStyle(color: c.gray400, fontSize: 14)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: c.gray900,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.gray700),
          ),
          child: Row(
            children: [
              Icon(Icons.search, size: 20, color: c.gray500),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  onChanged: _onSearchChanged,
                  onSubmitted: _search,
                  style: TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'npub1..., hex key, alice@example.com, or name...',
                    hintStyle: TextStyle(color: c.gray500),
                    border: InputBorder.none,
                    filled: false,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
              if (_searching)
                SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: c.gray400)),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text('Searches relays via NIP-50. Direct lookup for npub, hex keys, and NIP-05 addresses.',
          style: TextStyle(color: c.gray500, fontSize: 11)),
        const SizedBox(height: 8),
        ..._results.map((r) => _SearchResultItem(result: r, colors: c, ref: ref)),
      ],
    );
  }
}

class _SearchResultItem extends StatefulWidget {
  final Map<String, dynamic> result;
  final InfernoColors colors;
  final WidgetRef ref;
  const _SearchResultItem({required this.result, required this.colors, required this.ref});

  @override
  State<_SearchResultItem> createState() => _SearchResultItemState();
}

class _SearchResultItemState extends State<_SearchResultItem> {
  String _buttonState = 'add'; // add, sending, sent, friend, pending

  @override
  void initState() {
    super.initState();
    _checkContactStatus();
  }

  Future<void> _checkContactStatus() async {
    final db = widget.ref.read(databaseProvider);
    final contact = await db.contactsDao.getByPubkey(widget.result['pubkey']);
    if (contact == null || !mounted) return;
    setState(() {
      switch (contact.friendshipStatus) {
        case 3: _buttonState = 'friend';
        case 1: _buttonState = 'pending';
        case 2: _buttonState = 'respond';
        default: _buttonState = 'add';
      }
    });
  }

  Future<void> _addFriend() async {
    setState(() => _buttonState = 'sending');
    try {
      final auth = widget.ref.read(authServiceProvider);
      final dmService = widget.ref.read(dmServiceProvider);
      final contactService = widget.ref.read(contactServiceProvider);

      // Add contact locally
      await contactService.addContact(widget.result['pubkey']);

      // Send friend request via encrypted DM
      if (auth.privateKeyHex != null && auth.publicKeyHex != null) {
        await dmService.sendFriendRequest(
          privateKeyHex: auth.privateKeyHex!,
          publicKeyHex: auth.publicKeyHex!,
          recipientPubkey: widget.result['pubkey'],
        );
        // Update friendship status to pending_outgoing
        final db = widget.ref.read(databaseProvider);
        await (db.update(db.contacts)..where((c) => c.pubkey.equals(widget.result['pubkey'])))
            .write(ContactsCompanion(friendshipStatus: const Value(1), updatedAt: Value(DateTime.now())));
      }

      if (mounted) setState(() => _buttonState = 'sent');
    } catch (_) {
      if (mounted) {
        setState(() => _buttonState = 'add');
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _buttonState = 'add');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final r = widget.result;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: c.gray600,
            backgroundImage: r['picture'] != null ? NetworkImage(r['picture']) : null,
            child: r['picture'] == null
                ? Text((r['name'] ?? '?')[0].toUpperCase(), style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.bold))
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r['name'] ?? 'Unknown', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
                Text(
                  r['nip05'] ?? _truncateNpub(r['npub'] ?? ''),
                  style: TextStyle(color: c.gray500, fontSize: 12),
                ),
              ],
            ),
          ),
          _buildActionButton(c),
        ],
      ),
    );
  }

  String _truncateNpub(String npub) {
    if (npub.length < 20) return npub;
    return '${npub.substring(0, 16)}...${npub.substring(npub.length - 5)}';
  }

  Widget _buildActionButton(InfernoColors c) {
    switch (_buttonState) {
      case 'friend':
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: const Color(0xFF16A34A).withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)),
          child: const Text('Added', style: TextStyle(color: Color(0xFF16A34A), fontSize: 13, fontWeight: FontWeight.w600)),
        );
      case 'pending':
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: c.idle.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)),
          child: Text('Pending', style: TextStyle(color: c.idle, fontSize: 13, fontWeight: FontWeight.w600)),
        );
      case 'respond':
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: const Color(0xFF2563EB).withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)),
          child: const Text('Respond', style: TextStyle(color: Color(0xFF2563EB), fontSize: 13, fontWeight: FontWeight.w600)),
        );
      case 'sending':
        return SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: c.gray400));
      case 'sent':
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: c.idle.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)),
          child: Text('Sent', style: TextStyle(color: c.idle, fontSize: 13, fontWeight: FontWeight.w600)),
        );
      default:
        return GestureDetector(
          onTap: _addFriend,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(color: const Color(0xFF16A34A), borderRadius: BorderRadius.circular(4)),
            child: const Text('Add', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        );
    }
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  final InfernoColors colors;
  const _EmptyState({required this.icon, required this.text, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: colors.gray600),
          const SizedBox(height: 16),
          Text(text, style: TextStyle(color: colors.gray400, fontSize: 14)),
        ],
      ),
    );
  }
}
