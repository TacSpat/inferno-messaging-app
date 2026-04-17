import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/database.dart';
import '../../models/permission.dart';
import '../../providers/database_provider.dart';
import '../../providers/server_settings_provider.dart';
import '../../providers/servers_provider.dart';

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
  bool _refreshing = true;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.role.name ?? '');
    _colorController = TextEditingController(text: widget.role.color ?? '#ffffff');
    _permissions = _decodePermissions(widget.role.permissions);
    // The role passed in is the last-cached snapshot — fetch Kind 31752 from
    // relays so the permission toggles reflect what's actually published, not
    // whatever was in the DB when the list was first loaded.
    _refreshFromRelays();
  }

  Map<String, bool> _decodePermissions(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, bool>.from(json.decode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> _refreshFromRelays() async {
    try {
      await ref.read(serverSyncServiceProvider).refreshRoles(widget.serverId);
      final db = ref.read(databaseProvider);
      final fresh = await (db.select(db.roles)..where((r) => r.id.equals(widget.role.id)))
          .getSingleOrNull();
      if (!mounted || fresh == null) return;
      // Don't clobber unsaved user edits.
      if (_dirty) {
        setState(() => _refreshing = false);
        return;
      }
      setState(() {
        _permissions = _decodePermissions(fresh.permissions);
        _nameController.text = fresh.name ?? _nameController.text;
        _colorController.text = fresh.color ?? _colorController.text;
        _refreshing = false;
      });
    } catch (_) {
      if (mounted) setState(() => _refreshing = false);
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
          if (_refreshing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
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
