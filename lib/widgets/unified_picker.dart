import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../database/database.dart';
import '../providers/database_provider.dart';
import '../theme/all_themes.dart';

/// Unified picker with three tabs: GIFs, Stickers, Emoji
/// Matches Rails unified_picker_controller.js
class UnifiedPicker extends ConsumerStatefulWidget {
  final void Function(String emoji) onEmojiSelect;
  final void Function(String url) onGifSelect;
  final void Function(String url) onStickerSelect;

  const UnifiedPicker({
    super.key,
    required this.onEmojiSelect,
    required this.onGifSelect,
    required this.onStickerSelect,
  });

  @override
  ConsumerState<UnifiedPicker> createState() => _UnifiedPickerState();
}

class _UnifiedPickerState extends ConsumerState<UnifiedPicker> {
  String _tab = 'emoji';
  final _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _searchDebounce;

  // GIF state
  List<Map<String, dynamic>> _gifs = [];
  bool _loadingGifs = false;

  @override
  void dispose() {
    _searchController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onSearch(String query) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      setState(() => _searchQuery = query.toLowerCase());
      if (_tab == 'gifs' && query.isNotEmpty) {
        _searchGifs(query);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<InfernoColors>()!;

    return Container(
      width: 384,
      constraints: const BoxConstraints(maxHeight: 420),
      decoration: BoxDecoration(
        color: c.gray800,
        border: Border.all(color: c.gray700),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 16, offset: const Offset(0, -4))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Tabs
          Container(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.gray700))),
            child: Row(
              children: [
                _TabButton(label: 'GIFs', isActive: _tab == 'gifs', colors: c, onTap: () => setState(() { _tab = 'gifs'; _searchController.clear(); _searchQuery = ''; })),
                _TabButton(label: 'Stickers', isActive: _tab == 'stickers', colors: c, onTap: () => setState(() { _tab = 'stickers'; _searchController.clear(); _searchQuery = ''; })),
                _TabButton(label: 'Emoji', isActive: _tab == 'emoji', colors: c, onTap: () => setState(() { _tab = 'emoji'; _searchController.clear(); _searchQuery = ''; })),
              ],
            ),
          ),
          // Search
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearch,
              style: TextStyle(color: c.gray200, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search...',
                hintStyle: TextStyle(color: c.gray500),
                fillColor: c.gray700,
                filled: true,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                prefixIcon: Icon(Icons.search, size: 16, color: c.gray500),
                prefixIconConstraints: const BoxConstraints(minWidth: 36),
              ),
            ),
          ),
          // Content
          Expanded(
            child: switch (_tab) {
              'gifs' => _buildGifTab(c),
              'stickers' => _buildStickerTab(c),
              _ => _buildEmojiTab(c),
            },
          ),
        ],
      ),
    );
  }

  // ─── Emoji Tab ──────────────────────────────────────────

  static const _emojiCategories = {
    'Smileys': [
      '\u{1F600}', '\u{1F603}', '\u{1F604}', '\u{1F601}', '\u{1F606}', '\u{1F605}',
      '\u{1F602}', '\u{1F923}', '\u{1F642}', '\u{1F643}', '\u{1F609}', '\u{1F60A}',
      '\u{1F607}', '\u{1F970}', '\u{1F60D}', '\u{1F929}', '\u{1F618}', '\u{1F617}',
      '\u{1F619}', '\u{1F61A}', '\u{1F60B}', '\u{1F61B}', '\u{1F61C}', '\u{1F92A}',
      '\u{1F61D}', '\u{1F911}', '\u{1F917}', '\u{1F92D}', '\u{1F92B}', '\u{1F914}',
      '\u{1F910}', '\u{1F928}', '\u{1F610}', '\u{1F611}', '\u{1F636}', '\u{1F60F}',
      '\u{1F612}', '\u{1F644}', '\u{1F62C}', '\u{1F925}', '\u{1F60C}', '\u{1F614}',
      '\u{1F62A}', '\u{1F924}', '\u{1F634}', '\u{1F637}', '\u{1F912}', '\u{1F915}',
      '\u{1F922}', '\u{1F92E}', '\u{1F927}', '\u{1F975}', '\u{1F976}', '\u{1F974}',
      '\u{1F635}', '\u{1F92F}', '\u{1F920}', '\u{1F973}', '\u{1F978}', '\u{1F60E}',
      '\u{1F913}', '\u{1F9D0}', '\u{1F615}', '\u{1F61F}', '\u{1F641}', '\u{1F62E}',
      '\u{1F62F}', '\u{1F632}', '\u{1F633}', '\u{1F97A}', '\u{1F979}',
    ],
    'Gestures': [
      '\u{1F44D}', '\u{1F44E}', '\u{1F44A}', '\u{270A}', '\u{1F91B}', '\u{1F91C}',
      '\u{1F44F}', '\u{1F64C}', '\u{1F450}', '\u{1F932}', '\u{1F91D}', '\u{1F64F}',
      '\u{270D}', '\u{1F485}', '\u{1F933}', '\u{1F4AA}', '\u{1F9BE}', '\u{1F9BF}',
      '\u{1F9B5}', '\u{1F9B6}', '\u{1F442}', '\u{1F443}', '\u{1F9E0}', '\u{1FAC0}',
      '\u{1FAC1}', '\u{1F9B7}', '\u{1F9B4}', '\u{1F440}', '\u{1F441}', '\u{1F445}',
      '\u{1F444}', '\u{1F48B}',
    ],
    'Hearts': [
      '\u{2764}', '\u{1F9E1}', '\u{1F49B}', '\u{1F49A}', '\u{1F499}', '\u{1F49C}',
      '\u{1F5A4}', '\u{1FA76}', '\u{1F90E}', '\u{1F90D}', '\u{1F498}', '\u{1F49D}',
      '\u{1F496}', '\u{1F497}', '\u{1F493}', '\u{1F49E}', '\u{1F495}', '\u{1F49F}',
      '\u{2763}', '\u{1F494}',
    ],
    'Objects': [
      '\u{1F525}', '\u{2B50}', '\u{1F31F}', '\u{1F4AF}', '\u{1F389}', '\u{1F38A}',
      '\u{1F3C6}', '\u{1F3C5}', '\u{1F947}', '\u{1F948}', '\u{1F949}', '\u{26BD}',
      '\u{1F3B5}', '\u{1F3B6}', '\u{1F3A4}', '\u{1F4A1}', '\u{1F4A9}', '\u{1F480}',
      '\u{1F47B}', '\u{1F47D}', '\u{1F916}', '\u{1F4AC}', '\u{1F4A4}', '\u{1F4A2}',
      '\u{2705}', '\u{274C}', '\u{2753}', '\u{2757}', '\u{26A0}', '\u{1F6A9}',
      '\u{1F680}', '\u{1F30D}', '\u{1F308}', '\u{2600}', '\u{1F319}',
    ],
  };

  Widget _buildEmojiTab(InfernoColors c) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      children: [
        for (final entry in _emojiCategories.entries) ...[
          // Filter by search
          if (_searchQuery.isEmpty || entry.value.any((e) => e.contains(_searchQuery)))
            _buildEmojiSection(entry.key, entry.value, c),
        ],
        // Custom server emojis
        _buildServerEmojisSection(c),
      ],
    );
  }

  Widget _buildEmojiSection(String title, List<String> emojis, InfernoColors c) {
    final filtered = _searchQuery.isEmpty ? emojis : emojis;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4, left: 4),
          child: Text(title.toUpperCase(), style: TextStyle(color: c.gray500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
        ),
        Wrap(
          children: filtered.map((emoji) => _EmojiButton(
            emoji: emoji,
            onTap: () => widget.onEmojiSelect(emoji),
          )).toList(),
        ),
      ],
    );
  }

  Widget _buildServerEmojisSection(InfernoColors c) {
    final db = ref.watch(databaseProvider);
    return StreamBuilder<List<Server>>(
      stream: db.select(db.servers).watch(),
      builder: (context, serverSnap) {
        final servers = serverSnap.data ?? [];
        if (servers.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: servers.map((server) => _ServerEmojiSection(
            server: server,
            searchQuery: _searchQuery,
            colors: c,
            onSelect: (name, url) => widget.onEmojiSelect(':$name:'),
          )).toList(),
        );
      },
    );
  }

  // ─── GIF Tab ──────────────────────────────────────────

  Future<void> _searchGifs(String query) async {
    setState(() => _loadingGifs = true);
    // Note: In production, this would proxy through your own server
    // or use a Tenor API key. For now, show a placeholder.
    setState(() {
      _gifs = [];
      _loadingGifs = false;
    });
  }

  Widget _buildGifTab(InfernoColors c) {
    if (_loadingGifs) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchQuery.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.gif_box_outlined, size: 48, color: c.gray500),
            const SizedBox(height: 12),
            Text('Search for GIFs', style: TextStyle(color: c.gray400, fontSize: 14)),
            Text('Type to search Tenor', style: TextStyle(color: c.gray500, fontSize: 12)),
          ],
        ),
      );
    }
    if (_gifs.isEmpty) {
      return Center(
        child: Text('No GIFs found', style: TextStyle(color: c.gray500, fontSize: 14)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 4, mainAxisSpacing: 4),
      itemCount: _gifs.length,
      itemBuilder: (context, index) {
        final gif = _gifs[index];
        return GestureDetector(
          onTap: () => widget.onGifSelect(gif['url'] as String),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.network(gif['preview'] as String, fit: BoxFit.cover),
          ),
        );
      },
    );
  }

  // ─── Sticker Tab ──────────────────────────────────────

  Widget _buildStickerTab(InfernoColors c) {
    final db = ref.watch(databaseProvider);
    return StreamBuilder<List<Server>>(
      stream: db.select(db.servers).watch(),
      builder: (context, serverSnap) {
        final servers = serverSnap.data ?? [];
        if (servers.isEmpty) {
          return Center(child: Text('No stickers available', style: TextStyle(color: c.gray500, fontSize: 14)));
        }
        return ListView(
          padding: const EdgeInsets.all(8),
          children: servers.map((server) => _ServerStickerSection(
            server: server,
            searchQuery: _searchQuery,
            colors: c,
            onSelect: (url) => widget.onStickerSelect(url),
          )).toList(),
        );
      },
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool isActive;
  final InfernoColors colors;
  final VoidCallback onTap;
  const _TabButton({required this.label, required this.isActive, required this.colors, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(
              color: isActive ? colors.accent : Colors.transparent,
              width: 2,
            )),
          ),
          child: Center(
            child: Text(label, style: TextStyle(
              color: isActive ? Colors.white : colors.gray400,
              fontSize: 13, fontWeight: FontWeight.w600,
            )),
          ),
        ),
      ),
    );
  }
}

