import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/all_themes.dart';

class SafetyScreen extends ConsumerWidget {
  const SafetyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = Theme.of(context).extension<InfernoColors>()!;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Content Safety', style: TextStyle(color: c.gray50, fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text('Manage content filtering and safety settings.', style: TextStyle(color: c.gray400, fontSize: 14)),
        const SizedBox(height: 24),

        _label('CONTENT FILTERING', c),
        const SizedBox(height: 12),
        _toggleRow('Blur NSFW content', 'Blur images marked as NSFW until clicked', true, c),
        const SizedBox(height: 8),
        _toggleRow('Hide messages from unknown users', 'Only show messages from contacts and server members', false, c),
        const SizedBox(height: 8),
        _toggleRow('Block explicit content', 'Filter messages containing explicit content', false, c),

        const SizedBox(height: 24),
        Container(height: 1, color: c.gray700),
        const SizedBox(height: 24),

        _label('DIRECT MESSAGES', c),
        const SizedBox(height: 12),
        _toggleRow('Allow DMs from server members', 'Let anyone in your servers send you DMs', true, c),
        const SizedBox(height: 8),
        _toggleRow('Allow DMs from everyone', 'Let anyone on Nostr send you DMs', false, c),

        const SizedBox(height: 24),
        Container(height: 1, color: c.gray700),
        const SizedBox(height: 24),

        _label('BLOCKED USERS', c),
        const SizedBox(height: 8),
        Text('Manage your block list in the Contacts tab (Friends > Blocked).',
          style: TextStyle(color: c.gray500, fontSize: 13)),
      ],
    );
  }

  Widget _label(String text, InfernoColors c) => Text(text,
    style: TextStyle(color: c.gray400, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.5));

  Widget _toggleRow(String label, String desc, bool value, InfernoColors c) {
    return Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(color: c.gray200, fontSize: 14)),
        Text(desc, style: TextStyle(color: c.gray500, fontSize: 12)),
      ])),
      Switch(value: value, onChanged: (_) {}, activeColor: c.accent),
    ]);
  }
}
