import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/database.dart';
import '../../providers/auth_provider.dart';
import '../../providers/database_provider.dart';
import '../../services/blossom_client.dart';
import '../../theme/all_themes.dart';
import '../../theme/theme_provider.dart';
import '../../utils/url_utils.dart';
import '../../widgets/image_crop_dialog.dart';

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
  final _statusController = TextEditingController();
  String _statusEmoji = '😊';
  Color _color1 = const Color(0xFF1e1c1b);
  Color _color2 = const Color(0xFF1e1c1b);
  bool _dirty = false;
  bool _loaded = false;
  bool _saving = false;

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

    // Get profile colors from remote_members
    final members = await (db.select(db.remoteMembers)
      ..where((m) => m.pubkey.equals(auth.publicKeyHex!))
      ..limit(5)).get();
    String? profileColor, profileColor2;
    for (final rm in members) {
      if (rm.profileColor != null && rm.profileColor!.isNotEmpty) {
        profileColor = rm.profileColor;
        profileColor2 = rm.profileColor2;
        break;
      }
    }

    if (mounted) {
      setState(() {
        _displayNameController.text = contact?.displayName ?? contact?.username ?? '';
        _bioController.text = contact?.bio ?? '';
        _avatarUrlController.text = contact?.avatarUrl ?? '';
        _bannerUrlController.text = contact?.bannerUrl ?? '';
        _statusController.text = contact?.status ?? '';
        _statusEmoji = contact?.statusEmoji ?? '😊';
        if (profileColor != null) _color1 = _parseColor(profileColor) ?? _color1;
        if (profileColor2 != null) _color2 = _parseColor(profileColor2) ?? _color2;
        _loaded = true;
      });
    }
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _bioController.dispose();
    _avatarUrlController.dispose();
    _bannerUrlController.dispose();
    _statusController.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
    // Trigger preview rebuild
    setState(() {});
  }

  String _colorToHex(Color c) => '#${c.toARGB32().toRadixString(16).substring(2)}';

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final auth = ref.read(authServiceProvider);
      final db = ref.read(databaseProvider);
      final profileService = ref.read(profileServiceProvider);
      if (auth.privateKeyHex != null) {
        // Persist profile colors to all remoteMembers rows for this user
        // (colors are server-specific, stored in remoteMembers, published in Kind 31753)
        final colorHex1 = _colorToHex(_color1);
        final colorHex2 = _colorToHex(_color2);
        await (db.update(db.remoteMembers)
              ..where((m) => m.pubkey.equals(auth.publicKeyHex!)))
            .write(RemoteMembersCompanion(
          profileColor: Value(colorHex1),
          profileColor2: Value(colorHex2),
          updatedAt: Value(DateTime.now()),
        ));

        final results = await profileService.publishProfile(
          privateKeyHex: auth.privateKeyHex!,
          publicKeyHex: auth.publicKeyHex!,
          username: _displayNameController.text.isNotEmpty ? _displayNameController.text : 'user',
          displayName: _displayNameController.text.isNotEmpty ? _displayNameController.text : null,
          about: _bioController.text.isNotEmpty ? _bioController.text : null,
          pictureUrl: _avatarUrlController.text.isNotEmpty ? _avatarUrlController.text : null,
          bannerUrl: _bannerUrlController.text.isNotEmpty ? _bannerUrlController.text : null,
          status: _statusController.text.isNotEmpty ? _statusController.text : null,
          statusEmoji: _statusEmoji.isNotEmpty ? _statusEmoji : null,
        );
        final okCount = results.values.where((v) => v).length;
        if (mounted) {
          setState(() { _dirty = false; _saving = false; });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Profile published to $okCount/${results.length} relays')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);

    if (!_loaded) {
      return Center(child: CircularProgressIndicator(color: c.accent));
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left: Form
        Expanded(
          flex: 3,
          child: ListView(
            padding: const EdgeInsets.only(right: 32),
            children: [
              Text('Profile', style: TextStyle(color: c.gray50, fontSize: 20, fontWeight: FontWeight.w600)),
              const SizedBox(height: 24),
              _buildBannerAvatarCard(c),
              const SizedBox(height: 20),
              _buildThemeCard(c),
              const SizedBox(height: 20),
              _buildFieldsCard(c),
              const SizedBox(height: 20),
              _buildSaveButton(c),
              const SizedBox(height: 32),
            ],
          ),
        ),
        // Right: Live preview
        SizedBox(
          width: 280,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('PREVIEW', style: TextStyle(color: c.gray500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
              ),
              _buildPreviewCard(c),
            ],
          ),
        ),
      ],
    );
  }

  // ── Banner + Avatar card ──

  Widget _buildBannerAvatarCard(InfernoColors c) {
    final bannerUrl = validImageUrl(_bannerUrlController.text.trim());
    final avatarUrl = validImageUrl(_avatarUrlController.text.trim());
    final initial = _displayNameController.text.isNotEmpty
        ? _displayNameController.text[0].toUpperCase()
        : '?';

    return Container(
      decoration: BoxDecoration(
        color: c.gray800,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Banner
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => _showImageDialog('Banner', _bannerUrlController, cropMode: CropMode.banner),
              child: ClipRRect(
                borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
                child: Container(
                  height: 128,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [_color1, _color2],
                    ),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (bannerUrl != null)
                        Image.network(bannerUrl, fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox()),
                      // Hover overlay
                      _HoverOverlay(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.photo_library_outlined, color: Colors.white, size: 24),
                            const SizedBox(height: 4),
                            Text('Change Banner', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Avatar
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Transform.translate(
                  offset: const Offset(0, -40),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => _showImageDialog('Avatar', _avatarUrlController, cropMode: CropMode.avatar),
                      child: Container(
                        width: 80, height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: c.gray800, width: 4),
                          color: _color1,
                        ),
                        child: ClipOval(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (avatarUrl != null)
                                Image.network(avatarUrl, fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => Center(
                                    child: Text(initial, style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
                                  ))
                              else
                                Center(child: Text(initial, style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold))),
                              _HoverOverlay(
                                child: Icon(Icons.camera_alt_outlined, color: Colors.white, size: 20),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Transform.translate(
                  offset: const Offset(0, -32),
                  child: Text('Click to change avatar', style: TextStyle(color: c.gray500, fontSize: 11)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Theme card ──

  Widget _buildThemeCard(InfernoColors c) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.gray800,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fieldLabel('PROFILE THEME', c),
          const SizedBox(height: 12),
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Color 1', style: TextStyle(color: c.gray500, fontSize: 10, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  _ColorSwatch(color: _color1, onTap: () => _showColorPicker(1)),
                ],
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Color 2', style: TextStyle(color: c.gray500, fontSize: 10, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  _ColorSwatch(color: _color2, onTap: () => _showColorPicker(2)),
                ],
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Preview', style: TextStyle(color: c.gray500, fontSize: 10, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Container(
                      height: 32,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft, end: Alignment.bottomRight,
                          colors: [_color1, _color2],
                        ),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: c.gray600),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Fields card ──

  Widget _buildFieldsCard(InfernoColors c) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.gray800,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Display Name
          _fieldLabel('DISPLAY NAME', c),
          const SizedBox(height: 8),
          _textField(_displayNameController, c, suffixIcon: Icons.emoji_emotions_outlined),
          const SizedBox(height: 16),
          // About Me
          _fieldLabel('ABOUT ME', c),
          const SizedBox(height: 8),
          TextField(
            controller: _bioController,
            style: TextStyle(color: c.gray200, fontSize: 14),
            maxLines: 4,
            maxLength: 500,
            onChanged: (_) => _markDirty(),
            decoration: InputDecoration(
              filled: true, fillColor: c.gray900,
              hintText: 'Tell others about yourself',
              hintStyle: TextStyle(color: c.gray600, fontSize: 14),
              counterStyle: TextStyle(color: c.gray600, fontSize: 11),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent.withValues(alpha: 0.5))),
            ),
          ),
          const SizedBox(height: 16),
          // Custom Status
          _fieldLabel('CUSTOM STATUS', c),
          const SizedBox(height: 8),
          Row(
            children: [
              // Emoji button
              GestureDetector(
                onTap: _showEmojiPicker,
                child: Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: c.gray900,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
                  ),
                  child: Center(child: _buildStatusEmojiDisplay()),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _statusController,
                  style: TextStyle(color: c.gray200, fontSize: 14),
                  onChanged: (_) => _markDirty(),
                  decoration: InputDecoration(
                    filled: true, fillColor: c.gray900,
                    hintText: 'What are you up to?',
                    hintStyle: TextStyle(color: c.gray600, fontSize: 14),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent.withValues(alpha: 0.5))),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Save button ──

  Widget _buildSaveButton(InfernoColors c) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _dirty && !_saving ? _save : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: c.accent,
          disabledBackgroundColor: c.accent.withValues(alpha: 0.4),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: _saving
            ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : const Text('Save Changes', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      ),
    );
  }

  // ── Live preview card (matches user_profile_card.dart _CardContent) ──

  Widget _buildPreviewCard(InfernoColors c) {
    final bannerUrl = validImageUrl(_bannerUrlController.text.trim());
    final avatarUrl = validImageUrl(_avatarUrlController.text.trim());
    final displayName = _displayNameController.text.isNotEmpty ? _displayNameController.text : 'Display Name';
    final bio = _bioController.text;
    final status = _statusController.text;
    final initial = displayName[0].toUpperCase();
    final profileTint = Color.lerp(_color1, _color2, 0.4)!;

    return Container(
      width: 280,
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_color1, _color2]),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.gray600),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 20, offset: const Offset(0, 6))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Banner
          ClipRRect(
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
            child: Container(
              height: 60,
              width: double.infinity,
              color: c.gray700,
              child: bannerUrl != null
                  ? Image.network(bannerUrl, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox())
                  : null,
            ),
          ),
          // Avatar
          Transform.translate(
            offset: const Offset(0, -26),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Container(
                  width: 52, height: 52,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: profileTint),
                  padding: const EdgeInsets.all(3),
                  child: Container(
                    width: 46, height: 46,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: avatarUrl != null ? Colors.transparent : _color1,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: avatarUrl != null
                        ? Image.network(avatarUrl, fit: BoxFit.cover, width: 46, height: 46,
                            errorBuilder: (_, _, _) => Center(child: Text(initial, style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))))
                        : Center(child: Text(initial, style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
                  ),
                ),
              ]),
            ),
          ),
          // Info card
          Container(
            margin: const EdgeInsets.only(left: 12, right: 12, bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(displayName, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                if (status.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildStatusEmojiInline(_statusEmoji, size: 14),
                      const SizedBox(width: 2),
                      Flexible(child: Text(status, style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12))),
                    ],
                  ),
                ],
                if (bio.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(height: 1, color: Colors.white.withValues(alpha: 0.1)),
                  const SizedBox(height: 8),
                  Text('ABOUT ME', style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 10, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(bio, style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12, height: 1.4),
                    maxLines: 4, overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Helpers ──

  /// Renders status emoji — custom `:name:` as image, Unicode as text.
  Widget _buildStatusEmojiDisplay() {
    if (_statusEmoji.startsWith(':') && _statusEmoji.endsWith(':') && _statusEmoji.length > 2) {
      // Custom emoji shortcode — resolve URL from DB
      return FutureBuilder<ServerEmoji?>(
        future: _resolveCustomEmoji(_statusEmoji),
        builder: (_, snap) {
          if (snap.data?.url != null) {
            return CachedNetworkImage(imageUrl: snap.data!.url!, width: 22, height: 22, fit: BoxFit.contain);
          }
          return Text(_statusEmoji, style: const TextStyle(fontSize: 12, color: Colors.white54));
        },
      );
    }
    return Text(_statusEmoji, style: const TextStyle(fontSize: 18));
  }

  Future<ServerEmoji?> _resolveCustomEmoji(String shortcode) async {
    final name = shortcode.replaceAll(':', '');
    final db = ref.read(databaseProvider);
    return (db.select(db.serverEmojis)..where((e) => e.name.equals(name))..limit(1)).getSingleOrNull();
  }

  /// Renders status emoji inline for the preview card.
  Widget _buildStatusEmojiInline(String emoji, {double size = 14}) {
    if (emoji.startsWith(':') && emoji.endsWith(':') && emoji.length > 2) {
      return FutureBuilder<ServerEmoji?>(
        future: _resolveCustomEmoji(emoji),
        builder: (_, snap) {
          if (snap.data?.url != null) {
            return Padding(
              padding: const EdgeInsets.only(right: 4),
              child: CachedNetworkImage(imageUrl: snap.data!.url!, width: size, height: size, fit: BoxFit.contain),
            );
          }
          return Text(emoji, style: TextStyle(fontSize: size - 2, color: Colors.white54));
        },
      );
    }
    return Text(emoji, style: TextStyle(fontSize: size));
  }

  Widget _fieldLabel(String text, InfernoColors c) {
    return Text(text, style: TextStyle(color: c.gray500, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5));
  }

  Widget _textField(TextEditingController controller, InfernoColors c, {IconData? suffixIcon}) {
    return TextField(
      controller: controller,
      style: TextStyle(color: c.gray200, fontSize: 14),
      onChanged: (_) => _markDirty(),
      decoration: InputDecoration(
        filled: true, fillColor: c.gray900,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        suffixIcon: suffixIcon != null
            ? Icon(suffixIcon, color: c.gray500, size: 18)
            : null,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent.withValues(alpha: 0.5))),
      ),
    );
  }

  Future<void> _showImageDialog(String title, TextEditingController target, {CropMode cropMode = CropMode.banner}) async {
    final urlController = TextEditingController(text: target.text);
    final c = ref.read(infernoColorsProvider);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        var uploading = false;
        return StatefulBuilder(builder: (ctx, setDialogState) {
          return AlertDialog(
            backgroundColor: c.gray800,
            title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16)),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Live preview of whatever URL is currently in the field so
                  // the user can see their existing image before editing.
                  _ImagePreview(
                    url: urlController.text,
                    mode: cropMode,
                    colors: c,
                  ),
                  const SizedBox(height: 12),
                  // Upload a new image + crop.
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.gray200,
                      side: BorderSide(color: c.gray600),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: uploading ? null : () async {
                      final picked = await FilePicker.platform.pickFiles(
                        type: FileType.image,
                        allowMultiple: false,
                      );
                      if (picked == null || picked.files.isEmpty) return;
                      final path = picked.files.first.path;
                      if (path == null) return;
                      final bytes = await File(path).readAsBytes();
                      if (!ctx.mounted) return;
                      final cropped = await showImageCropDialog(
                        ctx,
                        imageBytes: bytes,
                        mode: cropMode,
                        backgroundColor: c.gray800,
                        accentColor: c.accent,
                      );
                      if (cropped == null || !ctx.mounted) return;
                      setDialogState(() => uploading = true);
                      final auth = ref.read(authServiceProvider);
                      if (auth.privateKeyHex == null) {
                        setDialogState(() => uploading = false);
                        return;
                      }
                      final url = await BlossomClient.upload(
                        fileBytes: cropped,
                        privateKeyHex: auth.privateKeyHex!,
                        publicKeyHex: auth.publicKeyHex!,
                        contentType: 'image/png',
                      );
                      setDialogState(() => uploading = false);
                      if (url != null) {
                        setDialogState(() => urlController.text = url);
                      } else if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text('Upload failed')),
                        );
                      }
                    },
                    icon: uploading
                        ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: c.gray200))
                        : const Icon(Icons.upload_file, size: 18),
                    label: Text(uploading ? 'Uploading...' : 'Upload Image'),
                  ),
                  const SizedBox(height: 8),
                  // Edit placement on the currently-set image (fetches bytes
                  // from the URL → crop dialog → re-uploads).
                  if (urlController.text.trim().isNotEmpty)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: c.gray200,
                        side: BorderSide(color: c.gray600),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: uploading ? null : () async {
                        setDialogState(() => uploading = true);
                        try {
                          final resp = await http.get(Uri.parse(urlController.text.trim()));
                          if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
                          final bytes = resp.bodyBytes;
                          if (!ctx.mounted) return;
                          final cropped = await showImageCropDialog(
                            ctx,
                            imageBytes: bytes,
                            mode: cropMode,
                            backgroundColor: c.gray800,
                            accentColor: c.accent,
                          );
                          if (cropped == null || !ctx.mounted) {
                            setDialogState(() => uploading = false);
                            return;
                          }
                          final auth = ref.read(authServiceProvider);
                          if (auth.privateKeyHex == null) {
                            setDialogState(() => uploading = false);
                            return;
                          }
                          final url = await BlossomClient.upload(
                            fileBytes: cropped,
                            privateKeyHex: auth.privateKeyHex!,
                            publicKeyHex: auth.publicKeyHex!,
                            contentType: 'image/png',
                          );
                          setDialogState(() => uploading = false);
                          if (url != null) {
                            setDialogState(() => urlController.text = url);
                          } else if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              const SnackBar(content: Text('Upload failed')),
                            );
                          }
                        } catch (e) {
                          setDialogState(() => uploading = false);
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(content: Text('Could not load current image: $e')),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.crop, size: 18),
                      label: const Text('Edit Placement'),
                    ),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(child: Divider(color: c.gray600)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text('or paste URL', style: TextStyle(color: c.gray500, fontSize: 12)),
                    ),
                    Expanded(child: Divider(color: c.gray600)),
                  ]),
                  const SizedBox(height: 12),
                  TextField(
                    controller: urlController,
                    onChanged: (_) => setDialogState(() {}),
                    style: TextStyle(color: c.gray200, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'https://...',
                      hintStyle: TextStyle(color: c.gray600),
                      filled: true, fillColor: c.gray900,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray600)),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: c.gray400))),
              ElevatedButton(
                onPressed: uploading ? null : () => Navigator.pop(ctx, urlController.text),
                style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                child: const Text('Save'),
              ),
            ],
          );
        });
      },
    );
    urlController.dispose();
    if (result != null) {
      target.text = result;
      _markDirty();
    }
  }

  void _showColorPicker(int which) {
    final c = ref.read(infernoColorsProvider);
    final current = which == 1 ? _color1 : _color2;
    final hexController = TextEditingController(text: '#${current.toARGB32().toRadixString(16).substring(2)}');

    showDialog(
      context: context,
      builder: (ctx) {
        Color selected = current;
        return StatefulBuilder(builder: (ctx, setDialogState) {
          return AlertDialog(
            backgroundColor: c.gray800,
            title: Text('Color $which', style: const TextStyle(color: Colors.white, fontSize: 16)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Preset swatches
                Wrap(
                  spacing: 6, runSpacing: 6,
                  children: [
                    for (final hex in _presetColors)
                      _buildColorSwatch(hex, selected, (color) {
                        setDialogState(() {
                          selected = color;
                          hexController.text = '#${color.toARGB32().toRadixString(16).substring(2)}';
                        });
                      }),
                  ],
                ),
                const SizedBox(height: 16),
                // Hex input
                TextField(
                  controller: hexController,
                  style: TextStyle(color: c.gray200, fontSize: 14, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    labelText: 'Hex', labelStyle: TextStyle(color: c.gray500),
                    filled: true, fillColor: c.gray900,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray600)),
                  ),
                  onChanged: (val) {
                    final parsed = _parseColor(val);
                    if (parsed != null) setDialogState(() => selected = parsed);
                  },
                ),
                const SizedBox(height: 12),
                // Preview
                Container(
                  height: 32, width: double.infinity,
                  decoration: BoxDecoration(
                    color: selected,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: c.gray600),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: c.gray400))),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, selected),
                style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                child: const Text('Apply'),
              ),
            ],
          );
        });
      },
    ).then((result) {
      hexController.dispose();
      if (result != null && result is Color) {
        setState(() {
          if (which == 1) {
            _color1 = result;
          } else {
            _color2 = result;
          }
          _dirty = true;
        });
      }
    });
  }

  Widget _buildColorSwatch(String hex, Color selected, void Function(Color) onTap) {
    final color = _parseColor(hex)!;
    final isSelected = color.toARGB32() == selected.toARGB32();
    return GestureDetector(
      onTap: () => onTap(color),
      child: Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: isSelected ? Colors.white : Colors.transparent, width: 2),
        ),
      ),
    );
  }

  void _showEmojiPicker() async {
    final c = ref.read(infernoColorsProvider);
    final db = ref.read(databaseProvider);
    final unicodeEmojis = ['😊', '😎', '🔥', '💻', '🎮', '🎵', '📚', '🚀', '⚡', '🌙', '☕', '🎯', '💬', '🛠️', '✨', '🌊', '🎨', '🏆', '💡', '🔑'];

    // Load custom emojis from all servers
    final customEmojis = await db.select(db.serverEmojis).get();

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.gray800,
        title: const Text('Pick Status Emoji', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Unicode emojis
                Wrap(
                  spacing: 6, runSpacing: 6,
                  children: unicodeEmojis.map((e) => _emojiButton(ctx, c, e, isSelected: _statusEmoji == e)).toList(),
                ),
                // Custom server emojis
                if (customEmojis.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('SERVER EMOJIS', style: TextStyle(color: c.gray500, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6, runSpacing: 6,
                    children: customEmojis
                        .where((e) => e.url != null)
                        .map((e) => _customEmojiButton(ctx, c, e))
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _emojiButton(BuildContext ctx, InfernoColors c, String emoji, {bool isSelected = false}) {
    return GestureDetector(
      onTap: () {
        Navigator.pop(ctx);
        setState(() { _statusEmoji = emoji; _dirty = true; });
      },
      child: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: isSelected ? c.accent.withValues(alpha: 0.3) : c.gray900,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: isSelected ? c.accent : c.gray700),
        ),
        child: Center(child: Text(emoji, style: const TextStyle(fontSize: 18))),
      ),
    );
  }

  Widget _customEmojiButton(BuildContext ctx, InfernoColors c, ServerEmoji emoji) {
    final shortcode = ':${emoji.name}:';
    final isSelected = _statusEmoji == shortcode;
    return Tooltip(
      message: shortcode,
      child: GestureDetector(
        onTap: () {
          Navigator.pop(ctx);
          setState(() { _statusEmoji = shortcode; _dirty = true; });
        },
        child: Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: isSelected ? c.accent.withValues(alpha: 0.3) : c.gray900,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: isSelected ? c.accent : c.gray700),
          ),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: CachedNetworkImage(
              imageUrl: emoji.url!,
              width: 28, height: 28,
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }

  static Color? _parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    try {
      final cleaned = hex.replaceFirst('#', '');
      if (cleaned.length == 6) return Color(int.parse('FF$cleaned', radix: 16));
    } catch (_) {}
    return null;
  }

  static const _presetColors = [
    '#e74c3c', '#e67e22', '#f1c40f', '#2ecc71', '#1abc9c',
    '#3498db', '#9b59b6', '#e91e63', '#ff6b6b', '#ffa07a',
    '#95a5a6', '#607d8b', '#8d6e63', '#1e1c1b', '#2c3e50',
    '#34495e', '#546e7a', '#455a64', '#37474f', '#263238',
  ];
}

// ── Hover overlay widget ──

class _HoverOverlay extends StatefulWidget {
  final Widget child;
  const _HoverOverlay({required this.child});
  @override
  State<_HoverOverlay> createState() => _HoverOverlayState();
}

class _HoverOverlayState extends State<_HoverOverlay> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        color: _hovering ? Colors.black.withValues(alpha: 0.4) : Colors.transparent,
        child: Center(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: _hovering ? 1.0 : 0.0,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

// ── Color swatch button ──

class _ColorSwatch extends StatefulWidget {
  final Color color;
  final VoidCallback onTap;
  const _ColorSwatch({required this.color, required this.onTap});
  @override
  State<_ColorSwatch> createState() => _ColorSwatchState();
}

class _ColorSwatchState extends State<_ColorSwatch> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: widget.color,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: _hovering ? Colors.white.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.15),
              width: _hovering ? 2 : 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// Preview of the current avatar/banner image inside the edit dialog so the
/// user can see what's already set before deciding whether to replace or
/// re-crop it.
class _ImagePreview extends StatelessWidget {
  final String url;
  final CropMode mode;
  final InfernoColors colors;
  const _ImagePreview({required this.url, required this.mode, required this.colors});

  @override
  Widget build(BuildContext context) {
    final valid = validImageUrl(url);
    final isBanner = mode == CropMode.banner;

    if (valid == null) {
      return Container(
        height: isBanner ? 110 : 96,
        decoration: BoxDecoration(
          color: colors.gray900,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.gray700, style: BorderStyle.solid),
        ),
        alignment: Alignment.center,
        child: Text(
          'No image set',
          style: TextStyle(color: colors.gray500, fontSize: 13),
        ),
      );
    }

    if (isBanner) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: AspectRatio(
          aspectRatio: 960 / 320,
          child: CachedNetworkImage(
            imageUrl: valid,
            fit: BoxFit.cover,
            placeholder: (_, __) => Container(color: colors.gray900),
            errorWidget: (_, __, ___) => Container(
              color: colors.gray900,
              alignment: Alignment.center,
              child: Icon(Icons.broken_image, color: colors.gray600),
            ),
          ),
        ),
      );
    }

    // Avatar (circular)
    return Center(
      child: Container(
        width: 96, height: 96,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.gray900,
          border: Border.all(color: colors.gray700),
        ),
        clipBehavior: Clip.antiAlias,
        child: CachedNetworkImage(
          imageUrl: valid,
          fit: BoxFit.cover,
          placeholder: (_, __) => const SizedBox(),
          errorWidget: (_, __, ___) => Icon(Icons.broken_image, color: colors.gray600),
        ),
      ),
    );
  }
}
