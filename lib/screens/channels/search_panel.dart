import 'dart:async';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../database/database.dart';
import '../../providers/database_provider.dart';
import '../../services/search_service.dart';
import '../../theme/all_themes.dart';
import '../../theme/theme_provider.dart';
import '../../widgets/message_content.dart';
import '../../widgets/message_list.dart';

class ActiveFilter {
  final String type; // 'from', 'has', 'before', 'after', 'on', 'in'
  final String value;
  final String label;

  const ActiveFilter({required this.type, required this.value, required this.label});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActiveFilter && type == other.type && value == other.value;

  @override
  int get hashCode => type.hashCode ^ value.hashCode;
}

/// Persisted search state per channel — survives panel close/reopen and channel switches.
class _ChannelSearchState {
  String queryText;
  List<ActiveFilter> filters;

  _ChannelSearchState({this.queryText = '', List<ActiveFilter>? filters})
      : filters = filters ?? [];
}

/// Right-side search panel matching Rails: filters, pagination, jump-to-message.
/// Filters persist per channel until explicitly cleared.
class SearchPanel extends ConsumerStatefulWidget {
  final int? channelId;
  final int? serverId;
  final VoidCallback onClose;

  const SearchPanel({super.key, this.channelId, this.serverId, required this.onClose});