class _EmojiButton extends StatefulWidget {
  final String emoji;
  final VoidCallback onTap;
  const _EmojiButton({required this.emoji, required this.onTap});

  @override
  State<_EmojiButton> createState() => _EmojiButtonState();
}

class _EmojiButtonState extends State<_EmojiButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: _hovering ? const Color(0xFF404040) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Center(child: Text(widget.emoji, style: const TextStyle(fontSize: 22))),
        ),
      ),
    );
  }
}

class _ServerEmojiSection extends ConsumerWidget {
  final Server server;
  final String searchQuery;
  final InfernoColors colors;
  final void Function(String name, String url) onSelect;

  const _ServerEmojiSection({required this.server, required this.searchQuery, required this.colors, required this.onSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    return StreamBuilder<List<ServerEmoji>>(
      stream: (db.select(db.serverEmojis)..where((e) => e.serverId.equals(server.id))).watch(),
      builder: (context, snap) {
        var emojis = snap.data ?? [];
        if (emojis.isEmpty) return const SizedBox.shrink();
        if (searchQuery.isNotEmpty) {
          emojis = emojis.where((e) => e.name.toLowerCase().contains(searchQuery)).toList();
          if (emojis.isEmpty) return const SizedBox.shrink();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4, left: 4),
              child: Text(server.name.toUpperCase(), style: TextStyle(color: colors.gray500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
            ),
            Wrap(
              children: emojis.map((emoji) => Tooltip(
                message: ':${emoji.name}:',
                child: GestureDetector(
                  onTap: () => onSelect(emoji.name, emoji.url ?? ''),
                  child: Container(
                    width: 36, height: 36,
                    padding: const EdgeInsets.all(4),
                    child: emoji.url != null
                        ? Image.network(emoji.url!, width: 24, height: 24)
                        : Text(emoji.name[0], style: TextStyle(color: colors.gray200)),
                  ),
                ),
              )).toList(),
            ),
          ],
        );
      },
    );
  }
}

