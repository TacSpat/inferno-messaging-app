import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/database.dart';
import '../../models/permission.dart';
import '../../providers/server_settings_provider.dart';

class RoleEditorScreen extends ConsumerStatefulWidget {
  final Role role;
  final int serverId;

  const RoleEditorScreen({super.key, required this.role, required this.serverId});

  @override
  ConsumerState<RoleEditorScreen> createState() => _RoleEditorScreenState();
}

class _RoleEditorScreenState extends ConsumerState<RoleEditorScreen> {
  late Map<String, bool> _permissions;
  late TextEditingController _nameController;
  late TextEditingController _colorController;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.role.name ?? '');
    _colorController = TextEditingController(text: widget.role.color ?? '#ffffff');
    try {
      _permissions = Map<String, bool>.from(
        json.decode(widget.role.permissions ?? '{}') as Map,
      );
    } catch (_) {
      _permissions = {};
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _colorController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final roleService = ref.read(roleServiceProvider);
    await roleService.updateRole(
      widget.role.id,
      name: _nameController.text,
      color: _colorController.text,
    );
    await roleService.updatePermissions(widget.role.id, _permissions);
    if (mounted) {
      setState(() => _dirty = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Role saved')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSystemRole = widget.role.name == '@everyone' || widget.role.name == 'Owner';

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.role.name ?? 'Edit Role'),
        actions: [
          if (_dirty)
            TextButton(
              onPressed: _save,
              child: const Text('Save', style: TextStyle(color: Color(0xFFE85D3A))),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Name & color
          if (!isSystemRole) ...[
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Role Name'),
              onChanged: (_) => setState(() => _dirty = true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _colorController,
              decoration: const InputDecoration(labelText: 'Color (hex)', hintText: '#ff5733'),
              onChanged: (_) => setState(() => _dirty = true),
            ),
            const SizedBox(height: 24),
          ],
          // Permission matrix grouped by category
          for (final category in PermissionCategory.values) ...[
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: Text(
                category.label.toUpperCase(),
                style: const TextStyle(
                  color: Color(0xFF8899A6),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
            ),
            for (final perm in Permission.values.where((p) => p.category == category))
              SwitchListTile(
                title: Text(perm.label, style: const TextStyle(color: Color(0xFFE0E0E0), fontSize: 14)),
                value: _permissions[perm.key] ?? perm.defaultValue,
                activeTrackColor: const Color(0xFFE85D3A),
                onChanged: isSystemRole && (perm == Permission.owner)
                    ? null
                    : (value) {
                        setState(() {
                          _permissions[perm.key] = value;
                          _dirty = true;
                        });
                      },
              ),
          ],
        ],
      ),
    );
  }
}