  @override
  ConsumerState<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends ConsumerState<SearchPanel> {
  // Static per-channel filter/query persistence (keyed by channelId)
  static final Map<int, _ChannelSearchState> _savedStates = {};

  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;
  List<Message> _results = [];
  bool _searching = false;
  int _totalLoaded = 0;
  int _totalCount = 0;
  bool _hasMore = false;
  List<ActiveFilter> _filters = [];

  // Autocomplete state
  List<RemoteMember> _memberSuggestions = [];
  List<Channel> _channelSuggestions = [];
  String? _pendingFilterType; // 'from', 'has', 'in', or null

  // Resolved author info cache (shared across searches)
  static final Map<String, String> _authorNames = {};
  static final Map<String, String?> _authorAvatars = {};

  // Resolved channel name cache
  static final Map<int, String> _channelNames = {};

  // Custom emojis for this server
  Map<String, String> _customEmojis = {};

  int? get _stateKey => widget.channelId;

  @override
  void initState() {
    super.initState();
    // Restore persisted state for this channel
    final saved = _stateKey != null ? _savedStates[_stateKey] : null;
    if (saved != null) {
      _controller.text = saved.queryText;
      _filters = List.of(saved.filters);
    }
    _controller.addListener(_onTextChanged);
    _loadCustomEmojis();
    // Run initial search if we have restored state
    if (_filters.isNotEmpty || _controller.text.isNotEmpty) {
      Future.microtask(_search);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // Persist state before dispose
    _persistState();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _persistState() {
    if (_stateKey == null) return;
    if (_filters.isEmpty && _controller.text.isEmpty) {
      _savedStates.remove(_stateKey);
    } else {
      _savedStates[_stateKey!] = _ChannelSearchState(
        queryText: _controller.text,
        filters: List.of(_filters),
      );
    }
  }

  Future<void> _loadCustomEmojis() async {
    if (widget.serverId == null) return;
    final db = ref.read(databaseProvider);
    final emojis = await (db.select(db.serverEmojis)
        ..where((e) => e.serverId.equals(widget.serverId!)))
        .get();
    if (mounted) {
      setState(() {
        _customEmojis = {for (final e in emojis) if (e.url != null) e.name: e.url!};
      });
    }
  }

  void _clearAll() {
    setState(() {
      _filters.clear();
      _controller.clear();
      _results = [];
      _totalLoaded = 0;
      _totalCount = 0;
      _hasMore = false;
      _pendingFilterType = null;
      _memberSuggestions = [];
      _channelSuggestions = [];
    });
    if (_stateKey != null) _savedStates.remove(_stateKey);
  }

  void _onTextChanged() {
    _debounce?.cancel();
    final text = _controller.text;

    // Detect typed filter prefixes
    if (text.toLowerCase().startsWith('from:')) {
      _startMemberSearch(text.substring(5).trim());
      return;
    }
    if (text.toLowerCase().startsWith('in:')) {
      _startChannelSearch(text.substring(3).trim());
      return;
    }
    if (text.toLowerCase().startsWith('has:')) {
      setState(() => _pendingFilterType = 'has');
      return;
    }
    if (text.toLowerCase().startsWith('before:') ||
        text.toLowerCase().startsWith('after:') ||
        text.toLowerCase().startsWith('on:')) {
      final prefix = text.split(':').first.toLowerCase();
      _openDatePicker(prefix);
      return;
    }
    setState(() {
      _pendingFilterType = null;
      _memberSuggestions = [];
      _channelSuggestions = [];
    });

    _debounce = Timer(const Duration(milliseconds: 350), _search);
  }

  // ── Autocomplete: from: ──

  Future<void> _startMemberSearch(String query) async {
    if (widget.serverId == null) return;
    final db = ref.read(databaseProvider);
    final svc = SearchService(db);
    final members = await svc.searchMembers(widget.serverId!, query);
    if (mounted) {
      setState(() {
        _memberSuggestions = members;
        _channelSuggestions = [];
        _pendingFilterType = 'from';
      });
    }
  }

  void _selectMember(RemoteMember member) {
    final name = member.displayName ?? member.username ?? member.pubkey.substring(0, 8);
    _addFilter(ActiveFilter(type: 'from', value: member.pubkey, label: 'from: $name'));
    _controller.clear();
    setState(() { _pendingFilterType = null; _memberSuggestions = []; });
  }

  // ── Autocomplete: in: ──

  Future<void> _startChannelSearch(String query) async {
    if (widget.serverId == null) return;
    final db = ref.read(databaseProvider);
    final svc = SearchService(db);
    final channels = await svc.searchChannels(widget.serverId!, query);
    if (mounted) {
      setState(() {
        _channelSuggestions = channels;
        _memberSuggestions = [];
        _pendingFilterType = 'in';
      });
    }
  }

  void _selectChannel(Channel channel) {
    _channelNames[channel.id] = channel.name;
    _addFilter(ActiveFilter(
      type: 'in',
      value: channel.id.toString(),
      label: 'in: #${channel.name}',
    ));
    _controller.clear();
    setState(() { _pendingFilterType = null; _channelSuggestions = []; });
  }

  // ── Filter management ──

  void _addFilter(ActiveFilter filter) {
    if (_filters.contains(filter)) return;
    // For singleton filters, replace existing
    if (filter.type == 'before' || filter.type == 'after' || filter.type == 'on') {
      _filters.removeWhere((f) => f.type == filter.type);
    }
    setState(() => _filters.add(filter));
    _persistState();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 100), _search);
  }

  void _removeFilter(int index) {
    setState(() => _filters.removeAt(index));
    _persistState();
    _search();
  }

  void _selectHasOption(String value) {
    final labels = {'file': 'has: File', 'image': 'has: Image', 'link': 'has: Link'};
    _addFilter(ActiveFilter(type: 'has', value: value, label: labels[value]!));
    _controller.clear();
    setState(() => _pendingFilterType = null);
  }

  Future<void> _openDatePicker(String prefix) async {
    _controller.clear();
    setState(() => _pendingFilterType = null);

    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null && mounted) {
      final formatted = DateFormat('MM/dd/yyyy').format(picked);
      _addFilter(ActiveFilter(type: prefix, value: picked.toIso8601String(), label: '$prefix: $formatted'));
    }
  }

  // ── Search execution ──

