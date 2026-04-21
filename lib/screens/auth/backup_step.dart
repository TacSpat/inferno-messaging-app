import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../crypto/nip49_crypto.dart';
import '../../services/key_management_service.dart';
import '../../widgets/inferno_logo.dart';

/// Mandatory backup screen used after signup AND for existing users who
/// haven't set a backup password yet.
class BackupStep extends StatefulWidget {
  final String npub;
  final String privateKeyHex;
  final String displayName;
  final VoidCallback onComplete;

  const BackupStep({
    super.key,
    required this.npub,
    required this.privateKeyHex,
    required this.displayName,
    required this.onComplete,
  });

  @override
  State<BackupStep> createState() => _BackupStepState();
}

class _BackupStepState extends State<BackupStep> {
  final _pwController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _ncryptsec;
  String? _error;
  bool _generating = false;
  bool _saved = false;
  String? _filePath;

  @override
  void dispose() {
    _pwController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final pw = _pwController.text;
    final confirm = _confirmController.text;
    if (pw.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters');
      return;
    }
    if (pw != confirm) {
      setState(() => _error = 'Passwords do not match');
      return;
    }
    setState(() { _generating = true; _error = null; });
    try {
      final ncryptsec = Nip49Crypto.encrypt(widget.privateKeyHex, pw);
      await KeyManagementService.setBackupPasswordHash(pw);
      await KeyManagementService.storeCurrentAsAccount(ncryptsec, widget.displayName);
      if (mounted) setState(() { _ncryptsec = ncryptsec; _generating = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _generating = false; });
    }
  }

