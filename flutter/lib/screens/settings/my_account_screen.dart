import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../providers/auth_provider.dart';
import '../../providers/database_provider.dart';
import '../../crypto/bech32_nostr.dart';
import '../../crypto/nip49_crypto.dart';
import '../../services/relay_config_service.dart';
import '../../theme/all_themes.dart';
import '../../theme/theme_provider.dart';

class MyAccountScreen extends ConsumerStatefulWidget {
  final void Function(String page)? onNavigate;
  const MyAccountScreen({super.key, this.onNavigate});

  @override
  ConsumerState<MyAccountScreen> createState() => _MyAccountScreenState();
}

class _MyAccountScreenState extends ConsumerState<MyAccountScreen> {
  String? _npub;
  String? _ncryptsec;
  bool _generating = false;
  final _accountPasswordController = TextEditingController();
  final _backupPasswordController = TextEditingController();

  // Profile data
  String _displayName = '';
  String _username = '';
  String? _avatarUrl;
  String? _bannerUrl;
  String? _profileColor;
  String? _profileColor2;
  DateTime? _memberSince;
  List<String> _relayUrls = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _accountPasswordController.dispose();
    _backupPasswordController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final auth = ref.read(authServiceProvider);
    if (auth.publicKeyHex == null) return;

    setState(() => _npub = Bech32Nostr.npubEncode(auth.publicKeyHex!));

    final db = ref.read(databaseProvider);

    // Load profile from contacts
    final contact = await db.contactsDao.getByPubkey(auth.publicKeyHex!);
    if (contact != null && mounted) {
      setState(() {
        _displayName = contact.displayName ?? contact.username ?? '';
        _username = contact.username ?? '';
        _avatarUrl = contact.avatarUrl;
        _bannerUrl = contact.bannerUrl;
        _memberSince = contact.createdAt;
      });
    }

    // Load profile colors from remote_members (contacts table lacks these)
    final members = await (db.select(db.remoteMembers)
          ..where((m) => m.pubkey.equals(auth.publicKeyHex!))
          ..limit(1))
        .get();
    if (members.isNotEmpty && mounted) {
      setState(() {
        _profileColor = members.first.profileColor;
        _profileColor2 = members.first.profileColor2;
        if (_avatarUrl == null || _avatarUrl!.isEmpty) _avatarUrl = members.first.avatarUrl;
        if (_bannerUrl == null || _bannerUrl!.isEmpty) _bannerUrl = members.first.bannerUrl;
        if (_displayName.isEmpty) _displayName = members.first.displayName ?? members.first.username ?? '';
        if (_username.isEmpty) _username = members.first.username ?? '';
      });
    }

