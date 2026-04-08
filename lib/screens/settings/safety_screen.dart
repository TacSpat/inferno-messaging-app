import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../database/database.dart';
import '../../providers/database_provider.dart';
import '../../theme/all_themes.dart';
import '../../services/content_safety_service.dart';
import '../../theme/theme_provider.dart';
import '../../widgets/fire_shield.dart';
import 'authority_report_screen.dart';

class SafetyScreen extends ConsumerStatefulWidget {
  const SafetyScreen({super.key});

  @override
  ConsumerState<SafetyScreen> createState() => _SafetyScreenState();
}

class _SafetyScreenState extends ConsumerState<SafetyScreen> {
  AppSetting? _settings;
  int _hiddenCount = 0;
  List<Message> _hiddenMessages = [];
  bool _showAdvanced = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadHiddenMessages();
  }

  Future<void> _loadSettings() async {
    final db = ref.read(databaseProvider);
    final settings = await (db.select(db.appSettings)..limit(1)).getSingle();
    if (mounted) setState(() => _settings = settings);
  }

  Future<void> _loadHiddenMessages() async {
    final db = ref.read(databaseProvider);
    final messages = await (db.select(db.messages)
          ..where((m) => m.hiddenAt.isNotNull())
          ..orderBy([(m) => OrderingTerm.desc(m.hiddenAt)]))
        .get();
    final count = messages.length;
    if (mounted) setState(() { _hiddenMessages = messages; _hiddenCount = count; });
  }

  Future<void> _updateSetting(ContentSafetyUpdate update) async {
    final db = ref.read(databaseProvider);
    await (db.update(db.appSettings)..where((s) => s.id.equals(_settings!.id)))
        .write(update.companion);
    await _loadSettings();
  }

  bool get _isStandard => _settings?.safetyProtectionLevel == 'standard';

  Future<void> _toggleProtection() async {
    final newLevel = _isStandard ? 'relaxed' : 'standard';
    await _updateSetting(ContentSafetyUpdate(
      AppSettingsCompanion(safetyProtectionLevel: Value(newLevel)),
    ));
  }

  Future<void> _unhideMessage(Message message) async {
    final db = ref.read(databaseProvider);
    final service = ContentSafetyService(db);
    final success = await service.unhide(message.id);
    if (success) {
      await _loadHiddenMessages();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message unhidden')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);
    if (_settings == null) return const Center(child: CircularProgressIndicator());

    final screenWidth = MediaQuery.of(context).size.width;
    final shieldScale = screenWidth < 800 ? 0.7 : 1.0;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Content Safety', style: TextStyle(color: c.gray50, fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),

        // ── Fire Shield ──
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: FireShield(
              isActive: _isStandard,
              onToggle: _toggleProtection,
              scale: shieldScale,
            ),
          ),
        ),

        // ── Title + subtitle ──
        Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            child: Column(
              key: ValueKey(_isStandard),
              children: [
                Text(
                  _isStandard ? 'Firewall Active' : 'Firewall Lowered',
                  style: TextStyle(
                    color: _isStandard ? const Color(0xFFFBBF24) : const Color(0xFF706E6C),
                    fontSize: 20, fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _isStandard
                      ? 'Full protection is on. Harmful images, spam, and unknown senders are blocked.'
                      : 'Image protection stays on. Spam and sender filtering are off.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _isStandard ? const Color(0xFFA8A7A5) : const Color(0xFF5C5A58),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 24),

        // ── Protection stats ──
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.verified_user_outlined, color: Colors.green.withValues(alpha: 0.6), size: 16),
            const SizedBox(width: 6),
            Text(
              "You've helped protect the network from $_hiddenCount harmful message${_hiddenCount == 1 ? '' : 's'}.",
              style: TextStyle(color: c.gray500, fontSize: 12),
            ),
          ],
        ),

        const SizedBox(height: 24),
        Container(height: 1, color: c.gray700),
        const SizedBox(height: 24),

        // ── NSFW blur toggle ──
        _toggleCard(
          'Blur NSFW content',
          'Blurs images in age-restricted channels and profile pictures or banners detected as explicit. Click any blurred image to reveal it.',
          _settings!.safetyBlurNsfw,
          (v) => _updateSetting(ContentSafetyUpdate(
            AppSettingsCompanion(safetyBlurNsfw: Value(v)),
          )),
          c,
        ),

        const SizedBox(height: 24),
        Container(height: 1, color: c.gray700),
        const SizedBox(height: 24),

        // ── Hidden Messages ──
        Row(
          children: [
            Text('Hidden Messages', style: TextStyle(color: c.gray400, fontSize: 14, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text('${_hiddenMessages.length}', style: TextStyle(color: c.gray500, fontSize: 13)),
          ],
        ),
        const SizedBox(height: 16),

        if (_hiddenMessages.isEmpty)
          _emptyHiddenState(c)
        else
          ..._hiddenMessages.map((msg) => _hiddenMessageCard(msg, c)),

        const SizedBox(height: 24),
        Container(height: 1, color: c.gray700),
        const SizedBox(height: 24),

        // ── Advanced Settings ──
        GestureDetector(
          onTap: () => setState(() => _showAdvanced = !_showAdvanced),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Row(
              children: [
                Text('Advanced Settings', style: TextStyle(color: c.gray400, fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                Icon(
                  _showAdvanced ? Icons.expand_less : Icons.expand_more,
                  color: c.gray500, size: 20,
                ),
              ],
            ),
          ),
        ),

        if (_showAdvanced) ...[
          const SizedBox(height: 16),
          _toggleCard(
            'Hide unknown senders',
            'Auto-hide DMs from people who are not your friend or a known contact.',
            _settings!.safetyHideUnknownSenders,
            (v) => _updateSetting(ContentSafetyUpdate(
              AppSettingsCompanion(safetyHideUnknownSenders: Value(v)),
            )),
            c,
          ),
          const SizedBox(height: 8),
          _toggleCard(
            'Block links',
            'Auto-hide messages containing URLs.',
            _settings!.safetyBlockLinks,
            (v) => _updateSetting(ContentSafetyUpdate(
              AppSettingsCompanion(safetyBlockLinks: Value(v)),
            )),
            c,
          ),
          const SizedBox(height: 8),
          _toggleCard(
            'Block phone numbers',
            'Auto-hide messages containing phone numbers.',
            _settings!.safetyBlockPhoneNumbers,
            (v) => _updateSetting(ContentSafetyUpdate(
              AppSettingsCompanion(safetyBlockPhoneNumbers: Value(v)),
            )),
            c,
          ),
          const SizedBox(height: 8),
          _toggleCard(
            'Block ALL CAPS',
            'Auto-hide messages that are >80% uppercase and over 10 characters.',
            _settings!.safetyBlockAllCaps,
            (v) => _updateSetting(ContentSafetyUpdate(
              AppSettingsCompanion(safetyBlockAllCaps: Value(v)),
            )),
            c,
          ),
          const SizedBox(height: 8),
          _toggleCard(
            'Block spam characters',
            'Auto-hide messages with 5+ consecutive identical special characters.',
            _settings!.safetyBlockSpamChars,
            (v) => _updateSetting(ContentSafetyUpdate(
              AppSettingsCompanion(safetyBlockSpamChars: Value(v)),
            )),
            c,
          ),


          // Keyword filter
          const SizedBox(height: 16),
          Text('KEYWORD FILTER',
              style: TextStyle(color: c.gray500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
          const SizedBox(height: 6),
          Text('Comma-separated list of words to block.',
              style: TextStyle(color: c.gray600, fontSize: 12)),
          const SizedBox(height: 6),
          TextField(
            controller: TextEditingController(text: _settings!.safetyKeywordFilter),
            onSubmitted: (v) => _updateSetting(ContentSafetyUpdate(
              AppSettingsCompanion(safetyKeywordFilter: Value(v)),
            )),
            style: TextStyle(color: c.gray200, fontSize: 13),
            decoration: InputDecoration(
              filled: true, fillColor: c.gray900,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.accent)),
              hintText: 'e.g. spam, scam, phishing',
              hintStyle: TextStyle(color: c.gray600),
            ),
          ),
        ],
      ],
    );
  }

  // ── Reusable widgets ──

  Widget _toggleCard(String title, String subtitle, bool value, ValueChanged<bool> onChanged, InfernoColors c) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.gray800,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(color: c.gray500, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: c.accent,
          ),
        ],
      ),
    );
  }

  Widget _sliderSetting(String title, String subtitle, double value,
      double min, double max, ValueChanged<double> onChanged, InfernoColors c) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.gray800,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w500))),
              Text(value.round().toString(), style: TextStyle(color: c.accent, fontSize: 14, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(color: c.gray500, fontSize: 12)),
          const SizedBox(height: 8),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: c.accent,
              inactiveTrackColor: c.gray700,
              thumbColor: c.accent,
              overlayColor: c.accent.withValues(alpha: 0.2),
            ),
            child: Slider(value: value, min: min, max: max, onChanged: onChanged),
          ),
        ],
      ),
    );
  }

  Widget _dropdownSetting(String title, String subtitle, String value,
      Map<String, String> options, ValueChanged<String> onChanged, InfernoColors c) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.gray800,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(color: c.gray500, fontSize: 12)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: c.gray900,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: c.gray700),
            ),
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              dropdownColor: c.gray900,
              underline: const SizedBox(),
              style: TextStyle(color: c.gray200, fontSize: 13),
              items: options.entries
                  .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                  .toList(),
              onChanged: (v) { if (v != null) onChanged(v); },
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyHiddenState(InfernoColors c) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(
          children: [
            Icon(Icons.verified_user_outlined, color: c.gray600, size: 48),
            const SizedBox(height: 12),
            Text('No hidden messages', style: TextStyle(color: c.gray500, fontSize: 14)),
            const SizedBox(height: 4),
            Text(
              'Messages hidden by your filters will appear here for review.',
              style: TextStyle(color: c.gray600, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hiddenMessageCard(Message message, InfernoColors c) {
    final reason = message.hiddenReason?.replaceFirst('auto:', '') ?? 'unknown';
    final isCsam = reason.contains('csam');
    final dateFmt = DateFormat('MMM d, yyyy HH:mm');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.gray900,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.gray700),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _reasonBadge(reason, c),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message.nostrAuthorPubkey != null
                      ? '${message.nostrAuthorPubkey!.substring(0, 12)}...'
                      : 'Local user',
                  style: TextStyle(color: c.gray400, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                message.hiddenAt != null ? dateFmt.format(message.hiddenAt!) : '',
                style: TextStyle(color: c.gray600, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!isCsam && message.content != null && message.content!.isNotEmpty)
            Text(
              message.content!,
              style: TextStyle(color: c.gray400, fontSize: 13),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          if (isCsam)
            Text(
              '[Content blocked by automated safety systems]',
              style: TextStyle(color: c.gray600, fontSize: 13, fontStyle: FontStyle.italic),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (!isCsam)
                TextButton(
                  onPressed: () => _unhideMessage(message),
                  style: TextButton.styleFrom(foregroundColor: c.gray400),
                  child: const Text('Unhide', style: TextStyle(fontSize: 12)),
                ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => _showAuthorityReport(message),
                style: TextButton.styleFrom(foregroundColor: c.accent),
                child: const Text('Report to Authorities', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _reasonBadge(String reason, InfernoColors c) {
    final (label, color) = switch (reason) {
      'csam_match' => ('CSAM', Colors.red),
      'nsfw' => ('NSFW', Colors.orange),
      'unknown_sender' => ('Unknown Sender', Colors.blue),
      'reported' => ('Reported', Colors.yellow.shade700),
      'low_reputation' => ('Low Reputation', Colors.purple),
      'image_match' => ('Image Match', Colors.orange),
      'blocked_link' => ('Link', Colors.teal),
      'blocked_phone' => ('Phone', Colors.teal),
      'blocked_caps' => ('ALL CAPS', Colors.teal),
      'blocked_spam' => ('Spam', Colors.teal),
      'blocked_keyword' => ('Keyword', Colors.teal),
      _ => (reason, c.gray500),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
  }

  void _showAuthorityReport(Message message) {
    final db = ref.read(databaseProvider);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: ref.read(infernoColorsProvider).gray950,
        child: SizedBox(
          width: 700,
          height: 600,
          child: AuthorityReportScreen(message: message, db: db),
        ),
      ),
    );
  }
}

/// Helper to pass update companions through to the settings update method.
class ContentSafetyUpdate {
  final AppSettingsCompanion companion;
  ContentSafetyUpdate(this.companion);
}
