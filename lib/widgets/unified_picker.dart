import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';
import '../services/gif_service.dart';
import '../services/gif_favorites_service.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme/all_themes.dart';
import '../theme/theme_provider.dart';
import 'context_menu.dart';

const _frequentKey = 'unified_picker_frequently_used';
const _maxFrequent = 24;
const _lastTabKey = 'unified_picker_last_tab';

/// Unified picker with three tabs: GIFs, Stickers, Emoji
/// Matches Rails unified_picker_controller.js
class UnifiedPicker extends ConsumerStatefulWidget {
  final void Function(String emoji) onEmojiSelect;
  final void Function(String url)? onGifSelect;
  final void Function(String url)? onStickerSelect;
  /// Custom emoji map: name -> url (for collection icon picker)
  final Map<String, String> customEmojis;
  /// When true, show only the emoji tab with no tab bar (for reaction picker)
  final bool emojiOnly;
  /// Permission flags — hide tabs/sections when not permitted
  final bool canSendGifs;
  final bool canSendCustomEmojis;
  final bool canSendCustomStickers;

  const UnifiedPicker({
    super.key,
    required this.onEmojiSelect,
    this.onGifSelect,
    this.onStickerSelect,
    this.customEmojis = const {},
    this.emojiOnly = false,
    this.canSendGifs = true,
    this.canSendCustomEmojis = true,
    this.canSendCustomStickers = true,
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
  final _gifService = GifService();
  List<GifResult> _gifResults = [];
  bool _loadingGifs = false;
  bool _loadingMore = false;
  String? _gifSubView; // null = home, '_trending', or collection ID string
  String? _nextPos; // Tenor pagination token
  Set<String> _favoriteTenorIds = {};
  GifFavoritesService? _favService;
  List<GifCategory> _gifCategories = [];
  List<String> _autocompleteSuggestions = [];
  List<String> _trendingTerms = [];

  // Frequently used emojis
  List<Map<String, String>> _frequentlyUsed = [];

  @override
  void initState() {
    super.initState();
    if (widget.emojiOnly) _tab = 'emoji';
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!widget.emojiOnly) {
      final saved = prefs.getString(_lastTabKey);
      if (saved != null && ['emoji', 'gifs', 'stickers'].contains(saved)) {
        // Respect permission gates — fall back to emoji if saved tab is not permitted
        final allowed = saved == 'gifs' ? widget.canSendGifs
            : saved == 'stickers' ? widget.canSendCustomStickers
            : true;
        if (allowed) setState(() => _tab = saved);
      }
    }
    final freqJson = prefs.getString(_frequentKey);
    if (freqJson != null) {
      try {
        final list = (json.decode(freqJson) as List).cast<Map<String, dynamic>>();
        setState(() {
          _frequentlyUsed = list.map((e) => e.map((k, v) => MapEntry(k, v.toString()))).toList();
        });
      } catch (_) {}
    }
    _initFavService();
  }

  void _initFavService() {
    if (widget.emojiOnly) return; // Skip GIF/sticker init in emoji-only mode
    final db = ref.read(databaseProvider);
    _favService = GifFavoritesService(db, 1);
    _favService!.getAllFavoriteTenorIds().then((ids) {
      if (mounted) setState(() => _favoriteTenorIds = ids);
    });
    // Preload categories and trending terms
    _gifService.categories().then((cats) {
      if (mounted) setState(() => _gifCategories = cats);
    });
    _gifService.trendingTerms().then((terms) {
      if (mounted) setState(() => _trendingTerms = terms);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onSearch(String query) {
    _searchDebounce?.cancel();
    if (query.isEmpty) {
      setState(() {
        _searchQuery = '';
        _autocompleteSuggestions = [];
        _gifResults = [];
        _nextPos = null;
      });
      return;
    }
    _searchDebounce = Timer(Duration(milliseconds: _tab == 'gifs' ? 400 : 150), () {
      setState(() => _searchQuery = query.toLowerCase());
      // Only search Tenor API when on GIF home (not inside a collection sub-view)
      if (_tab == 'gifs' && query.isNotEmpty && _gifSubView == null) {
        _searchGifs(query);
      }
    });
  }

  void _switchTab(String tab) async {
    setState(() {
      _tab = tab;
      _searchController.clear();
      _searchQuery = '';
      _gifSubView = null;
      _gifResults = [];
    });
    final prefs = await SharedPreferences.getInstance();
    prefs.setString(_lastTabKey, tab);
  }

  void _trackFrequentlyUsed(Map<String, String> entry) async {
    _frequentlyUsed.removeWhere((e) {
      if (entry['type'] == 'standard') return e['emoji'] == entry['emoji'];
      return e['name'] == entry['name'];
    });
    _frequentlyUsed.insert(0, entry);
    if (_frequentlyUsed.length > _maxFrequent) {
      _frequentlyUsed = _frequentlyUsed.sublist(0, _maxFrequent);
    }
    final prefs = await SharedPreferences.getInstance();
    prefs.setString(_frequentKey, json.encode(_frequentlyUsed));
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);

    return Container(
      width: 384,
      constraints: BoxConstraints(maxHeight: widget.emojiOnly ? 380 : 420),
      decoration: BoxDecoration(
        color: c.gray800,
        border: Border.all(color: c.gray700),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 16, offset: const Offset(0, -4))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Tabs (hidden in emojiOnly mode)
          if (!widget.emojiOnly)
            Container(
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.gray700))),
              child: Row(
                children: [
                  if (widget.canSendGifs) _TabButton(label: 'GIFs', isActive: _tab == 'gifs', colors: c, onTap: () => _switchTab('gifs')),
                  if (widget.canSendCustomStickers) _TabButton(label: 'Stickers', isActive: _tab == 'stickers', colors: c, onTap: () => _switchTab('stickers')),
                  _TabButton(label: 'Emoji', isActive: _tab == 'emoji', colors: c, onTap: () => _switchTab('emoji')),
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
            child: widget.emojiOnly
                ? _buildEmojiTab(c)
                : switch (_tab) {
                    'gifs' when widget.canSendGifs => _buildGifTab(c),
                    'stickers' when widget.canSendCustomStickers => _buildStickerTab(c),
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
        // Frequently Used
        if (_frequentlyUsed.isNotEmpty && _searchQuery.isEmpty)
          _buildFrequentlyUsedSection(c),
        // Custom server emojis (only if permitted)
        if (widget.canSendCustomEmojis)
          _buildServerEmojisSection(c),
        // Standard categories
        for (final entry in _emojiCategories.entries)
          if (_searchQuery.isEmpty || entry.value.any((e) => e.contains(_searchQuery)))
            _buildEmojiSection(entry.key, entry.value, c),
      ],
    );
  }

  Widget _buildFrequentlyUsedSection(InfernoColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4, left: 4),
          child: Text('\u{1F552} FREQUENTLY USED', style: TextStyle(color: c.gray500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
        ),
        Wrap(
          children: _frequentlyUsed.map((entry) {
            if (entry['type'] == 'custom') {
              final url = entry['url'] ?? '';
              final name = entry['name'] ?? '';
              return _EmojiButton(
                emoji: '',
                customImageUrl: url,
                tooltipText: ':$name:',
                onTap: () {
                  _trackFrequentlyUsed(entry);
                  widget.onEmojiSelect(':$name:');
                },
              );
            }
            return _EmojiButton(
              emoji: entry['emoji'] ?? '',
              onTap: () {
                _trackFrequentlyUsed(entry);
                widget.onEmojiSelect(entry['emoji'] ?? '');
              },
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildEmojiSection(String title, List<String> emojis, InfernoColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4, left: 4),
          child: Text(title.toUpperCase(), style: TextStyle(color: c.gray500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
        ),
        Wrap(
          children: emojis.map((emoji) => _EmojiButton(
            emoji: emoji,
            onTap: () {
              _trackFrequentlyUsed({'type': 'standard', 'emoji': emoji});
              widget.onEmojiSelect(emoji);
            },
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
            onSelect: (name, url) {
              _trackFrequentlyUsed({'type': 'custom', 'name': name, 'url': url});
              widget.onEmojiSelect(':$name:');
            },
          )).toList(),
        );
      },
    );
  }

  // ─── GIF Tab ──────────────────────────────────────────

  Future<void> _searchGifs(String query, {bool append = false}) async {
    if (!append) {
      setState(() { _loadingGifs = true; _nextPos = null; });
    } else {
      setState(() => _loadingMore = true);
    }
    final result = await _gifService.search(query, pos: append ? _nextPos : null);
    if (mounted) {
      setState(() {
        if (append) {
          _gifResults.addAll(result.results);
        } else {
          _gifResults = result.results;
        }
        _nextPos = result.nextPos;
        _loadingGifs = false;
        _loadingMore = false;
      });
    }
    // Fetch autocomplete suggestions
    if (!append && query.length >= 2) {
      _gifService.autocomplete(query).then((suggestions) {
        if (mounted) setState(() => _autocompleteSuggestions = suggestions);
      });
    }
  }

  Future<void> _loadTrending({bool append = false}) async {
    if (!append) {
      setState(() { _loadingGifs = true; _nextPos = null; });
    } else {
      setState(() => _loadingMore = true);
    }
    final result = await _gifService.trending(pos: append ? _nextPos : null);
    if (mounted) {
      setState(() {
        if (append) {
          _gifResults.addAll(result.results);
        } else {
          _gifResults = result.results;
        }
        _nextPos = result.nextPos;
        _loadingGifs = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _toggleGifFavorite(GifResult gif) async {
    if (_favService == null) return;
    final nowFav = await _favService!.toggleFavorite(
      tenorGifId: gif.id,
      tenorUrl: gif.tenorUrl,
      previewUrl: gif.previewUrl,
      gifUrl: gif.gifUrl,
      description: gif.description,
    );
    if (!mounted) return;
    setState(() {
      if (nowFav) {
        _favoriteTenorIds.add(gif.id);
      } else {
        _favoriteTenorIds.remove(gif.id);
      }
    });
  }

  void _showGifContextMenu(TapDownDetails details, {
    required String tenorGifId,
    required String tenorUrl,
    required String previewUrl,
    required String gifUrl,
    String? description,
    int? currentCollectionId,
  }) async {
    if (_favService == null) return;

    final collections = await _favService!.watchCollections().first;
    final defaultCol = await _favService!.getDefaultCollection();
    final containingIds = await _favService!.getCollectionIdsContainingGif(tenorGifId);

    if (!mounted) return;

    // Exclude Favorites from collection menus — fire icon handles that
    final customCollections = collections.where((c) => c.id != defaultCol.id).toList();

    final addToItems = <CtxEntry>[];
    for (final col in customCollections) {
      if (containingIds.contains(col.id)) continue;
      final iconText = col.icon ?? '\u{1F4C1}';
      final isUrl = iconText.startsWith('http');
      addToItems.add(CtxItem(
        '${isUrl ? '' : '$iconText '}${col.name}', null,
        () async {
          await _favService!.addToCollection(
            collectionId: col.id,
            tenorGifId: tenorGifId,
            tenorUrl: tenorUrl,
            previewUrl: previewUrl,
            gifUrl: gifUrl,
            description: description,
          );
          if (mounted) {
            _favService!.getAllFavoriteTenorIds().then((ids) {
              if (mounted) setState(() => _favoriteTenorIds = ids);
            });
          }
        },
      ));
    }
    addToItems.add(CtxDivider());
    addToItems.add(CtxItem('New Collection...', Icons.add, () {
      _showNewCollectionDialog(thenAddGif: (collectionId) async {
        await _favService!.addToCollection(
          collectionId: collectionId,
          tenorGifId: tenorGifId,
          tenorUrl: tenorUrl,
          previewUrl: previewUrl,
          gifUrl: gifUrl,
          description: description,
        );
        if (mounted) {
          _favService!.getAllFavoriteTenorIds().then((ids) {
            if (mounted) setState(() => _favoriteTenorIds = ids);
          });
        }
      });
    }));

    final items = <CtxEntry>[
      CtxItem('Add to Collection', Icons.folder_open, () {}, submenu: addToItems),
    ];

    if (currentCollectionId != null) {
      items.add(CtxDivider());
      items.add(CtxItem('Remove from Collection', Icons.delete_outline, () async {
        final favs = await _favService!.watchFavorites(currentCollectionId).first;
        final match = favs.where((f) => f.tenorGifId == tenorGifId).firstOrNull;
        if (match != null) {
          await _favService!.removeFavorite(match.id);
          if (mounted) {
            _favService!.getAllFavoriteTenorIds().then((ids) {
              if (mounted) setState(() => _favoriteTenorIds = ids);
            });
          }
        }
      }, danger: true));
    }

    showStyledMenu(context: context, position: details.globalPosition, items: items);
  }

  void _showNewCollectionDialog({void Function(int collectionId)? thenAddGif}) {
    final nameController = TextEditingController();
    String selectedIcon = '\u{1F4C1}';
    String iconSearchQuery = '';

    Future<void> doCreate(BuildContext ctx) async {
      final name = nameController.text.trim();
      if (name.isEmpty) return;
      try {
        final col = await _favService!.createCollection(name, icon: selectedIcon);
        if (ctx.mounted) Navigator.pop(ctx);
        thenAddGif?.call(col.id);
      } catch (e) {
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(e.toString())));
        }
      }
    }

    showDialog(
      context: context,
      builder: (ctx) {
        final c = ref.read(infernoColorsProvider);
        return StatefulBuilder(builder: (ctx, setDialogState) {
          // Build flat emoji list filtered by search
          final allEmojis = <_IconOption>[];
          // Server custom emojis first
          for (final entry in widget.customEmojis.entries) {
            if (iconSearchQuery.isEmpty || entry.key.toLowerCase().contains(iconSearchQuery)) {
              allEmojis.add(_IconOption(value: entry.value, isUrl: true, label: entry.key));
            }
          }
          // Standard unicode emojis
          for (final catEntry in _emojiCategories.entries) {
            for (final emoji in catEntry.value) {
              if (iconSearchQuery.isEmpty || catEntry.key.toLowerCase().contains(iconSearchQuery)) {
                allEmojis.add(_IconOption(value: emoji, isUrl: false));
              }
            }
          }

          return Dialog(
            backgroundColor: Colors.transparent,
            child: Container(
              width: 380,
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: c.gray800,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('New Collection', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 16),
                // Name field + selected icon preview
                Row(
                  children: [
                    // Selected icon
                    GestureDetector(
                      onTap: () {}, // icon is selected from grid below
                      child: Container(
                        width: 44, height: 44,
                        decoration: BoxDecoration(
                          color: c.gray700,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: c.gray600),
                        ),
                        child: Center(
                          child: selectedIcon.startsWith('http')
                              ? CachedNetworkImage(imageUrl: selectedIcon, width: 28, height: 28, fit: BoxFit.contain)
                              : Text(selectedIcon, style: const TextStyle(fontSize: 24)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Name field
                    Expanded(
                      child: TextField(
                        controller: nameController,
                        maxLength: 50,
                        autofocus: true,
                        style: TextStyle(color: Colors.white, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'Collection name',
                          hintStyle: TextStyle(color: c.gray500),
                          counterText: '',
                          filled: true,
                          fillColor: c.gray900,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent)),
                        ),
                        onSubmitted: (_) => doCreate(ctx),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Icon search
                TextField(
                  style: TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search icons...',
                    hintStyle: TextStyle(color: c.gray500, fontSize: 13),
                    prefixIcon: Icon(Icons.search, size: 16, color: c.gray500),
                    prefixIconConstraints: const BoxConstraints(minWidth: 36),
                    filled: true,
                    fillColor: c.gray900,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent)),
                  ),
                  onChanged: (q) => setDialogState(() => iconSearchQuery = q.toLowerCase()),
                ),
                const SizedBox(height: 8),
                // Emoji grid (scrollable, same style as unified picker)
                Flexible(
                  child: Container(
                    decoration: BoxDecoration(
                      color: c.gray900,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: c.gray700),
                    ),
                    child: allEmojis.isEmpty
                        ? Center(child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text('No matches', style: TextStyle(color: c.gray500, fontSize: 13)),
                          ))
                        : GridView.builder(
                            padding: const EdgeInsets.all(4),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 8, crossAxisSpacing: 2, mainAxisSpacing: 2,
                            ),
                            itemCount: allEmojis.length,
                            itemBuilder: (context, index) {
                              final opt = allEmojis[index];
                              final isSelected = opt.value == selectedIcon;
                              return GestureDetector(
                                onTap: () => setDialogState(() => selectedIcon = opt.value),
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: isSelected ? c.accent.withValues(alpha: 0.2) : Colors.transparent,
                                      borderRadius: BorderRadius.circular(6),
                                      border: isSelected ? Border.all(color: c.accent, width: 1.5) : null,
                                    ),
                                    child: Center(
                                      child: opt.isUrl
                                          ? CachedNetworkImage(imageUrl: opt.value, width: 22, height: 22, fit: BoxFit.contain)
                                          : Text(opt.value, style: const TextStyle(fontSize: 20)),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                // Create button
                SizedBox(
                  width: double.infinity,
                  child: GestureDetector(
                    onTap: () => doCreate(ctx),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: c.accent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Text('Create', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          );
        });
      },
    );
  }

  Widget _buildGifTab(InfernoColors c) {
    // If we're in a sub-view (trending or collection)
    if (_gifSubView != null) {
      return _buildGifSubView(c);
    }

    // If searching from home, search Tenor directly
    if (_searchQuery.isNotEmpty) {
      return _buildGifSearchResults(c);
    }

    // Home: show collection tiles
    return _buildGifHome(c);
  }

  Widget _buildGifHome(InfernoColors c) {
    if (_favService == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    return StreamBuilder<List<GifCollection>>(
      stream: _favService!.watchCollections(),
      builder: (context, snap) {
        final collections = snap.data ?? [];
        final favCol = collections.where((c) => c.name == 'Favorites').firstOrNull;
        final customCols = collections.where((c) => c.name != 'Favorites').toList();

        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            // Trending search terms as chips
            if (_trendingTerms.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6, top: 2),
                child: Text('TRENDING', style: TextStyle(color: c.gray500, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
              ),
              Wrap(
                spacing: 6, runSpacing: 6,
                children: _trendingTerms.take(8).map((term) => GestureDetector(
                  onTap: () {
                    _searchController.text = term;
                    _onSearch(term);
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: c.gray700,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: c.gray600),
                      ),
                      child: Text(term, style: TextStyle(color: c.gray200, fontSize: 12)),
                    ),
                  ),
                )).toList(),
              ),
              const SizedBox(height: 12),
            ],
            // Collection tiles row
            GridView.count(
              crossAxisCount: 2,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 2.2,
              children: [
                _CollectionTile(
                  icon: '\u{1F525}',
                  name: 'Favorites',
                  subtitle: favCol != null ? _FavCountText(favService: _favService!, collectionId: favCol.id) : null,
                  colors: c,
                  onTap: () => setState(() { _gifSubView = 'favorites'; _gifResults = []; }),
                ),
                _CollectionTile(
                  icon: '\u{1F4C8}',
                  name: 'Trending',
                  colors: c,
                  onTap: () { _gifSubView = '_trending'; _loadTrending(); },
                ),
                for (final col in customCols)
                  _CollectionTile(
                    icon: col.icon ?? '\u{1F4C1}',
                    name: col.name,
                    subtitle: _FavCountText(favService: _favService!, collectionId: col.id),
                    colors: c,
                    onTap: () => setState(() { _gifSubView = 'col_${col.id}'; _gifResults = []; }),
                  ),
                // New Collection tile
                _CollectionTile(
                  icon: '+',
                  name: 'New Collection',
                  colors: c,
                  onTap: () => _showNewCollectionDialog(),
                  isAddButton: true,
                ),
              ],
            ),
            // Tenor categories
            if (_gifCategories.isNotEmpty) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Text('CATEGORIES', style: TextStyle(color: c.gray500, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
              ),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2, crossAxisSpacing: 6, mainAxisSpacing: 6, childAspectRatio: 2.0,
                ),
                itemCount: _gifCategories.length.clamp(0, 8),
                itemBuilder: (context, index) {
                  final cat = _gifCategories[index];
                  return _CategoryTile(
                    name: cat.name,
                    imageUrl: cat.imageUrl,
                    colors: c,
                    onTap: () {
                      _searchController.text = cat.searchTerm;
                      _onSearch(cat.searchTerm);
                    },
                  );
                },
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildGifSubView(InfernoColors c) {
    if (_gifSubView == '_trending') {
      return _buildGifGridWithBack(c, _gifResults);
    }

    if (_gifSubView == 'favorites') {
      return _buildFavoritesSubView(c);
    }

    // Custom collection: col_{id}
    if (_gifSubView != null && _gifSubView!.startsWith('col_')) {
      final colId = int.tryParse(_gifSubView!.substring(4));
      if (colId != null) return _buildCollectionSubView(c, colId, isDefault: false);
    }

    return _buildGifHome(c);
  }

  Widget _buildFavoritesSubView(InfernoColors c) {
    if (_favService == null) return const SizedBox.shrink();

    return FutureBuilder<GifCollection>(
      future: _favService!.getDefaultCollection(),
      builder: (context, colSnap) {
        if (!colSnap.hasData) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        return _buildCollectionSubView(c, colSnap.data!.id, isDefault: true);
      },
    );
  }

  Widget _buildCollectionSubView(InfernoColors c, int collectionId, {bool isDefault = true}) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _backButton(c)),
            if (!isDefault)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () async {
                      await _favService!.deleteCollection(collectionId);
                      _favService!.getAllFavoriteTenorIds().then((ids) {
                        if (mounted) setState(() => _favoriteTenorIds = ids);
                      });
                      setState(() { _gifSubView = null; _gifResults = []; });
                    },
                    child: Icon(Icons.delete_outline, size: 16, color: c.gray400),
                  ),
                ),
              ),
          ],
        ),
        Expanded(
          child: StreamBuilder<List<GifFavorite>>(
            stream: _favService!.watchFavorites(collectionId),
            builder: (context, snap) {
              var favorites = snap.data ?? [];
              if (_searchQuery.isNotEmpty) {
                favorites = favorites.where((f) =>
                    (f.description ?? '').toLowerCase().contains(_searchQuery) ||
                    f.tenorUrl.toLowerCase().contains(_searchQuery) ||
                    f.tenorGifId.toLowerCase().contains(_searchQuery)).toList();
              }
              if (favorites.isEmpty) {
                return Center(
                  child: Text(
                    _searchQuery.isNotEmpty ? 'No matches' : 'No saved GIFs yet',
                    style: TextStyle(color: c.gray500, fontSize: 14),
                  ),
                );
              }
              return GridView.builder(
                padding: const EdgeInsets.all(4),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2, crossAxisSpacing: 4, mainAxisSpacing: 4,
                ),
                itemCount: favorites.length,
                itemBuilder: (context, index) {
                  final fav = favorites[index];
                  return _GifTile(
                    previewUrl: fav.previewUrl,
                    gifUrl: fav.tenorUrl,
                    tenorGifId: fav.tenorGifId,
                    isFavorite: true,
                    colors: c,
                    onTap: () => widget.onGifSelect?.call(fav.gifUrl),
                    onToggleFavorite: () async {
                      await _favService!.removeFavorite(fav.id);
                      if (mounted) {
                        setState(() => _favoriteTenorIds.remove(fav.tenorGifId));
                      }
                    },
                    onContextMenu: (details) => _showGifContextMenu(details,
                      tenorGifId: fav.tenorGifId,
                      tenorUrl: fav.tenorUrl,
                      previewUrl: fav.previewUrl,
                      gifUrl: fav.gifUrl,
                      description: fav.description,
                      currentCollectionId: collectionId,
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildGifSearchResults(InfernoColors c) {
    return Column(
      children: [
        // Autocomplete suggestions
        if (_autocompleteSuggestions.isNotEmpty && _autocompleteSuggestions.first != _searchQuery)
          SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: _autocompleteSuggestions.map((s) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(
                  onTap: () {
                    _searchController.text = s;
                    _searchQuery = s;
                    _searchGifs(s);
                    setState(() => _autocompleteSuggestions = []);
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: c.gray700,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: c.gray600),
                      ),
                      child: Text(s, style: TextStyle(color: c.gray200, fontSize: 12)),
                    ),
                  ),
                ),
              )).toList(),
            ),
          ),
        // Results
        if (_loadingGifs && _gifResults.isEmpty)
          const Expanded(child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
        else if (_gifResults.isEmpty)
          Expanded(child: Center(child: Text('No GIFs found', style: TextStyle(color: c.gray500, fontSize: 14))))
        else
          Expanded(child: _buildGifGrid(c, _gifResults)),
      ],
    );
  }

  Widget _buildGifGridWithBack(InfernoColors c, List<GifResult> results) {
    if (_loadingGifs) {
      return Column(
        children: [
          _backButton(c),
          const Expanded(child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
        ],
      );
    }
    return Column(
      children: [
        _backButton(c),
        Expanded(child: _buildGifGrid(c, results)),
      ],
    );
  }

  Widget _buildGifGrid(InfernoColors c, List<GifResult> results) {
    if (results.isEmpty) {
      return Center(child: Text('No GIFs found', style: TextStyle(color: c.gray500, fontSize: 14)));
    }
    final hasMore = _nextPos != null && _nextPos!.isNotEmpty;
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2, crossAxisSpacing: 4, mainAxisSpacing: 4,
      ),
      itemCount: results.length + (hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        // Load more button at the end
        if (index >= results.length) {
          return GestureDetector(
            onTap: _loadingMore ? null : () {
              if (_gifSubView == '_trending') {
                _loadTrending(append: true);
              } else {
                _searchGifs(_searchQuery, append: true);
              }
            },
            child: Container(
              decoration: BoxDecoration(color: c.gray700, borderRadius: BorderRadius.circular(8)),
              child: Center(
                child: _loadingMore
                    ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: c.accent))
                    : Text('Load more', style: TextStyle(color: c.accent, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
          );
        }
        final gif = results[index];
        return _GifTile(
          previewUrl: gif.previewUrl,
          gifUrl: gif.tenorUrl,
          tenorGifId: gif.id,
          isFavorite: _favoriteTenorIds.contains(gif.id),
          colors: c,
          onTap: () => widget.onGifSelect?.call(gif.gifUrl),
          onToggleFavorite: () => _toggleGifFavorite(gif),
          onContextMenu: (details) => _showGifContextMenu(details,
            tenorGifId: gif.id,
            tenorUrl: gif.tenorUrl,
            previewUrl: gif.previewUrl,
            gifUrl: gif.gifUrl,
            description: gif.description,
          ),
        );
      },
    );
  }

  Widget _backButton(InfernoColors c) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => setState(() {
              _gifSubView = null;
              _gifResults = [];
              _searchController.clear();
              _searchQuery = '';
            }),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.chevron_left, size: 16, color: c.gray400),
                Text('Back', style: TextStyle(color: c.gray400, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
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
            onSelect: (url) => widget.onStickerSelect?.call(url),
          )).toList(),
        );
      },
    );
  }
}

// ─── Sub-widgets ──────────────────────────────────────────

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
  final String? customImageUrl;
  final String? tooltipText;
  final VoidCallback onTap;
  const _EmojiButton({required this.emoji, this.customImageUrl, this.tooltipText, required this.onTap});

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
          child: Center(
            child: widget.customImageUrl != null && widget.customImageUrl!.isNotEmpty
                ? Image.network(widget.customImageUrl!, width: 24, height: 24, errorBuilder: (_, __, ___) => const SizedBox.shrink())
                : Text(widget.emoji, style: const TextStyle(fontSize: 22)),
          ),
        ),
      ),
    );
  }
}

/// A GIF tile with preview image and favorite toggle button.
class _GifTile extends StatefulWidget {
  final String previewUrl;
  final String gifUrl;
  final String tenorGifId;
  final bool isFavorite;
  final InfernoColors colors;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final void Function(TapDownDetails)? onContextMenu;

  const _GifTile({
    required this.previewUrl,
    required this.gifUrl,
    required this.tenorGifId,
    required this.isFavorite,
    required this.colors,
    required this.onTap,
    required this.onToggleFavorite,
    this.onContextMenu,
  });

  @override
  State<_GifTile> createState() => _GifTileState();
}

class _GifTileState extends State<_GifTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTapDown: widget.onContextMenu != null ? (details) {
          // Convert local position to true global via RenderBox
          // (globalPosition can be wrong inside CompositedTransformFollower)
          final box = context.findRenderObject() as RenderBox?;
          final globalPos = box != null
              ? box.localToGlobal(details.localPosition)
              : details.globalPosition;
          widget.onContextMenu!(TapDownDetails(
            globalPosition: globalPos,
            localPosition: details.localPosition,
          ));
        } : null,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.network(
                widget.previewUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: widget.colors.gray700,
                  child: Icon(Icons.broken_image, color: widget.colors.gray500),
                ),
              ),
              // Hover ring
              if (_hovering)
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: widget.colors.accent, width: 2),
                  ),
                ),
              // Favorite toggle
              if (_hovering || widget.isFavorite)
                Positioned(
                  top: 4, left: 4,
                  child: GestureDetector(
                    onTap: widget.onToggleFavorite,
                    child: Container(
                      width: 18, height: 18,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        shape: BoxShape.circle,
                      ),
                      child: SvgPicture.asset(
                        'assets/icons/inferno_mono.svg',
                        width: 10, height: 10,
                        colorFilter: ColorFilter.mode(
                          widget.isFavorite ? widget.colors.accent : Colors.white.withValues(alpha: 0.8),
                          BlendMode.srcIn,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Collection tile for GIF home view.
class _CollectionTile extends StatefulWidget {
  final String icon;
  final String name;
  final Widget? subtitle;
  final InfernoColors colors;
  final VoidCallback onTap;
  final bool isAddButton;

  const _CollectionTile({
    required this.icon,
    required this.name,
    this.subtitle,
    required this.colors,
    required this.onTap,
    this.isAddButton = false,
  });

  @override
  State<_CollectionTile> createState() => _CollectionTileState();
}

class _CollectionTileState extends State<_CollectionTile> {
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
          decoration: BoxDecoration(
            color: _hovering ? widget.colors.gray600 : widget.colors.gray700,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.isAddButton)
                Icon(Icons.add, size: 24, color: widget.colors.gray400)
              else if (widget.icon.startsWith('http'))
                CachedNetworkImage(imageUrl: widget.icon, width: 24, height: 24, fit: BoxFit.contain,
                  errorWidget: (_, __, ___) => Text('\u{1F4C1}', style: const TextStyle(fontSize: 24)))
              else
                Text(widget.icon, style: const TextStyle(fontSize: 24)),
              const SizedBox(height: 4),
              Text(widget.name,
                style: TextStyle(
                  color: widget.isAddButton ? widget.colors.gray400 : Colors.white,
                  fontSize: 12, fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
              ),
              if (widget.subtitle != null) widget.subtitle!,
            ],
          ),
        ),
      ),
    );
  }
}

