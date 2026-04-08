import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/database_provider.dart';
import '../../services/prune_service.dart';
import '../../services/asset_cache_service.dart';
import '../../theme/all_themes.dart';
import '../../theme/theme_provider.dart';

class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});

  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  PruneStats? _stats;
  int _cacheSizeBytes = 0;
  bool _pruning = false;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final db = ref.read(databaseProvider);
    final pruneService = PruneService(db);
    final cacheService = AssetCacheService();
    final stats = await pruneService.getStats();
    final cacheSize = await cacheService.getCacheSize();
    if (mounted) setState(() { _stats = stats; _cacheSizeBytes = cacheSize; });
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Storage', style: TextStyle(color: c.gray50, fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 24),
        // Overview
        _SectionHeader('OVERVIEW', c),
        Card(
          color: c.gray900,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _StatRow('Database Size', _stats?.dbSizeFormatted ?? '...', c),
                _StatRow('Total Messages', '${_stats?.totalMessages ?? 0}', c),
                _StatRow('Visible Messages', '${_stats?.visibleMessages ?? 0}', c),
                const SizedBox(height: 8),
                _StatRow('Asset Cache', _formatBytes(_cacheSizeBytes), c),
                const SizedBox(height: 8),
                // Cache progress bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (_cacheSizeBytes / (500 * 1024 * 1024)).clamp(0.0, 1.0),
                    backgroundColor: c.gray800,
                    valueColor: AlwaysStoppedAnimation(
                      _cacheSizeBytes > 500 * 1024 * 1024 ? c.dnd
                          : _cacheSizeBytes > 400 * 1024 * 1024 ? c.idle
                          : c.online,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),

        // Actions
        _SectionHeader('ACTIONS', c),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _clearing ? null : () async {
                  setState(() => _clearing = true);
                  final cache = AssetCacheService();
                  final count = await cache.clearCache();
                  await _loadStats();
                  if (mounted) {
                    setState(() => _clearing = false);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cleared $count cached files')));
                  }
                },
                icon: _clearing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.delete_sweep),
                label: const Text('Clear Cache'),
                style: ElevatedButton.styleFrom(backgroundColor: c.gray800),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _pruning ? null : () async {
                  setState(() => _pruning = true);
                  final db = ref.read(databaseProvider);
                  final result = await PruneService(db).runPrune();
                  await _loadStats();
                  if (mounted) {
                    setState(() => _pruning = false);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Pruned ${result.messagesDeleted} messages, ${result.attachmentsPurged} attachments')),
                    );
                  }
                },
                icon: _pruning ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_delete),
                label: const Text('Run Prune'),
                style: ElevatedButton.styleFrom(backgroundColor: c.gray800),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  final InfernoColors c;
  const _SectionHeader(this.text, this.c);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: TextStyle(color: c.gray500, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1)),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;
  final InfernoColors c;
  const _StatRow(this.label, this.value, this.c);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: c.gray500, fontSize: 14)),
          Text(value, style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
