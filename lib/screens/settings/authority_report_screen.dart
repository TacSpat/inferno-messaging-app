import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/database.dart';
import '../../services/authority_report_generator.dart';
import '../../theme/all_themes.dart';
import '../../theme/theme_provider.dart';

class AuthorityReportScreen extends ConsumerStatefulWidget {
  final Message message;
  final InfernoDatabase db;

  const AuthorityReportScreen({
    super.key,
    required this.message,
    required this.db,
  });

  @override
  ConsumerState<AuthorityReportScreen> createState() => _AuthorityReportScreenState();
}

class _AuthorityReportScreenState extends ConsumerState<AuthorityReportScreen> {
  String _category = 'csam';
  String? _report;
  bool _generating = false;
  bool _copied = false;

  Future<void> _generate() async {
    setState(() { _generating = true; _report = null; _copied = false; });

    // Get local user info for reporter field
    final localUser = await (widget.db.select(widget.db.users)..limit(1)).getSingleOrNull();

    final generator = AuthorityReportGenerator(
      widget.db,
      message: widget.message,
      category: _category,
      reporterPubkey: localUser?.nostrPublicKey ?? 'unknown',
      reporterUsername: localUser?.username ?? 'unknown',
    );

    final report = await generator.generate();
    setState(() { _report = report; _generating = false; });
  }

  void _copyToClipboard() {
    if (_report != null) {
      Clipboard.setData(ClipboardData(text: _report!));
      setState(() => _copied = true);
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _copied = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Report to Authorities',
            style: TextStyle(color: c.gray50, fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(
          'Generate a formatted report for law enforcement containing message metadata, '
          'sender information, and relay details.',
          style: TextStyle(color: c.gray500, fontSize: 13),
        ),
        const SizedBox(height: 24),

        // Category dropdown
        Text('REPORT CATEGORY',
            style: TextStyle(color: c.gray400, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: c.gray900,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c.gray700),
          ),
          child: DropdownButton<String>(
            value: _category,
            isExpanded: true,
            dropdownColor: c.gray900,
            underline: const SizedBox(),
            style: TextStyle(color: c.gray200, fontSize: 14),
            items: AuthorityReportGenerator.categories.entries
                .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                .toList(),
            onChanged: (v) => setState(() => _category = v ?? _category),
          ),
        ),
        const SizedBox(height: 16),

        // Message info
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: c.gray900,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c.gray700),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _infoRow('Message ID', widget.message.publicId, c),
              _infoRow('Event ID', widget.message.nostrEventId ?? 'N/A', c),
              _infoRow('Sender', widget.message.nostrAuthorPubkey ?? 'local', c),
              _infoRow('Hidden Reason', widget.message.hiddenReason ?? 'N/A', c),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Generate button
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _generating ? null : _generate,
            style: ElevatedButton.styleFrom(
              backgroundColor: c.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            child: _generating
                ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Generate Report', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),

        // Report output
        if (_report != null) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Text('GENERATED REPORT',
                  style: TextStyle(color: c.gray400, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
              const Spacer(),
              TextButton.icon(
                onPressed: _copyToClipboard,
                icon: Icon(_copied ? Icons.check : Icons.copy, size: 14),
                label: Text(_copied ? 'Copied!' : 'Copy'),
                style: TextButton.styleFrom(foregroundColor: c.accent),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: c.gray950,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: c.gray700),
            ),
            child: SelectableText(
              _report!,
              style: TextStyle(
                color: c.gray200,
                fontSize: 12,
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _infoRow(String label, String value, InfernoColors c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: TextStyle(color: c.gray500, fontSize: 12)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(color: c.gray200, fontSize: 12),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
