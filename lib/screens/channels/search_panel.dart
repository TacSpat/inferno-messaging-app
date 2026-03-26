import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/database.dart';
import '../../providers/database_provider.dart';
import '../../theme/all_themes.dart';

/// Right-side search panel for channel/server-wide message search.
/// Matches Rails: search field in channel header, results with author + timestamp.
class SearchPanel extends ConsumerStatefulWidget {
  final int? channelId;
  final int? serverId;
  final VoidCallback onClose;

  const SearchPanel({super.key, this.channelId, this.serverId, required this.onClose});

  @override
  ConsumerState<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends ConsumerState<SearchPanel> {
  final _controller = TextEditingController();
  List<Message> _results = [];
  bool _searching = false;
  bool _serverWide = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) { setState(() => _results = []); return; }

    setState(() => _searching = true);
    final db = ref.read(databaseProvider);

    final selectQuery = db.select(db.messages)
      ..where((m) => m.content.like('%$query%'))
      ..orderBy([(m) => OrderingTerm.desc(m.createdAt)])
      ..limit(50);

    if (!_serverWide && widget.channelId != null) {
      selectQuery.where((m) => m.channelId.equals(widget.channelId!));
    }

    final results = await selectQuery.get();
    if (mounted) setState(() { _results = results; _searching = false; });
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<InfernoColors>()!;

    return Container(
      width: 340,
      color: c.gray800,
      child: Column(children: [
        // Header
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.gray900))),
          child: Row(children: [
            Icon(Icons.search, size: 18, color: c.gray400),
            const SizedBox(width: 8),
            Expanded(child: Text('Search', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14))),
            GestureDetector(onTap: widget.onClose, child: Icon(Icons.close, size: 18, color: c.gray400)),
          ]),
        ),
        // Search input
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _controller,
            autofocus: true,
            onSubmitted: (_) => _search(),
            style: TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Search messages...',
              hintStyle: TextStyle(color: c.gray500),
              fillColor: c.gray900, filled: true,
              prefixIcon: Icon(Icons.search, size: 18, color: c.gray500),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.accent)),
            ),
          ),
        ),
        // Scope toggle
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            GestureDetector(
              onTap: () => setState(() { _serverWide = false; _search(); }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: !_serverWide ? c.accent.withValues(alpha: 0.2) : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('This Channel', style: TextStyle(color: !_serverWide ? c.accent : c.gray400, fontSize: 12)),
              ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => setState(() { _serverWide = true; _search(); }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _serverWide ? c.accent.withValues(alpha: 0.2) : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('Server-wide', style: TextStyle(color: _serverWide ? c.accent : c.gray400, fontSize: 12)),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 8),
        // Results
        Expanded(
          child: _searching
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _results.isEmpty
                  ? Center(child: Text(
                      _controller.text.isEmpty ? 'Type to search' : 'No results',
                      style: TextStyle(color: c.gray500, fontSize: 13)))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final msg = _results[index];
                        final author = msg.nostrAuthorPubkey != null ? '${msg.nostrAuthorPubkey!.substring(0, 8)}...' : 'Unknown';
                        return Container(
                          padding: const EdgeInsets.all(10),
                          margin: const EdgeInsets.only(bottom: 4),
                          decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(6)),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Text(author, style: TextStyle(color: c.accent, fontSize: 12, fontWeight: FontWeight.w600)),
                              const Spacer(),
                              Text(_formatDate(msg.createdAt), style: TextStyle(color: c.gray500, fontSize: 11)),
                            ]),
                            const SizedBox(height: 4),
                            Text(msg.content ?? '', style: TextStyle(color: c.gray200, fontSize: 13), maxLines: 3, overflow: TextOverflow.ellipsis),
                          ]),
                        );
                      },
                    ),
        ),
      ]),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }
}
