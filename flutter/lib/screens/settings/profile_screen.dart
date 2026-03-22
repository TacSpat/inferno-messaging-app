import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/auth_provider.dart';
import '../../providers/database_provider.dart';
import '../../theme/all_themes.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _displayNameController = TextEditingController();
  final _bioController = TextEditingController();
  final _avatarUrlController = TextEditingController();
  final _bannerUrlController = TextEditingController();
  bool _dirty = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadExistingProfile();
  }

  Future<void> _loadExistingProfile() async {
    final auth = ref.read(authServiceProvider);
    if (auth.publicKeyHex == null) return;
    final db = ref.read(databaseProvider);
    final contact = await db.contactsDao.getByPubkey(auth.publicKeyHex!);
    if (contact != null && mounted) {
      setState(() {
        _displayNameController.text = contact.displayName ?? contact.username ?? '';
        _bioController.text = contact.bio ?? '';
        _avatarUrlController.text = contact.avatarUrl ?? '';
        _bannerUrlController.text = contact.bannerUrl ?? '';
        _loaded = true;
      });
    } else {
      if (mounted) setState(() => _loaded = true);
    }
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _bioController.dispose();
    _avatarUrlController.dispose();
    _bannerUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<InfernoColors>()!;
    final avatarUrl = _avatarUrlController.text.trim();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Text('Profile', style: TextStyle(color: c.gray50, fontSize: 20, fontWeight: FontWeight.w600)),
            const Spacer(),
            if (_dirty)
              TextButton(
                onPressed: () async {
                  final authService = ref.read(authServiceProvider);
                  final profileService = ref.read(profileServiceProvider);
                  if (authService.privateKeyHex != null) {
                    await profileService.publishProfile(
                      privateKeyHex: authService.privateKeyHex!,
                      publicKeyHex: authService.publicKeyHex!,
                      username: _displayNameController.text.isNotEmpty ? _displayNameController.text : 'user',
                      displayName: _displayNameController.text.isNotEmpty ? _displayNameController.text : null,
                      about: _bioController.text.isNotEmpty ? _bioController.text : null,
                      pictureUrl: _avatarUrlController.text.isNotEmpty ? _avatarUrlController.text : null,
                      bannerUrl: _bannerUrlController.text.isNotEmpty ? _bannerUrlController.text : null,
                    );
                  }
                  setState(() => _dirty = false);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile saved')));
                  }
                },
                child: Text('Save', style: TextStyle(color: c.accent)),
              ),
          ],
        ),
        const SizedBox(height: 24),
        // Avatar preview — shows actual avatar if URL is set
        Center(
          child: CircleAvatar(
            radius: 48,
            backgroundColor: c.gray800,
            backgroundImage: avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
            child: avatarUrl.isEmpty ? Icon(Icons.person, size: 48, color: c.gray500) : null,
          ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _displayNameController,
          style: TextStyle(color: c.gray200),
          decoration: InputDecoration(labelText: 'Display Name', labelStyle: TextStyle(color: c.gray500)),
          onChanged: (_) => setState(() => _dirty = true),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _bioController,
          style: TextStyle(color: c.gray200),
          decoration: InputDecoration(labelText: 'Bio', labelStyle: TextStyle(color: c.gray500)),
          maxLines: 3,
          onChanged: (_) => setState(() => _dirty = true),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _avatarUrlController,
          style: TextStyle(color: c.gray200),
          decoration: InputDecoration(labelText: 'Avatar URL', hintText: 'Blossom URL or image link', labelStyle: TextStyle(color: c.gray500), hintStyle: TextStyle(color: c.gray600)),
          onChanged: (_) => setState(() => _dirty = true),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _bannerUrlController,
          style: TextStyle(color: c.gray200),
          decoration: InputDecoration(labelText: 'Banner URL', hintText: 'Blossom URL or image link', labelStyle: TextStyle(color: c.gray500), hintStyle: TextStyle(color: c.gray600)),
          onChanged: (_) => setState(() => _dirty = true),
        ),
      ],
    );
  }
}
