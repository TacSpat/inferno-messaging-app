import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/auth_provider.dart';

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

  @override
  void dispose() {
    _keyController.dispose();
    _passwordController.dispose();
    super.dispose();
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
    final input = _keyController.text.trim();
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
      context.go('/conversations');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _detectedFormat == _KeyFormat.ncryptsec
            ? 'Decryption failed — wrong password or corrupted key'
            : 'Invalid key: ${e.toString()}';
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
              const SizedBox(height: 24),
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
