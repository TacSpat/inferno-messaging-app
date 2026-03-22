import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/server_settings_provider.dart';

class BansScreen extends ConsumerWidget {
  final int serverId;
  const BansScreen({super.key, required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bansAsync = ref.watch(serverBansProvider(serverId));

    return Scaffold(
      appBar: AppBar(title: const Text('Bans')),
      body: bansAsync.when(
        data: (bans) {
          if (bans.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.gavel, size: 48, color: Color(0xFF5C6B77)),
                  SizedBox(height: 16),
                  Text('No bans', style: TextStyle(color: Color(0xFF8899A6))),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: bans.length,
            itemBuilder: (context, index) {
              final ban = bans[index];
              return Card(
                color: const Color(0xFF1E2A4A),
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFF3A1A1A),
                    child: Icon(Icons.block, color: Color(0xFFFF4D4D)),
                  ),
                  title: Text('User #${ban.userId}',
                    style: const TextStyle(color: Color(0xFFE0E0E0))),
                  subtitle: ban.reason != null
                      ? Text(ban.reason!, style: const TextStyle(color: Color(0xFF8899A6), fontSize: 12))
                      : null,
                  trailing: TextButton(
                    onPressed: () async {
                      final memberService = ref.read(memberServiceProvider);
                      await memberService.unbanMember(serverId, ban.userId);
                    },
                    child: const Text('Unban', style: TextStyle(color: Color(0xFF4CAF50))),
                  ),
                ),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }
}
