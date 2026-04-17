import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../providers/auth_provider.dart';
import '../../crypto/bech32_nostr.dart';
import '../../crypto/nip49_crypto.dart';
import '../../services/key_management_service.dart';
import '../../theme/all_themes.dart';
import '../../theme/theme_provider.dart';

class KeyExportScreen extends ConsumerStatefulWidget {
  const KeyExportScreen({super.key});

  @override
  ConsumerState<KeyExportScreen> createState() => _KeyExportScreenState();
}

class _KeyExportScreenState extends ConsumerState<KeyExportScreen> {
  String? _npub;
  String? _ncryptsec;
  bool _generating = false;
  final _passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadKeys();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadKeys() async {
    final auth = ref.read(authServiceProvider);
    if (auth.publicKeyHex != null) {
      setState(() => _npub = Bech32Nostr.npubEncode(auth.publicKeyHex!));
    }
  }

  Future<void> _generateNcryptsec() async {
    final password = _passwordController.text;
    if (password.isEmpty) return;
    setState(() => _generating = true);

    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null) return;

    final ncryptsec = Nip49Crypto.encrypt(auth.privateKeyHex!, password, logN: 16);
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

  Future<void> _saveToFile() async {
    if (_ncryptsec == null) return;
    try {
      final path = await KeyManagementService.exportToFile(_ncryptsec!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved to $path')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
  }

  Future<void> _copyNsec() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Copy raw private key?'),
        content: const Text(
          'Your raw private key (nsec) will be copied to the clipboard. '
          'Anyone with access to your clipboard can steal your identity. '
          'Only do this if you understand the risks.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Copy nsec', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final nsec = await KeyManagementService.exportNsec();
      Clipboard.setData(ClipboardData(text: nsec));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('nsec copied to clipboard')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Key Backup', style: TextStyle(color: c.gray50, fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 24),

        // Info box
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: c.gray800, borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.gray700),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.shield_outlined, color: c.accent, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Your private key is stored securely on this device and is never displayed. '
                'Generate an encrypted backup (ncryptsec) below to transfer your identity.',
                style: TextStyle(color: c.gray400, fontSize: 13, height: 1.5),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 24),

        // npub
        _KeySection(label: 'Public Key (npub)', value: _npub ?? '',
          onCopy: _npub != null ? () => _copyToClipboard(_npub!, 'npub') : null, c: c),
        const SizedBox(height: 24),

        // ncryptsec generation
        Text('ENCRYPTED BACKUP', style: TextStyle(color: c.gray500, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1)),
        const SizedBox(height: 8),
        TextField(
          controller: _passwordController,
          decoration: const InputDecoration(
            labelText: 'Backup Password',
            hintText: 'Choose a strong password',
            prefixIcon: Icon(Icons.lock_outline),
          ),
          obscureText: true,
        ),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: _generating ? null : _generateNcryptsec,
          child: _generating
              ? const Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                  SizedBox(width: 8), Text('Generating...'),
                ])
              : const Text('Generate Encrypted Backup'),
        ),

        if (_ncryptsec != null) ...[
          const SizedBox(height: 20),

          // QR code
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
              child: QrImageView(data: _ncryptsec!, version: QrVersions.auto, size: 200, backgroundColor: Colors.white),
            ),
          ),
          const SizedBox(height: 8),
          Text('Scan on another device to import', style: TextStyle(color: c.gray500, fontSize: 12), textAlign: TextAlign.center),
          const SizedBox(height: 16),

          // ncryptsec string
          _KeySection(label: 'Encrypted Key (ncryptsec)', value: _ncryptsec!,
            onCopy: () => _copyToClipboard(_ncryptsec!, 'ncryptsec'), c: c),
          const SizedBox(height: 12),

          // Action buttons
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: () => _copyToClipboard(_ncryptsec!, 'ncryptsec'),
              icon: const Icon(Icons.copy, size: 16), label: const Text('Copy'),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              onPressed: _saveToFile,
              icon: const Icon(Icons.save_alt, size: 16), label: const Text('Save File'),
            )),
          ]),
        ],

        // nsec clipboard (hidden — never displayed)
        const SizedBox(height: 32),
        Container(height: 1, color: c.gray700),
        const SizedBox(height: 16),
        Text('ADVANCED', style: TextStyle(color: c.gray500, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1)),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _copyNsec,
          icon: Icon(Icons.warning_amber, size: 16, color: c.accent),
          label: Text('Copy nsec to clipboard', style: TextStyle(color: c.gray400)),
          style: OutlinedButton.styleFrom(side: BorderSide(color: c.gray700)),
        ),
        Text('Raw private key — use with extreme caution. Never share.',
            style: TextStyle(color: c.gray600, fontSize: 11)),
      ],
    );
  }
}

class _KeySection extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onCopy;
  final InfernoColors c;
  const _KeySection({required this.label, required this.value, this.onCopy, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(label, style: TextStyle(color: c.gray500, fontSize: 12, fontWeight: FontWeight.bold)),
          const Spacer(),
          if (onCopy != null) IconButton(icon: Icon(Icons.copy, size: 16, color: c.gray500), onPressed: onCopy),
        ]),
        const SizedBox(height: 8),
        SelectableText(value, style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: c.gray200)),
      ]),
    );
  }
}
