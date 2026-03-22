import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/server_settings_provider.dart';

class MembersScreen extends ConsumerWidget {
  final int serverId;
  const MembersScreen({super.key, required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final membershipsAsync = ref.watch(serverMembershipsProvider(serverId));

    return Scaffold(
      appBar: AppBar(title: const Text('Members')),
      body: membershipsAsync.when(
        data: (memberships) {
          if (memberships.isEmpty) {
            return const Center(child: Text('No members', style: TextStyle(color: Color(0xFF8899A6))));
          }
          return ListView.builder(
            itemCount: memberships.length,
            itemBuilder: (context, index) {
              final membership = memberships[index];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: const Color(0xFF2A3A5C),
                  child: Text('${membership.userId}'.substring(0, 1),
                    style: const TextStyle(color: Color(0xFFE0E0E0))),
                ),
                title: Text(membership.nickname ?? 'Member #${membership.userId}',
                  style: const TextStyle(color: Color(0xFFE0E0E0))),
                subtitle: Text('Joined ${membership.joinedAt?.toString().substring(0, 10) ?? 'unknown'}',
                  style: const TextStyle(color: Color(0xFF8899A6), fontSize: 12)),
                trailing: PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, color: Color(0xFF8899A6)),
                  color: const Color(0xFF16213E),
                  onSelected: (action) {
                    // TODO: implement kick/ban/timeout actions
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'kick', child: Text('Kick', style: TextStyle(color: Color(0xFFFF4D4D)))),
                    const PopupMenuItem(value: 'ban', child: Text('Ban', style: TextStyle(color: Color(0xFFFF4D4D)))),
                    const PopupMenuItem(value: 'timeout', child: Text('Timeout', style: TextStyle(color: Color(0xFFFF9800)))),
                  ],
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