  SearchFilter _buildFilter() {
    final fromPubkeys = _filters.where((f) => f.type == 'from').map((f) => f.value).toList();
    final hasTypes = _filters.where((f) => f.type == 'has').map((f) => f.value).toList();
    final inChannelIds = _filters
        .where((f) => f.type == 'in')
        .map((f) => int.tryParse(f.value))
        .whereType<int>()
        .toList();
    DateTime? before, after, on;

    for (final f in _filters) {
      switch (f.type) {
        case 'before':
          before = DateTime.tryParse(f.value);
          break;
        case 'after':
          after = DateTime.tryParse(f.value);
          break;
        case 'on':
          on = DateTime.tryParse(f.value);
          break;
      }
    }

    return SearchFilter(
      fromPubkeys: fromPubkeys,
      hasTypes: hasTypes,
      inChannelIds: inChannelIds,
      before: before,
      after: after,
      on: on,
    );
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    // Don't clear prefix text from search query
    final isPrefix = query.toLowerCase().startsWith('from:') ||
        query.toLowerCase().startsWith('in:') ||
        query.toLowerCase().startsWith('has:');
    final searchQuery = isPrefix ? null : (query.isNotEmpty ? query : null);
    final filter = _buildFilter();

    if (searchQuery == null && filter.isEmpty) {
      setState(() { _results = []; _totalLoaded = 0; _totalCount = 0; _hasMore = false; });
      return;
    }

    setState(() => _searching = true);
    final db = ref.read(databaseProvider);
    final svc = SearchService(db);

    // If no in: filters, default to current channel
    final defaultChannelId = filter.inChannelIds.isEmpty ? widget.channelId : null;

    final results = await svc.searchWithFilters(
      query: searchQuery,
      defaultChannelId: defaultChannelId,
      filter: filter,
      limit: 25,
      offset: 0,
    );

    final total = await svc.countWithFilters(
      query: searchQuery,
      defaultChannelId: defaultChannelId,
      filter: filter,
    );

    await _resolveAuthors(results, db);
    if (filter.inChannelIds.isNotEmpty) await _resolveChannelNames(results, db);

    if (mounted) {
      setState(() {
        _results = results;
        _totalLoaded = results.length;
        _totalCount = total;
        _hasMore = results.length == 25 && results.length < total;
        _searching = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (!_hasMore || _searching) return;
    setState(() => _searching = true);

    final query = _controller.text.trim();
    final isPrefix = query.toLowerCase().startsWith('from:') ||
        query.toLowerCase().startsWith('in:') ||
        query.toLowerCase().startsWith('has:');
    final searchQuery = isPrefix ? null : (query.isNotEmpty ? query : null);
    final filter = _buildFilter();
    final db = ref.read(databaseProvider);
    final svc = SearchService(db);
    final defaultChannelId = filter.inChannelIds.isEmpty ? widget.channelId : null;

    final results = await svc.searchWithFilters(
      query: searchQuery,
      defaultChannelId: defaultChannelId,
      filter: filter,
      limit: 25,
      offset: _totalLoaded,
    );

    await _resolveAuthors(results, db);
    if (filter.inChannelIds.isNotEmpty) await _resolveChannelNames(results, db);

    if (mounted) {
      setState(() {
        _results.addAll(results);
        _totalLoaded += results.length;
        _hasMore = results.length == 25 && _totalLoaded < _totalCount;
        _searching = false;
      });
    }
  }

  Future<void> _resolveAuthors(List<Message> messages, InfernoDatabase db) async {
    final unknownPubkeys = <String>{};
    for (final m in messages) {
      if (m.nostrAuthorPubkey != null && !_authorNames.containsKey(m.nostrAuthorPubkey)) {
        unknownPubkeys.add(m.nostrAuthorPubkey!);
      }
    }
    if (unknownPubkeys.isEmpty) return;

    for (final pubkey in unknownPubkeys) {
      final members = await (db.select(db.remoteMembers)
            ..where((m) => m.pubkey.equals(pubkey))
            ..limit(1))
          .get();
      if (members.isNotEmpty) {
        _authorNames[pubkey] = members.first.displayName ?? members.first.username ?? pubkey.substring(0, 8);
        _authorAvatars[pubkey] = members.first.avatarUrl;
        continue;
      }
      final contact = await db.contactsDao.getByPubkey(pubkey);
      if (contact != null) {
        _authorNames[pubkey] = contact.displayName ?? contact.username ?? pubkey.substring(0, 8);
        _authorAvatars[pubkey] = contact.avatarUrl;
      } else {
        _authorNames[pubkey] = '${pubkey.substring(0, 8)}...';
        _authorAvatars[pubkey] = null;
      }
    }
  }

  Future<void> _resolveChannelNames(List<Message> messages, InfernoDatabase db) async {
    final unknownIds = <int>{};
    for (final m in messages) {
      if (m.channelId != null && !_channelNames.containsKey(m.channelId)) {
        unknownIds.add(m.channelId!);
      }
    }
    if (unknownIds.isEmpty) return;
    for (final id in unknownIds) {
      final ch = await (db.select(db.channels)..where((c) => c.id.equals(id))).getSingleOrNull();
      if (ch != null) _channelNames[id] = ch.name;
    }
  }

  void _jumpToMessage(Message msg) {
    if (msg.nostrEventId != null) {
      MessageList.scrollToMessage(msg.nostrEventId!);
    }
  }

  bool get _hasInFilters => _filters.any((f) => f.type == 'in');

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);

    return Container(
      width: 420,
      decoration: BoxDecoration(
        color: c.gray800,
        border: Border(left: BorderSide(color: c.accent.withValues(alpha: 0.10), width: 1)),
      ),
      child: Column(children: [
        _buildHeader(c),
        if (_filters.isNotEmpty) _buildFilterChips(c),
        _buildSearchRow(c),
        if (_pendingFilterType == 'has') _buildHasOptions(c),
        if (_pendingFilterType == 'from') _buildMemberAutocomplete(c),
        if (_pendingFilterType == 'in') _buildChannelAutocomplete(c),
        Expanded(child: _buildResults(c)),
      ]),
    );
  }

  Widget _buildHeader(InfernoColors c) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.gray900))),
      child: Row(children: [
        Text('Search', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
        const Spacer(),
        if (_filters.isNotEmpty || _controller.text.isNotEmpty)
          GestureDetector(
            onTap: _clearAll,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('Clear', style: TextStyle(color: c.gray500, fontSize: 12)),
              ),
            ),
          ),
        GestureDetector(
          onTap: widget.onClose,
          child: MouseRegion(cursor: SystemMouseCursors.click, child: Icon(Icons.close, size: 18, color: c.gray400)),
        ),
      ]),
    );
  }

  Widget _buildFilterChips(InfernoColors c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: List.generate(_filters.length, (i) {
          final f = _filters[i];
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: c.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: c.accent.withValues(alpha: 0.3)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(f.label, style: TextStyle(color: c.accent, fontSize: 12)),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () => _removeFilter(i),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Icon(Icons.close, size: 14, color: c.accent.withValues(alpha: 0.7)),
                ),
              ),
            ]),
          );
        }),
      ),
    );
  }

  Widget _buildSearchRow(InfernoColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            autofocus: true,
            onSubmitted: (_) => _search(),
            style: TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Search messages...',
              hintStyle: TextStyle(color: c.gray500),
              fillColor: c.gray900,
              filled: true,
              prefixIcon: Icon(Icons.search, size: 18, color: c.gray500),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.accent)),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _AddFilterButton(colors: c, onSelected: _onFilterSelected),
      ]),
    );
  }

  void _onFilterSelected(String filterType) {
    switch (filterType) {
      case 'from':
        _controller.text = 'from:';
        _controller.selection = TextSelection.collapsed(offset: 5);
        _focusNode.requestFocus();
        break;
      case 'in':
        _controller.text = 'in:';
        _controller.selection = TextSelection.collapsed(offset: 3);
        _focusNode.requestFocus();
        break;
      case 'has':
        setState(() => _pendingFilterType = 'has');
        break;
      case 'before':
        _openDatePicker('before');
        break;
      case 'after':
        _openDatePicker('after');
        break;
      case 'on':
        _openDatePicker('on');
        break;
    }
  }

  Widget _buildHasOptions(InfernoColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('HAS:', style: TextStyle(color: c.gray500, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
        const SizedBox(height: 6),
        Row(children: [
          _HasChip(label: 'File', icon: Icons.attach_file, colors: c, onTap: () => _selectHasOption('file')),
          const SizedBox(width: 8),
          _HasChip(label: 'Image', icon: Icons.image_outlined, colors: c, onTap: () => _selectHasOption('image')),
          const SizedBox(width: 8),
          _HasChip(label: 'Link', icon: Icons.link, colors: c, onTap: () => _selectHasOption('link')),
        ]),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () {
            _controller.clear();
            setState(() => _pendingFilterType = null);
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Text('Cancel', style: TextStyle(color: c.gray500, fontSize: 12)),
          ),
        ),
      ]),
    );
  }

  Widget _buildMemberAutocomplete(InfernoColors c) {
    if (_memberSuggestions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Text('No members found', style: TextStyle(color: c.gray500, fontSize: 13)),
      );
    }
    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: c.gray900,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.gray700),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: _memberSuggestions.length,
        padding: EdgeInsets.zero,
        itemBuilder: (context, index) {
          final m = _memberSuggestions[index];
          final name = m.displayName ?? m.username ?? m.pubkey.substring(0, 8);
          final avatar = m.avatarUrl;
          return InkWell(
            onTap: () => _selectMember(m),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: c.gray700,
                  backgroundImage: avatar != null && avatar.startsWith('http') ? NetworkImage(avatar) : null,
                  child: avatar == null || !avatar.startsWith('http')
                      ? Text(name[0].toUpperCase(), style: TextStyle(color: c.gray400, fontSize: 12))
                      : null,
                ),
                const SizedBox(width: 8),
                Text(name, style: TextStyle(color: c.gray200, fontSize: 13)),
                if (m.username != null) ...[
                  const SizedBox(width: 6),
                  Text(m.username!, style: TextStyle(color: c.gray500, fontSize: 12)),
                ],
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _buildChannelAutocomplete(InfernoColors c) {
    if (_channelSuggestions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Text('No channels found', style: TextStyle(color: c.gray500, fontSize: 13)),
      );
    }
    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: c.gray900,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.gray700),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: _channelSuggestions.length,
        padding: EdgeInsets.zero,
        itemBuilder: (context, index) {
          final ch = _channelSuggestions[index];
          return InkWell(
            onTap: () => _selectChannel(ch),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(children: [
                Icon(ch.encrypted ? Icons.lock : Icons.tag, size: 16, color: c.gray500),
                const SizedBox(width: 8),
                Text(ch.name, style: TextStyle(color: c.gray200, fontSize: 13)),
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _buildResults(InfernoColors c) {
    if (_searching && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_results.isEmpty) {
      return Center(
        child: Text(
          _controller.text.isEmpty && _filters.isEmpty ? 'Type to search' : 'No results',
          style: TextStyle(color: c.gray500, fontSize: 13),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _results.length + (_hasMore ? 1 : 0) + 1, // +1 for count header
      itemBuilder: (context, index) {
        // Count header
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _totalCount == 1
                  ? '1 result'
                  : '$_totalCount results${_totalLoaded < _totalCount ? ' \u2022 showing $_totalLoaded' : ''}',
              style: TextStyle(color: c.gray500, fontSize: 12),
            ),
          );
        }

        final resultIndex = index - 1;

        // Load more button
        if (resultIndex == _results.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: _searching
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : GestureDetector(
                      onTap: _loadMore,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: c.gray900,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: c.gray700),
                          ),
                          child: Text(
                            'Load more (${_totalCount - _totalLoaded} remaining)',
                            style: TextStyle(color: c.gray400, fontSize: 13),
                          ),
                        ),
                      ),
                    ),
            ),
          );
        }

        final msg = _results[resultIndex];
        final channelName = _hasInFilters && msg.channelId != null ? _channelNames[msg.channelId] : null;
        return _SearchResult(
          message: msg,
          authorName: _authorNames[msg.nostrAuthorPubkey] ?? 'Unknown',
          authorAvatar: _authorAvatars[msg.nostrAuthorPubkey],
          channelName: channelName,
          colors: c,
          customEmojis: _customEmojis,
          onTap: () => _jumpToMessage(msg),
        );
      },
    );
  }
}