  Future<void> _saveToFile() async {
    if (_ncryptsec == null) return;
    try {
      final path = await KeyManagementService.exportToFile(_ncryptsec!);
      if (mounted) {
        setState(() => _filePath = path);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved to $path')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final screenWidth = MediaQuery.of(context).size.width;
    final cardWidth = screenWidth > 520 ? 460.0 : screenWidth - 48;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
        child: Center(
          child: SizedBox(
            width: cardWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Header ──
                const InfernoLogo(size: 40),
                const SizedBox(height: 16),
                Text('Back up your identity',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text(
                  'Your private key is the only way to access your account.\nSet a password to create an encrypted backup.',
                  style: TextStyle(color: Color(0xFF8899A6), fontSize: 14, height: 1.5),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),

                // ── Card ──
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF111827),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: primary.withValues(alpha: 0.15)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // npub row
                      _SectionLabel('YOUR PUBLIC KEY'),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0D1117),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF21262D)),
                        ),
                        child: Row(children: [
                          Icon(Icons.fingerprint, size: 16, color: primary.withValues(alpha: 0.6)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(widget.npub,
                                style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFF8B949E)),
                                overflow: TextOverflow.ellipsis),
                          ),
                          const SizedBox(width: 8),
                          _CopyBtn(text: widget.npub, label: 'Public key'),
                        ]),
                      ),

                      const SizedBox(height: 24),

                      // Password fields OR backup result
                      if (_ncryptsec == null) ...[
                        _SectionLabel('BACKUP PASSWORD'),
                        const SizedBox(height: 4),
                        const Text('Choose a strong password you can remember.',
                            style: TextStyle(color: Color(0xFF6E7681), fontSize: 12)),
                        const SizedBox(height: 12),
                        _StyledField(
                          controller: _pwController,
                          hint: 'Password (min 8 characters)',
                          icon: Icons.lock_outline,
                        ),
                        const SizedBox(height: 10),
                        _StyledField(
                          controller: _confirmController,
                          hint: 'Confirm password',
                          icon: Icons.lock_outline,
                          onSubmitted: (_) => _generate(),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF3A1A1A),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(children: [
                              const Icon(Icons.error_outline, size: 14, color: Color(0xFFFF6B6B)),
                              const SizedBox(width: 8),
                              Expanded(child: Text(_error!, style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 12))),
                            ]),
                          ),
                        ],
                        const SizedBox(height: 20),
                        SizedBox(
                          height: 44,
                          child: ElevatedButton(
                            onPressed: _generating ? null : _generate,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: primary,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            child: _generating
                                ? Row(mainAxisSize: MainAxisSize.min, children: [
                                    const SizedBox(width: 16, height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                                    const SizedBox(width: 10),
                                    const Text('Encrypting...'),
                                  ])
                                : const Row(mainAxisSize: MainAxisSize.min, children: [
                                    Icon(Icons.vpn_key, size: 16),
                                    SizedBox(width: 8),
                                    Text('Generate Encrypted Backup'),
                                  ]),
                          ),
                        ),
                      ] else ...[
                        // ── Backup generated ──
                        // QR code
                        Center(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              color: Colors.white,
                              padding: const EdgeInsets.all(8),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  QrImageView(
                                    data: _ncryptsec!,
                                    version: QrVersions.auto,
                                    errorCorrectionLevel: QrErrorCorrectLevel.H,
                                    size: 200,
                                    padding: EdgeInsets.zero,
                                    backgroundColor: Colors.white,
                                    gapless: true,
                                    eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Color(0xFF1A1A2E)),
                                    dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: Color(0xFF1A1A2E)),
                                  ),
                                  Container(
                                    width: 52, height: 52,
                                    decoration: const BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                    ),
                                    padding: const EdgeInsets.all(4),
                                    child: Image.asset('assets/icons/inferno_icon.png', width: 44, height: 44),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text('Scan on another device to import your identity',
                            style: TextStyle(color: Color(0xFF6E7681), fontSize: 12), textAlign: TextAlign.center),
                        const SizedBox(height: 20),

                        // Encrypted backup string
                        _SectionLabel('ENCRYPTED KEY'),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0D1117),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: primary.withValues(alpha: 0.2)),
                          ),
                          child: Text(_ncryptsec!,
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF8B949E), height: 1.6)),
                        ),
                        const SizedBox(height: 14),

                        // Action buttons
                        Row(children: [
                          Expanded(child: _ActionBtn(
                            icon: Icons.copy, label: 'Copy Key',
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: _ncryptsec!));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Encrypted key copied')));
                            },
                          )),
                          const SizedBox(width: 10),
                          Expanded(child: _ActionBtn(
                            icon: Icons.save_alt, label: 'Save File',
                            onTap: _saveToFile,
                          )),
                        ]),
                        if (_filePath != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Row(children: [
                              const Icon(Icons.check_circle, size: 13, color: Color(0xFF4CAF50)),
                              const SizedBox(width: 6),
                              Expanded(child: Text('Saved: $_filePath',
                                  style: const TextStyle(color: Color(0xFF4CAF50), fontSize: 11),
                                  overflow: TextOverflow.ellipsis)),
                            ]),
                          ),
                      ],
                    ],
                  ),
                ),

                // ── Confirm + Continue ──
                if (_ncryptsec != null) ...[
                  const SizedBox(height: 20),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => setState(() => _saved = !_saved),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: _saved ? primary.withValues(alpha: 0.08) : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: _saved ? primary.withValues(alpha: 0.3) : const Color(0xFF21262D)),
                        ),
                        child: Row(children: [
                          Icon(_saved ? Icons.check_box : Icons.check_box_outline_blank,
                              size: 20, color: _saved ? primary : const Color(0xFF6E7681)),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text('I have saved my encrypted backup in a safe place',
                                style: TextStyle(color: Color(0xFFCCCCCC), fontSize: 13)),
                          ),
                        ]),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _saved ? widget.onComplete : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primary,
                        disabledBackgroundColor: const Color(0xFF21262D),
                        foregroundColor: Colors.white,
                        disabledForegroundColor: const Color(0xFF6E7681),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('Continue to Inferno', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Shared mini widgets ───────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(color: Color(0xFF6E7681), fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8));
}

class _StyledField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final ValueChanged<String>? onSubmitted;
  const _StyledField({required this.controller, required this.hint, required this.icon, this.onSubmitted});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: true,
      onSubmitted: onSubmitted,
      style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF484F58)),
        prefixIcon: Icon(icon, size: 18, color: const Color(0xFF484F58)),
        filled: true,
        fillColor: const Color(0xFF0D1117),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF21262D))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF21262D))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5))),
      ),
    );
  }
}

class _CopyBtn extends StatelessWidget {
  final String text;
  final String label;
  const _CopyBtn({required this.text, required this.label});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          Clipboard.setData(ClipboardData(text: text));
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label copied')));
        },
        child: const Icon(Icons.copy, size: 14, color: Color(0xFF6E7681)),
      ),
    );
  }
}

class _ActionBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionBtn({required this.icon, required this.label, required this.onTap});

  @override
  State<_ActionBtn> createState() => _ActionBtnState();
}

class _ActionBtnState extends State<_ActionBtn> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: _hovering ? primary.withValues(alpha: 0.08) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _hovering ? primary.withValues(alpha: 0.3) : const Color(0xFF21262D)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(widget.icon, size: 16, color: _hovering ? primary : const Color(0xFF8B949E)),
            const SizedBox(width: 8),
            Text(widget.label, style: TextStyle(
                color: _hovering ? primary : const Color(0xFF8B949E), fontSize: 13, fontWeight: FontWeight.w500)),
          ]),
        ),
      ),
    );
  }
}
