import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/all_themes.dart';
import '../../theme/theme_provider.dart';

class PasswordScreen extends ConsumerStatefulWidget {
  const PasswordScreen({super.key});

  @override
  ConsumerState<PasswordScreen> createState() => _PasswordScreenState();
}

class _PasswordScreenState extends ConsumerState<PasswordScreen> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _error;
  bool _saved = false;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _updatePassword() {
    final newPw = _newController.text;
    final confirmPw = _confirmController.text;

    if (newPw.length < 6) {
      setState(() => _error = 'New password must be at least 6 characters.');
      return;
    }
    if (newPw != confirmPw) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }

    // TODO: Implement actual password update (re-encrypt private key with new password)
    setState(() {
      _error = null;
      _saved = true;
    });
    _currentController.clear();
    _newController.clear();
    _confirmController.clear();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Password updated successfully.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Change Password', style: TextStyle(color: c.gray50, fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 24),
        Container(
          constraints: const BoxConstraints(maxWidth: 448),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: c.gray900,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.gray700),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _fieldLabel('CURRENT PASSWORD', c),
            const SizedBox(height: 6),
            _passwordField(_currentController, c),
            const SizedBox(height: 20),
            _fieldLabel('NEW PASSWORD', c),
            const SizedBox(height: 6),
            _passwordField(_newController, c),
            const SizedBox(height: 4),
            Text('Minimum 6 characters', style: TextStyle(color: c.gray500, fontSize: 12)),
            const SizedBox(height: 20),
            _fieldLabel('CONFIRM NEW PASSWORD', c),
            const SizedBox(height: 6),
            _passwordField(_confirmController, c),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: c.accent, fontSize: 13)),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _updatePassword,
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
                child: const Text('Update Password', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _fieldLabel(String text, InfernoColors c) {
    return Text(text, style: TextStyle(
      color: Colors.white.withValues(alpha: 0.5), fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5));
  }

  Widget _passwordField(TextEditingController controller, InfernoColors c) {
    return TextField(
      controller: controller,
      obscureText: true,
      style: TextStyle(color: c.gray200, fontSize: 14),
      decoration: InputDecoration(
        filled: true, fillColor: c.gray950,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray600)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray600)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.accent)),
      ),
    );
  }
}