// ── Helper widgets ──

class _AddFilterButton extends StatefulWidget {
  final InfernoColors colors;
  final void Function(String filterType) onSelected;

  const _AddFilterButton({required this.colors, required this.onSelected});

  @override
  State<_AddFilterButton> createState() => _AddFilterButtonState();
}

class _AddFilterButtonState extends State<_AddFilterButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showMenu(context),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: _hovered ? widget.colors.accent.withValues(alpha: 0.15) : widget.colors.gray900,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: _hovered ? widget.colors.accent.withValues(alpha: 0.4) : widget.colors.gray700),
          ),
          child: Icon(Icons.add, size: 18, color: _hovered ? widget.colors.accent : widget.colors.gray400),
        ),
      ),
    );
  }

  void _showMenu(BuildContext context) {
    final c = widget.colors;
    final RenderBox box = context.findRenderObject() as RenderBox;
    final offset = box.localToGlobal(Offset.zero);

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        offset.dx - 160,
        offset.dy + box.size.height + 4,
        offset.dx + box.size.width,
        0,
      ),
      color: c.gray900,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: c.gray700),
      ),
      items: [
        _menuItem('from', Icons.person_outline, 'From user', c),
        _menuItem('in', Icons.tag, 'In channel', c),
        _menuItem('has', Icons.attach_file, 'Has type', c),
        _menuItem('before', Icons.calendar_today, 'Before date', c),
        _menuItem('after', Icons.calendar_today, 'After date', c),
        _menuItem('on', Icons.calendar_today, 'On date', c),
      ],
    ).then((value) {
      if (value != null) widget.onSelected(value);
    });
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label, InfernoColors c) {
    return PopupMenuItem<String>(
      value: value,
      height: 36,
      child: Row(children: [
        Icon(icon, size: 16, color: c.gray400),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: c.gray200, fontSize: 13)),
      ]),
    );
  }
}