class _ServerStickerSection extends ConsumerWidget {
  final Server server;
  final String searchQuery;
  final InfernoColors colors;
  final void Function(String url) onSelect;

  const _ServerStickerSection({required this.server, required this.searchQuery, required this.colors, required this.onSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    return StreamBuilder<List<ServerSticker>>(
      stream: (db.select(db.serverStickers)..where((s) => s.serverId.equals(server.id))).watch(),
      builder: (context, snap) {
        var stickers = snap.data ?? [];
        if (stickers.isEmpty) return const SizedBox.shrink();
        if (searchQuery.isNotEmpty) {
          stickers = stickers.where((s) => s.name.toLowerCase().contains(searchQuery)).toList();
          if (stickers.isEmpty) return const SizedBox.shrink();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4, left: 4),
              child: Text(server.name.toUpperCase(), style: TextStyle(color: colors.gray500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
            ),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 3,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
              children: stickers.map((sticker) => GestureDetector(
                onTap: () => onSelect(sticker.url ?? ''),
                child: Container(
                  decoration: BoxDecoration(
                    color: colors.gray700,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.all(4),
                  child: sticker.url != null
                      ? Image.network(sticker.url!, fit: BoxFit.contain)
                      : Center(child: Text(sticker.name, style: TextStyle(color: colors.gray400, fontSize: 11))),
                ),
              )).toList(),
            ),
          ],
        );
      },
    );
  }
}