    // Load relays
    final relays = await RelayConfigService(db).getActiveRelayUrls();
    if (mounted) setState(() => _relayUrls = relays.take(3).toList());
  }

  Future<void> _generateNcryptsec() async {
    final backupPw = _backupPasswordController.text;
    if (backupPw.isEmpty || backupPw.length < 8) return;
    setState(() => _generating = true);

    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null) return;

    final ncryptsec = Nip49Crypto.encrypt(auth.privateKeyHex!, backupPw, logN: 16);
    if (mounted) {
      setState(() {
        _ncryptsec = ncryptsec;
        _generating = false;
      });
    }
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label copied to clipboard')));
  }

  static Color? _parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    try {
      final cleaned = hex.replaceFirst('#', '');
      if (cleaned.length == 6) return Color(int.parse('FF$cleaned', radix: 16));
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);
    final color1 = _parseColor(_profileColor) ?? c.gray700;
    final color2 = _parseColor(_profileColor2) ?? c.gray800;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('My Account', style: TextStyle(color: c.gray50, fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 24),

        // ── Profile Card ──
        _buildProfileCard(c, color1, color2),
        const SizedBox(height: 32),

        // ── Federation Identity ──
        Text('Federation Identity', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: c.gray900,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.gray700),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Your keypair is your federation identity. Other users can verify you using your public key.',
              style: TextStyle(color: c.gray400, fontSize: 14)),
            const SizedBox(height: 20),

            // Public Key
            _sectionLabel('PUBLIC KEY', c),
            const SizedBox(height: 8),
            _keyRow(_npub ?? '', 'npub', c),
            const SizedBox(height: 20),

            // Private Key — never revealed, only encrypted export
            Container(height: 1, color: c.gray700),
            const SizedBox(height: 16),
            _sectionLabel('PRIVATE KEY', c),
            const SizedBox(height: 4),
            Row(children: [
              Icon(Icons.shield_outlined, size: 14, color: c.accent),
              const SizedBox(width: 6),
              Expanded(child: Text(
                'Your private key is stored securely on this device and is never displayed. '
                'Use the encrypted backup below to transfer your identity to another device.',
                style: TextStyle(color: c.gray400, fontSize: 12),
              )),
            ]),

            const SizedBox(height: 20),

            // Encrypted Backup
            Container(height: 1, color: c.gray700),
            const SizedBox(height: 16),
            _sectionLabel('ENCRYPTED BACKUP (NIP-49)', c),
            const SizedBox(height: 4),
            Text('Export your private key encrypted with a backup password. Store the ncryptsec safely \u2014 you can import it on any compatible Nostr client.',
              style: TextStyle(color: c.gray500, fontSize: 12)),
            const SizedBox(height: 12),
            _inputField('Account password', _accountPasswordController, c, hint: 'Your account password'),
            const SizedBox(height: 8),
            _inputField('Backup password (min 8 characters)', _backupPasswordController, c, hint: 'Choose a strong backup password'),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _generating ? null : _generateNcryptsec,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: _generating
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Export Encrypted Key'),
              ),
            ),
            if (_ncryptsec != null) ...[
              const SizedBox(height: 12),
              _keyRow(_ncryptsec!, 'ncryptsec', c, valueColor: c.accent),
            ],
          ]),
        ),

        const SizedBox(height: 32),

        // ── Relays ──
        Row(children: [
          Text('Relays', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          const Spacer(),
          if (widget.onNavigate != null)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => widget.onNavigate!('relays'),
                child: Text('Manage Relays', style: TextStyle(color: c.accent, fontSize: 14)),
              ),
            ),
        ]),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: c.gray900,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.gray700),
          ),
          child: Column(children: [
            if (_relayUrls.isEmpty)
              Text('No relays configured.', style: TextStyle(color: c.gray500, fontSize: 13))
            else
              for (final url in _relayUrls)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(children: [
                    Container(
                      width: 24, height: 24,
                      decoration: BoxDecoration(
                        color: const Color(0xFF4CAF50).withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Center(child: Container(
                        width: 8, height: 8,
                        decoration: const BoxDecoration(color: Color(0xFF66BB6A), shape: BoxShape.circle),
                      )),
                    ),
                    const SizedBox(width: 12),
                    Text(url, style: TextStyle(color: Colors.white, fontSize: 14, fontFamily: 'monospace')),
                  ]),
                ),
          ]),
        ),
      ],
    );
  }

  Widget _buildProfileCard(InfernoColors c, Color color1, Color color2) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.gray700),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        // Banner
        Container(
          height: 96,
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [color1, color2]),
            image: _bannerUrl != null && _bannerUrl!.isNotEmpty
                ? DecorationImage(image: NetworkImage(_bannerUrl!), fit: BoxFit.cover)
                : null,
          ),
        ),
        // Body with gradient
        Container(
          padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16, top: 4),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [color1.withValues(alpha: 0.6), color2.withValues(alpha: 0.3)],
            ),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Avatar
            Transform.translate(
              offset: const Offset(0, -35),
              child: Container(
                width: 76, height: 76,
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: color2,
                  shape: BoxShape.circle,
                ),
                child: CircleAvatar(
                  radius: 33,
                  backgroundColor: color1,
                  backgroundImage: _avatarUrl != null && _avatarUrl!.isNotEmpty
                      ? NetworkImage(_avatarUrl!) : null,
                  child: _avatarUrl == null || _avatarUrl!.isEmpty
                      ? Text(
                          (_displayName.isNotEmpty ? _displayName : _username).isNotEmpty
                              ? (_displayName.isNotEmpty ? _displayName : _username)[0].toUpperCase()
                              : '?',
                          style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold))
                      : null,
                ),
              ),
            ),
            // Info card
            Transform.translate(
              offset: const Offset(0, -20),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    _displayName.isNotEmpty ? _displayName : _username,
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  if (_username.isNotEmpty)
                    Text(_username, style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 14)),
                  const SizedBox(height: 12),
                  Container(height: 1, color: Colors.white.withValues(alpha: 0.1)),
                  const SizedBox(height: 12),
                  Text('MEMBER SINCE', style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5), fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                  const SizedBox(height: 2),
                  Text(
                    _memberSince != null ? DateFormat('MMMM d, y').format(_memberSince!) : '',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _sectionLabel(String text, InfernoColors c) {
    return Text(text, style: TextStyle(
      color: Colors.white.withValues(alpha: 0.5), fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5));
  }

  Widget _keyRow(String value, String label, InfernoColors c, {Color? valueColor}) {
    return Row(children: [
      Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: c.gray950,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c.gray600),
          ),
          child: SelectableText(
            value,
            style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: valueColor ?? Colors.white),
          ),
        ),
      ),
      const SizedBox(width: 8),
      MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: value.isNotEmpty ? () => _copyToClipboard(value, label) : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: c.gray700,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('Copy', style: TextStyle(color: c.gray400, fontSize: 14)),
          ),
        ),
      ),
    ]);
  }

  Widget _inputField(String label, TextEditingController controller, InfernoColors c, {String? hint}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(color: c.gray500, fontSize: 12)),
      const SizedBox(height: 4),
      TextField(
        controller: controller,
        obscureText: true,
        style: TextStyle(color: c.gray200, fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: c.gray600),
          filled: true, fillColor: c.gray950,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray600)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray600)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.accent)),
        ),
      ),
    ]);
  }
}
