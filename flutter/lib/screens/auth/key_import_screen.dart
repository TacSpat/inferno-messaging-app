import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import '../../providers/auth_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/realtime_provider.dart';
import '../../providers/servers_provider.dart';
import '../../providers/conversations_provider.dart';
import '../../services/key_management_service.dart';
import '../../services/app_bootstrap_service.dart';
import '../../services/media_cache_service.dart';
import 'backup_step.dart';

enum _KeyFormat { unknown, nsec, ncryptsec }

class KeyImportScreen extends ConsumerStatefulWidget {
  const KeyImportScreen({super.key});

  @override
  ConsumerState<KeyImportScreen> createState() => _KeyImportScreenState();
}

class _KeyImportScreenState extends ConsumerState<KeyImportScreen> {
  final _keyController = TextEditingController();
  final _passwordController = TextEditingController();
  _KeyFormat _detectedFormat = _KeyFormat.unknown;
  bool _loading = false;
  String? _error;
  bool _obscurePassword = true;
  List<StoredAccount> _savedAccounts = [];

  @override
  void initState() {
    super.initState();
    _loadSavedAccounts();
  }

  Future<void> _loadSavedAccounts() async {
    final accounts = await KeyManagementService.listAccounts();
    if (mounted) setState(() => _savedAccounts = accounts);
  }

