import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/server_settings_provider.dart';
import 'role_editor_screen.dart';

class RolesScreen extends ConsumerWidget {
  final int serverId;
  const RolesScreen({super.key, required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rolesAsync = ref.watch(serverRolesProvider(serverId));

    return Scaffold(
      appBar: AppBar(title: const Text('Roles')),
      body: rolesAsync.when(
        data: (roles) {
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: roles.length,
            itemBuilder: (context, index) {
              final role = roles[index];
              final color = _parseColor(role.color);
              return Card(
                color: const Color(0xFF1E2A4A),
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Container(
                    width: 16, height: 16,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  title: Text(role.name ?? 'Unnamed', style: TextStyle(color: color)),
                  subtitle: Text('Position: ${role.position ?? 0}',
                    style: const TextStyle(color: Color(0xFF8899A6), fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right, color: Color(0xFF8899A6)),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (ctx) => RoleEditorScreen(role: role, serverId: serverId),
                    ),
                  ),
                ),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFFE85D3A),
        onPressed: () async {
          final roleService = ref.read(roleServiceProvider);
          await roleService.createRole(serverId: serverId, name: 'New Role');
        },
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Color _parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return const Color(0xFFE0E0E0);
    try {
      return Color(int.parse(hex.replaceFirst('#', 'FF'), radix: 16));
    } catch (_) {
      return const Color(0xFFE0E0E0);
    }
  }
}