class _HasChip extends StatefulWidget {
  final String label;
  final IconData icon;
  final InfernoColors colors;
  final VoidCallback onTap;

  const _HasChip({required this.label, required this.icon, required this.colors, required this.onTap});

  @override
  State<_HasChip> createState() => _HasChipState();
}

class _HasChipState extends State<_HasChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _hovered ? widget.colors.accent.withValues(alpha: 0.12) : widget.colors.gray900,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: _hovered ? widget.colors.accent.withValues(alpha: 0.4) : widget.colors.gray700),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(widget.icon, size: 14, color: _hovered ? widget.colors.accent : widget.colors.gray400),
            const SizedBox(width: 6),
            Text(widget.label, style: TextStyle(color: _hovered ? widget.colors.accent : widget.colors.gray400, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}

class _SearchResult extends StatelessWidget {
  final Message message;
  final String authorName;
  final String? authorAvatar;
  final String? channelName;
  final InfernoColors colors;
  final Map<String, String> customEmojis;
  final VoidCallback onTap;

  const _SearchResult({
    required this.message,
    required this.authorName,
    this.authorAvatar,
    this.channelName,
    required this.colors,
    this.customEmojis = const {},
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.all(10),
          margin: const EdgeInsets.only(bottom: 4),
          decoration: BoxDecoration(color: colors.gray900, borderRadius: BorderRadius.circular(6)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Channel name (when searching across channels)
            if (channelName != null) ...[
              Row(children: [
                Icon(Icons.tag, size: 12, color: colors.gray500),
                const SizedBox(width: 4),
                Text(channelName!, style: TextStyle(color: colors.gray500, fontSize: 11)),
              ]),
              const SizedBox(height: 4),
            ],
            // Author + timestamp
            Row(children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: colors.gray700,
                backgroundImage: authorAvatar != null && authorAvatar!.startsWith('http')
                    ? NetworkImage(authorAvatar!)
                    : null,
                child: authorAvatar == null || !authorAvatar!.startsWith('http')
                    ? Text(authorName[0].toUpperCase(), style: TextStyle(color: colors.gray400, fontSize: 10))
                    : null,
              ),
              const SizedBox(width: 8),
              Text(authorName, style: TextStyle(color: colors.accent, fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(DateFormat('MM/dd/yyyy h:mm a').format(message.createdAt),
                  style: TextStyle(color: colors.gray500, fontSize: 11)),
            ]),
            const SizedBox(height: 6),
            // Rendered message content — same widget as message history
            MessageContent(
              content: message.content ?? '',
              colors: colors,
              isSpoiler: message.spoiler,
              customEmojis: customEmojis,
              fileUrls: message.fileUrls,
            ),
          ]),
        ),
      ),
    );
  }
}
