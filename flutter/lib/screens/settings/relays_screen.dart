import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/database.dart';
import '../../providers/database_provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/relay_config_service.dart';
import '../../theme/theme_provider.dart';

class RelaysScreen extends ConsumerStatefulWidget {
  const RelaysScreen({super.key});

  @override
  ConsumerState<RelaysScreen> createState() => _RelaysScreenState();
}

class _RelaysScreenState extends ConsumerState<RelaysScreen> {
  late RelayConfigService _relayConfig;

  @override
  void initState() {
    super.initState();
    _relayConfig = RelayConfigService(ref.read(databaseProvider));
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);

    return StreamBuilder<List<RelayConnection>>(
      stream: _relayConfig.watchAllRelays(),
      builder: (context, snapshot) {
        final relays = snapshot.data ?? [];
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Relays', style: TextStyle(color: c.gray50, fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 24),
            for (final relay in relays)
              Card(
                color: c.gray900,
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(
                    relay.status == 'active' ? Icons.check_circle : Icons.error,
                    color: relay.status == 'active' ? c.online : c.dnd,
                  ),
                  title: Text(relay.url, style: TextStyle(color: c.gray200, fontSize: 13)),
                  subtitle: Text('Retries: ${relay.retryCount}',
                    style: TextStyle(color: c.gray500, fontSize: 11)),
                  trailing: IconButton(
                    icon: Icon(Icons.delete, color: c.dnd, size: 20),
                    onPressed: () {
                      _relayConfig.removeRelay(relay.url);
                      ref.read(relayPoolProvider).removeRelay(relay.url);
                    },
                  ),
                ),
              ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _showAddRelayDialog(context),
              icon: const Icon(Icons.add),
              label: const Text('Add Relay'),
            ),
          ],
        );
      },
    );
  }

  void _showAddRelayDialog(BuildContext context) {
    final controller = TextEditingController(text: 'wss://');
    final c = ref.read(infernoColorsProvider);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.gray950,
        title: const Text('Add Relay'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'wss://relay.example.com'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final url = controller.text.trim();
              if (url.startsWith('wss://') || url.startsWith('ws://')) {
                await _relayConfig.addRelay(url);
                final pool = ref.read(relayPoolProvider);
                pool.addRelay(url);
                Navigator.pop(ctx);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}
