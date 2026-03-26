import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/all_themes.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = Theme.of(context).extension<InfernoColors>()!;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Notifications', style: TextStyle(color: c.gray50, fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text('Control how and when you receive notifications.', style: TextStyle(color: c.gray400, fontSize: 14)),
        const SizedBox(height: 24),

        _label('DESKTOP NOTIFICATIONS', c),
        const SizedBox(height: 12),
        _ToggleRow(label: 'Enable desktop notifications', description: 'Show system notifications for new messages',
          value: true, colors: c, onChanged: (_) {}),
        const SizedBox(height: 8),
        _ToggleRow(label: 'Enable notification sounds', description: 'Play a sound when a notification arrives',
          value: true, colors: c, onChanged: (_) {}),
        const SizedBox(height: 24),

        Container(height: 1, color: c.gray700),
        const SizedBox(height: 24),

        _label('SERVER NOTIFICATIONS', c),
        const SizedBox(height: 12),
        Text('Default notification setting for all servers:', style: TextStyle(color: c.gray400, fontSize: 13)),
        const SizedBox(height: 8),
        _RadioRow(label: 'All Messages', description: 'Get notified for every message',
          selected: false, colors: c, onTap: () {}),
        _RadioRow(label: 'Only @Mentions', description: 'Only when someone mentions you',
          selected: true, colors: c, onTap: () {}),
        _RadioRow(label: 'Nothing', description: 'Suppress all notifications',
          selected: false, colors: c, onTap: () {}),

        const SizedBox(height: 24),
        Container(height: 1, color: c.gray700),
        const SizedBox(height: 24),

        _label('DIRECT MESSAGES', c),
        const SizedBox(height: 12),
        _ToggleRow(label: 'DM notifications', description: 'Show notifications for direct messages',
          value: true, colors: c, onChanged: (_) {}),
      ],
    );
  }

  Widget _label(String text, InfernoColors c) => Text(text,
    style: TextStyle(color: c.gray400, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.5));
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final String description;
  final bool value;
  final InfernoColors colors;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({required this.label, required this.description, required this.value, required this.colors, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(color: c.gray200, fontSize: 14)),
        Text(description, style: TextStyle(color: c.gray500, fontSize: 12)),
      ])),
      Switch(value: value, onChanged: onChanged, activeColor: c.accent),
    ]);
  }
}

class _RadioRow extends StatefulWidget {
  final String label;
  final String description;
  final bool selected;
  final InfernoColors colors;
  final VoidCallback onTap;
  const _RadioRow({required this.label, required this.description, required this.selected, required this.colors, required this.onTap});
  @override
  State<_RadioRow> createState() => _RadioRowState();
}

class _RadioRowState extends State<_RadioRow> {
  bool _hovering = false;
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          margin: const EdgeInsets.only(bottom: 4),
          decoration: BoxDecoration(gradient: _hovering ? LinearGradient(colors: [c.accent.withValues(alpha: 0.08), Colors.transparent]) : null, borderRadius: BorderRadius.circular(4)),
          child: Row(children: [
            Container(
              width: 18, height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: widget.selected ? c.accent : c.gray500, width: 2),
              ),
              child: widget.selected ? Center(child: Container(width: 8, height: 8,
                  decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle))) : null,
            ),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.label, style: TextStyle(color: c.gray200, fontSize: 14)),
              Text(widget.description, style: TextStyle(color: c.gray500, fontSize: 12)),
            ])),
          ]),
        ),
      ),
    );
  }
}