/// Category tile with background image from Tenor
class _CategoryTile extends StatefulWidget {
  final String name;
  final String imageUrl;
  final InfernoColors colors;
  final VoidCallback onTap;
  const _CategoryTile({required this.name, required this.imageUrl, required this.colors, required this.onTap});
  @override
  State<_CategoryTile> createState() => _CategoryTileState();
}

class _CategoryTileState extends State<_CategoryTile> {
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
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: _hovering ? Border.all(color: widget.colors.accent, width: 2) : null,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (widget.imageUrl.isNotEmpty)
                Image.network(widget.imageUrl, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(color: widget.colors.gray700))
              else
                Container(color: widget.colors.gray700),
              // Dark gradient overlay for text readability
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black.withValues(alpha: 0.7)],
                  ),
                ),
              ),
              // Label
              Positioned(
                left: 8, bottom: 6,
                child: Text(widget.name,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700, shadows: [
                    Shadow(offset: Offset(0, 1), blurRadius: 3, color: Colors.black),
                  ]),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Async widget that shows the favorites count for a collection.
class _FavCountText extends StatelessWidget {
  final GifFavoritesService favService;
  final int collectionId;
  const _FavCountText({required this.favService, required this.collectionId});

  @override
  Widget build(BuildContext context) {
    final c = ProviderScope.containerOf(context).read(infernoColorsProvider);
    return StreamBuilder<int>(
      stream: favService.watchFavoritesCount(collectionId),
      builder: (context, snap) {
        if (!snap.hasData || snap.data == 0) return const SizedBox.shrink();
        return Text('${snap.data}', style: TextStyle(color: c.gray400, fontSize: 11));
      },
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
              children: emojis.map((emoji) => GestureDetector(
                onTap: () => onSelect(emoji.name, emoji.url ?? ''),
                child: Container(
                  width: 36, height: 36,
                  padding: const EdgeInsets.all(4),
                  child: emoji.url != null
                      ? Image.network(emoji.url!, width: 24, height: 24)
                      : Text(emoji.name[0], style: TextStyle(color: colors.gray200)),
                ),
              )).toList(),
            ),
          ],
        );
      },
    );
  }
}

/// Icon option for the collection icon picker grid.
class _IconOption {
  final String value; // emoji character or URL
  final bool isUrl;
  final String? label; // for search matching (custom emoji name)
  const _IconOption({required this.value, this.isUrl = false, this.label});
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
