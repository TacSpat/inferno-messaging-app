import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';

class MemberList extends ConsumerWidget {
  final int serverId;

  const MemberList({super.key, required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);

    return Container(
      width: 240,
      color: const Color(0xFF16213E),
      child: Column(
        children: [
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.centerLeft,
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF2A3A5C))),
            ),
            child: const Text(
              'Members',
              style: TextStyle(
                color: Color(0xFF8899A6),
                fontWeight: FontWeight.bold,
                fontSize: 12,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<RemoteMember>>(
              stream: db.serversDao.watchRemoteMembers(serverId),
              builder: (context, snapshot) {
                final members = snapshot.data ?? [];
                if (members.isEmpty) {
                  return const Center(
                    child: Text('No members', style: TextStyle(color: Color(0xFF8899A6))),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: members.length,
                  itemBuilder: (context, index) {
                    final member = members[index];
                    final name = member.displayName ?? member.username ?? '${member.pubkey.substring(0, 8)}...';
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 16,
                        backgroundColor: const Color(0xFF2A3A5C),
                        backgroundImage: member.avatarUrl != null ? NetworkImage(member.avatarUrl!) : null,
                        child: member.avatarUrl == null
                            ? Text(name[0].toUpperCase(), style: const TextStyle(fontSize: 12, color: Color(0xFFE0E0E0)))
                            : null,
                      ),
                      title: Text(name, style: const TextStyle(color: Color(0xFFE0E0E0), fontSize: 14)),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
