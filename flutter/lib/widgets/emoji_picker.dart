import 'package:flutter/material.dart';

class EmojiPicker extends StatelessWidget {
  final void Function(String emoji) onSelect;

  const EmojiPicker({super.key, required this.onSelect});

  static const _commonEmojis = [
    // Smileys
    '\u{1F600}', '\u{1F602}', '\u{1F605}', '\u{1F923}', '\u{1F60D}', '\u{1F618}',
    '\u{1F60E}', '\u{1F914}', '\u{1F644}', '\u{1F62D}', '\u{1F621}', '\u{1F631}',
    '\u{1F4AF}', '\u{1F525}', '\u{2764}', '\u{1F44D}', '\u{1F44E}', '\u{1F44F}',
    '\u{1F64F}', '\u{1F389}', '\u{1F680}', '\u{2705}', '\u{274C}', '\u{26A0}',
    // Reactions
    '+', '-', '\u{1F440}', '\u{1F4A9}', '\u{1F3C6}', '\u{1F48E}',
    '\u{2B50}', '\u{1F31F}', '\u{1F4A1}', '\u{1F4AC}', '\u{1F516}', '\u{1F6A9}',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 200,
      decoration: const BoxDecoration(
        color: Color(0xFF16213E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Reactions', style: TextStyle(color: Color(0xFF8899A6), fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 8,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
              ),
              itemCount: _commonEmojis.length,
              itemBuilder: (context, index) {
                final emoji = _commonEmojis[index];
                return InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => onSelect(emoji),
                  child: Center(
                    child: Text(emoji, style: const TextStyle(fontSize: 24, fontFamilyFallback: ['NotoColorEmoji'])),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