  @override
  void dispose() {
    _keyController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _switchToSavedAccount(StoredAccount account) async {
    // Prompt for backup password.
    final pwController = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Unlock ${account.displayName.isNotEmpty ? account.displayName : "account"}'),
        content: TextField(
          controller: pwController,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Backup Password',
            prefixIcon: Icon(Icons.lock_outline),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, pwController.text),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
    pwController.dispose();
    if (password == null || password.isEmpty || !mounted) return;

    setState(() { _loading = true; _error = null; });
    try {
      await KeyManagementService.switchAccount(account.pubkey, password);
      final authService = ref.read(authServiceProvider);
      await authService.initialize();
      if (!mounted) return;

      // Bootstrap
      final db = ref.read(databaseProvider);
      final pool = ref.read(relayPoolProvider);
      final bootstrap = AppBootstrapService(
        db: db, relayPool: pool, authService: authService,
        presenceService: ref.read(presenceServiceProvider),
        typingService: ref.read(typingServiceProvider),
        reactionService: ref.read(reactionServiceProvider),
        groupMessageService: ref.read(groupMessageServiceProvider),
        dmService: ref.read(dmServiceProvider),
        contactService: ref.read(contactServiceProvider),
        inviteService: ref.read(inviteServiceProvider),
        mediaCacheService: ref.read(mediaCacheServiceProvider),
      );
      await bootstrap.bootstrap();
      if (!mounted) return;
      context.go('/conversations');
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'Wrong password or corrupted backup'; });
    }
  }

  void _detectFormat(String input) {
    final trimmed = input.trim().toLowerCase();
    setState(() {
      if (trimmed.startsWith('nsec1')) {
        _detectedFormat = _KeyFormat.nsec;
      } else if (trimmed.startsWith('ncryptsec1')) {
        _detectedFormat = _KeyFormat.ncryptsec;
      } else {
        _detectedFormat = _KeyFormat.unknown;
      }
    });
  }

  Future<void> _importKey() async {
    // Bech32 requires lowercase — normalize before passing to crypto.
    final input = _keyController.text.trim().toLowerCase();
    if (input.isEmpty) {
      setState(() => _error = 'Please enter a key');
      return;
    }
    setState(() { _loading = true; _error = null; });

    try {
      final authService = ref.read(authServiceProvider);
      switch (_detectedFormat) {
        case _KeyFormat.nsec:
          await authService.importNsec(input);
          break;
        case _KeyFormat.ncryptsec:
          final password = _passwordController.text;
          if (password.isEmpty) {
            setState(() { _loading = false; _error = 'Password required for ncryptsec'; });
            return;
          }
          await authService.importNcryptsec(input, password);
          break;
        case _KeyFormat.unknown:
          setState(() { _loading = false; _error = 'Unrecognized key format. Use nsec1... or ncryptsec1...'; });
          return;
      }

      if (!mounted) return;

      // Bootstrap the app with the imported key before navigating.
      try {
        final db = ref.read(databaseProvider);
        final pool = ref.read(relayPoolProvider);
        final bootstrap = AppBootstrapService(
          db: db,
          relayPool: pool,
          authService: ref.read(authServiceProvider),
          presenceService: ref.read(presenceServiceProvider),
          typingService: ref.read(typingServiceProvider),
          reactionService: ref.read(reactionServiceProvider),
          groupMessageService: ref.read(groupMessageServiceProvider),
          dmService: ref.read(dmServiceProvider),
          contactService: ref.read(contactServiceProvider),
          inviteService: ref.read(inviteServiceProvider),
          mediaCacheService: ref.read(mediaCacheServiceProvider),
        );
        await bootstrap.bootstrap();
      } catch (e) {
        debugPrint('[Import] Bootstrap failed: $e');
      }

      if (!mounted) return;

      // Check if backup password exists — if not, gate through backup step.
      final hasBackup = await KeyManagementService.hasBackupPassword();
      if (!hasBackup) {
        final npub = await KeyManagementService.exportNpub();
        final auth = ref.read(authServiceProvider);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('Secure Your Identity')),
            body: SafeArea(child: BackupStep(
              npub: npub,
              privateKeyHex: auth.privateKeyHex!,
              displayName: '',
              onComplete: () {
                if (context.mounted) GoRouter.of(context).go('/conversations');
              },
            )),
          )),
        );
        return;
      }

      context.go('/conversations');
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      setState(() {
        _loading = false;
        if (msg.contains('MixedCase')) {
          _error = 'Key contains mixed case — it has been auto-corrected. Try again.';
        } else if (_detectedFormat == _KeyFormat.ncryptsec) {
          _error = 'Decryption failed — wrong password or corrupted key';
        } else {
          _error = 'Invalid key: $msg';
        }
      });
    }
  }

  String get _formatLabel {
    switch (_detectedFormat) {
      case _KeyFormat.nsec: return 'nsec (private key)';
      case _KeyFormat.ncryptsec: return 'ncryptsec (password-encrypted)';
      case _KeyFormat.unknown: return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/auth/login'),
        ),
        title: const Text('Import Key'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              Text(
                'Import your Nostr identity',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Paste your private key in any supported format.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF8899A6),
                ),
              ),
              // Saved accounts
              if (_savedAccounts.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('SAVED ACCOUNTS', style: TextStyle(
                  color: const Color(0xFF8899A6), fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                const SizedBox(height: 8),
                for (final account in _savedAccounts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: OutlinedButton(
                      onPressed: _loading ? null : () => _switchToSavedAccount(account),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFE0E0E0),
                        side: BorderSide(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      child: Row(children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                          child: Text(
                            (account.displayName.isNotEmpty ? account.displayName : account.npub)[0].toUpperCase(),
                            style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (account.displayName.isNotEmpty)
                            Text(account.displayName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                          Text(
                            account.npub.length > 24 ? '${account.npub.substring(0, 24)}...' : account.npub,
                            style: const TextStyle(color: Color(0xFF8899A6), fontSize: 11, fontFamily: 'monospace'),
                          ),
                        ])),
                        const Icon(Icons.login, size: 18, color: Color(0xFF8899A6)),
                      ]),
                    ),
                  ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: Divider(color: const Color(0xFF2A3A5C))),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('or import a new key', style: TextStyle(color: Color(0xFF5C6B77), fontSize: 12)),
                  ),
                  Expanded(child: Divider(color: const Color(0xFF2A3A5C))),
                ]),
              ],
              const SizedBox(height: 16),
              // Import from file
              OutlinedButton.icon(
                onPressed: () async {
                  try {
                    final picked = await FilePicker.platform.pickFiles(
                      type: FileType.custom,
                      allowedExtensions: ['key', 'txt'],
                    );
                    if (picked == null || picked.files.isEmpty) return;
                    final path = picked.files.first.path;
                    if (path == null) return;
                    final contents = await KeyManagementService.importFromFile(path);
                    _keyController.text = contents;
                    _detectFormat(contents);
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to read file: $e')),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.file_open, size: 18),
                label: const Text('Import from File'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFE0E0E0),
                  side: const BorderSide(color: Color(0xFF2A3A5C)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: Divider(color: const Color(0xFF2A3A5C))),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text('or paste key', style: TextStyle(color: Color(0xFF5C6B77), fontSize: 12)),
                ),
                Expanded(child: Divider(color: const Color(0xFF2A3A5C))),
              ]),
              const SizedBox(height: 16),
              TextFormField(
                controller: _keyController,
                decoration: const InputDecoration(
                  labelText: 'Private Key',
                  hintText: 'nsec1... or ncryptsec1...',
                  prefixIcon: Icon(Icons.key),
                  suffixIcon: Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.visibility_off, color: Color(0xFF5C5C5C)),
                  ),
                ),
                obscureText: true,
                onChanged: _detectFormat,
                maxLines: 1,
              ),
              if (_detectedFormat != _KeyFormat.unknown) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.check_circle, size: 16, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      'Detected: $_formatLabel',
                      style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 13),
                    ),
                  ],
                ),
              ],
              if (_detectedFormat == _KeyFormat.nsec) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A2A3A),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF2196F3).withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline, color: Color(0xFF2196F3), size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'For better security, use an ncryptsec (encrypted backup) instead. '
                          'Raw nsec keys can be leaked if your clipboard is compromised.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF90CAF9), fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_detectedFormat == _KeyFormat.ncryptsec) ...[
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passwordController,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    hintText: 'Enter the password used to encrypt this key',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  obscureText: _obscurePassword,
                  onFieldSubmitted: (_) => _importKey(),
                ),
              ],
              const SizedBox(height: 24),
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3A1A1A),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_error!, style: const TextStyle(color: Color(0xFFFF4D4D))),
                ),
                const SizedBox(height: 16),
              ],
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: _loading ? null : _importKey,
                  child: _loading
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Import Key'),
                ),
              ),
              const SizedBox(height: 32),
              // Warning box
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A1A),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF5C4D00)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber, color: Color(0xFFFF9800), size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Your private key is stored securely on this device using the platform keychain. '
                        'For maximum security, use an ncryptsec (encrypted backup) instead of a raw nsec. '
                        'Never share your private key with anyone.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFFFF9800),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
