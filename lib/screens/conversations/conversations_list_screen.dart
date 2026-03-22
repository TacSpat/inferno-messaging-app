import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/conversations_provider.dart';
import '../../providers/auth_provider.dart';
import '../../database/database.dart';
import '../../theme/all_themes.dart';
import '../../nostr/nostr_filter.dart';
import '../../crypto/bech32_nostr.dart';

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
    final c = Theme.of(context).extension<InfernoColors>()!;

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
              // Title bar
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
              // Tabs
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
        // Tab content
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
    return friendsAsync.when(
      data: (contacts) {
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
  final VoidCallback? onRemove;
  const _ContactItem({required this.contact, required this.colors, this.onRemove});

  @override
  State<_ContactItem> createState() => _ContactItemState();
}

class _ContactItemState extends State<_ContactItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final contact = widget.contact;
    final name = contact.displayName ?? contact.username ?? '${contact.pubkey.substring(0, 12)}...';

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: _hovering ? c.gray600.withValues(alpha: 0.3) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border(bottom: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
        ),
        child: Row(
          children: [
            // Avatar with status dot
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
                      color: c.offline, // TODO: use actual presence
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
                  Text('Offline', style: TextStyle(color: c.gray400, fontSize: 12)),
                ],
              ),
            ),
            // Remove button (hover only)
            if (_hovering)
              GestureDetector(
                onTap: widget.onRemove,
                child: Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: c.gray700,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.close, size: 20, color: c.gray400),
                ),
              ),
          ],
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
                    // Accept
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
                    // Decline
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

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().length < 2) {
      setState(() => _results = []);
      return;
    }
    setState(() => _searching = true);

    // Search relays for Kind 0 profiles matching the query
    final pool = ref.read(relayPoolProvider);
    final filter = NostrFilter(kinds: [0], limit: 20);
    final events = await pool.fetch(filter, timeout: const Duration(seconds: 8));

    final results = <Map<String, dynamic>>[];
    for (final event in events) {
      try {
        final profile = jsonDecode(event.content) as Map<String, dynamic>;
        final name = (profile['name'] ?? profile['display_name'] ?? '').toString().toLowerCase();
        final nip05 = (profile['nip05'] ?? '').toString().toLowerCase();
        if (name.contains(query.toLowerCase()) || nip05.contains(query.toLowerCase()) || event.pubkey.contains(query.toLowerCase())) {
          results.add({
            'pubkey': event.pubkey,
            'name': profile['display_name'] ?? profile['name'] ?? '${event.pubkey.substring(0, 12)}...',
            'nip05': profile['nip05'],
            'picture': profile['picture'],
            'npub': Bech32Nostr.npubEncode(event.pubkey),
          });
        }
      } catch (_) {}
    }

    if (mounted) setState(() { _results = results; _searching = false; });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Find People', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
        const SizedBox(height: 4),
        Text('Search by name, public key, or address (user@domain).',
          style: TextStyle(color: c.gray400, fontSize: 14)),
        const SizedBox(height: 12),
        // Search input
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
                  onChanged: _search,
                  style: TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Search by name, public key, or user@domain...',
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
        Text('Searches relays for matching profiles. Try a name, public key, or alice@example.com',
          style: TextStyle(color: c.gray500, fontSize: 11)),
        const SizedBox(height: 8),
        // Results
        ..._results.map((r) => Container(
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
                      r['nip05'] ?? '${(r['npub'] as String).substring(0, 16)}...${(r['npub'] as String).substring((r['npub'] as String).length - 5)}',
                      style: TextStyle(color: c.gray500, fontSize: 12),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () {
                  final contactService = ref.read(contactServiceProvider);
                  contactService.addContact(r['pubkey']);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Added ${r['name']}')),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF16A34A),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('Add', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        )),
      ],
    );
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
