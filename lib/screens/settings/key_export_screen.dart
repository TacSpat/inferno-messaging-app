import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/auth_provider.dart';
import '../../crypto/bech32_nostr.dart';
import '../../crypto/nip49_crypto.dart';
import '../../theme/all_themes.dart';

class KeyExportScreen extends ConsumerStatefulWidget {
  const KeyExportScreen({super.key});

  @override
  ConsumerState<KeyExportScreen> createState() => _KeyExportScreenState();
}

class _KeyExportScreenState extends ConsumerState<KeyExportScreen> {
  String? _npub;
  String? _ncryptsec;
  bool _showNsec = false;
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

    // Run in isolate-friendly way (scrypt is slow)
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

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authServiceProvider);
    final c = Theme.of(context).extension<InfernoColors>()!;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('My Account', style: TextStyle(color: c.gray50, fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 24),
        // Warning
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF2A2A1A),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF5C4D00)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber, color: Color(0xFFFF9800), size: 20),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Your private key gives full access to your Nostr identity. Never share your nsec with anyone. Use ncryptsec for safe backups.',
                  style: TextStyle(color: Color(0xFFFF9800), fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // npub (public key)
        _KeySection(
          label: 'Public Key (npub)',
          value: _npub ?? '',
          onCopy: _npub != null ? () => _copyToClipboard(_npub!, 'npub') : null,
          c: c,
        ),
        const SizedBox(height: 16),

        // nsec (raw private key)
        _KeySection(
          label: 'Private Key (nsec)',
          value: _showNsec && auth.privateKeyHex != null
              ? Bech32Nostr.nsecEncode(auth.privateKeyHex!)
              : '\u2022' * 40,
          onCopy: auth.privateKeyHex != null
              ? () => _copyToClipboard(Bech32Nostr.nsecEncode(auth.privateKeyHex!), 'nsec')
              : null,
          c: c,
          trailing: TextButton(
            onPressed: () => setState(() => _showNsec = !_showNsec),
            child: Text(_showNsec ? 'Hide' : 'Reveal', style: TextStyle(color: c.accent)),
          ),
        ),
        const SizedBox(height: 24),

        // ncryptsec generation
        Text('ENCRYPTED BACKUP', style: TextStyle(color: c.gray500, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1)),
        const SizedBox(height: 8),
        Text(
          'Generate a password-encrypted backup of your private key. This is the safest way to store your key.',
          style: TextStyle(color: c.gray500, fontSize: 13),
        ),
        const SizedBox(height: 12),
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
              ? const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                    SizedBox(width: 8),
                    Text('Generating...'),
                  ],
                )
              : const Text('Generate ncryptsec'),
        ),
        if (_ncryptsec != null) ...[
          const SizedBox(height: 16),
          _KeySection(
            label: 'Encrypted Key (ncryptsec)',
            value: _ncryptsec!,
            onCopy: () => _copyToClipboard(_ncryptsec!, 'ncryptsec'),
            c: c,
          ),
        ],
      ],
    );
  }
}

class _KeySection extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onCopy;
  final Widget? trailing;
  final InfernoColors c;

  const _KeySection({required this.label, required this.value, this.onCopy, this.trailing, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.gray900,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: TextStyle(color: c.gray500, fontSize: 12, fontWeight: FontWeight.bold)),
              const Spacer(),
              if (trailing != null) trailing!,
              if (onCopy != null)
                IconButton(icon: Icon(Icons.copy, size: 16, color: c.gray500), onPressed: onCopy),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            value,
            style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: c.gray200),
          ),
        ],
      ),
    );
  }
}
