import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import '../theme/all_themes.dart';

/// Regex patterns for content rendering
final _urlPattern = RegExp(r'https?://\S+', caseSensitive: false);
final _imageExtPattern = RegExp(r'\.(png|jpg|jpeg|gif|webp|avif|svg)(\?.*)?$', caseSensitive: false);
final _blossomPattern = RegExp(r'https?://blossom\.\S+', caseSensitive: false);
final _singleEmojiPattern = RegExp(r'^[\p{Emoji_Presentation}\p{Emoji}\u200d\ufe0f]{1,7}$', unicode: true);
final _spoilerPattern = RegExp(r'\|\|(.+?)\|\|', dotAll: true);
final _boldPattern = RegExp(r'\*\*(.+?)\*\*');
final _italicPattern = RegExp(r'(?<!\*)\*([^*]+)\*(?!\*)');
final _codePattern = RegExp(r'`([^`]+)`');
final _customEmojiPattern = RegExp(r':([a-zA-Z0-9_]+):');

/// Renders message content with inline images, large emoji, spoilers, and basic markdown.
class MessageContent extends StatelessWidget {
  final String content;
  final InfernoColors colors;

  const MessageContent({super.key, required this.content, required this.colors});

  @override
  Widget build(BuildContext context) {
    if (content.isEmpty) return const SizedBox.shrink();

    // Check if content is a single emoji (render large)
    final trimmed = content.trim();
    if (_singleEmojiPattern.hasMatch(trimmed) && trimmed.length <= 10) {
      return Text(trimmed, style: const TextStyle(fontSize: 48));
    }

    // Check if content is a single image URL
    if (_isImageUrl(trimmed) && !trimmed.contains('\n') && !trimmed.contains(' ')) {
      return _buildImageEmbed(trimmed);
    }

    // Parse fenced code blocks first, then process remaining lines
    final widgets = <Widget>[];
    final codeBlockPattern = RegExp(r'```(\w*)\n([\s\S]*?)```', multiLine: true);
    int lastEnd = 0;

    for (final match in codeBlockPattern.allMatches(content)) {
      // Process text before this code block
      if (match.start > lastEnd) {
        _addLinesAsWidgets(widgets, content.substring(lastEnd, match.start));
      }
      // Render code block
      final lang = match.group(1) ?? '';
      final code = match.group(2) ?? '';
      widgets.add(_buildCodeBlock(code.trimRight(), lang));
      lastEnd = match.end;
    }

    // Process remaining text after last code block
    if (lastEnd < content.length) {
      _addLinesAsWidgets(widgets, content.substring(lastEnd));
    }

    if (widgets.isEmpty) {
      return Text(content, style: TextStyle(color: colors.gray200, fontSize: 15, height: 1.4));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  void _addLinesAsWidgets(List<Widget> widgets, String text) {
    final lines = text.split('\n');
    for (final line in lines) {
      if (line.trim().isEmpty) {
        widgets.add(const SizedBox(height: 4));
        continue;
      }
      final trimmedLine = line.trim();
      if (_isImageUrl(trimmedLine)) {
        widgets.add(_buildImageEmbed(trimmedLine));
        continue;
      }
      widgets.add(_buildRichLine(trimmedLine));
    }
  }

  Widget _buildCodeBlock(String code, String lang) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.gray900,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.gray700),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (lang.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(lang, style: TextStyle(color: colors.gray500, fontSize: 11, fontWeight: FontWeight.w600)),
            ),
          Text(
            code,
            style: TextStyle(
              color: colors.gray200,
              fontSize: 13,
              fontFamily: 'monospace',
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  bool _isImageUrl(String text) {
    if (!_urlPattern.hasMatch(text)) return false;
    return _imageExtPattern.hasMatch(text) || _blossomPattern.hasMatch(text);
  }

  Widget _buildImageEmbed(String url) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 350),
          child: Image.network(
            url,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return Container(
                width: 200, height: 150,
                decoration: BoxDecoration(color: colors.gray700, borderRadius: BorderRadius.circular(8)),
                child: Center(child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: loadingProgress.expectedTotalBytes != null
                      ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                      : null,
                  color: colors.gray500,
                )),
              );
            },
            errorBuilder: (context, error, stackTrace) => Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: colors.gray700, borderRadius: BorderRadius.circular(4)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.broken_image, size: 16, color: colors.gray500),
                const SizedBox(width: 4),
                Flexible(child: Text(url, style: TextStyle(color: colors.gray500, fontSize: 12), overflow: TextOverflow.ellipsis)),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRichLine(String text) {
    // Build spans with formatting
    final spans = <InlineSpan>[];
    int lastEnd = 0;

    // Find all special patterns and their positions
    final matches = <_Match>[];

    for (final match in _boldPattern.allMatches(text)) {
      matches.add(_Match(match.start, match.end, 'bold', match.group(1)!));
    }
    for (final match in _spoilerPattern.allMatches(text)) {
      matches.add(_Match(match.start, match.end, 'spoiler', match.group(1)!));
    }
    for (final match in _codePattern.allMatches(text)) {
      matches.add(_Match(match.start, match.end, 'code', match.group(1)!));
    }
    for (final match in _urlPattern.allMatches(text)) {
      // Skip if it's an image URL (handled separately)
      if (!_isImageUrl(match.group(0)!)) {
        matches.add(_Match(match.start, match.end, 'url', match.group(0)!));
      }
    }

    // Sort by position, remove overlaps
    matches.sort((a, b) => a.start.compareTo(b.start));
    final filtered = <_Match>[];
    int lastMatchEnd = 0;
    for (final m in matches) {
      if (m.start >= lastMatchEnd) {
        filtered.add(m);
        lastMatchEnd = m.end;
      }
    }

    for (final m in filtered) {
      if (m.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, m.start), style: TextStyle(color: colors.gray200, fontSize: 15, height: 1.4)));
      }
      switch (m.type) {
        case 'bold':
          spans.add(TextSpan(text: m.content, style: TextStyle(color: colors.gray200, fontSize: 15, height: 1.4, fontWeight: FontWeight.bold)));
        case 'spoiler':
          spans.add(WidgetSpan(child: _SpoilerText(text: m.content, colors: colors)));
        case 'code':
          spans.add(WidgetSpan(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(color: colors.gray900, borderRadius: BorderRadius.circular(3)),
            child: Text(m.content, style: TextStyle(color: colors.gray200, fontSize: 14, fontFamily: 'monospace')),
          )));
        case 'url':
          spans.add(TextSpan(
            text: m.content,
            style: TextStyle(color: colors.accent, fontSize: 15, height: 1.4, decoration: TextDecoration.underline),
          ));
      }
      lastEnd = m.end;
    }

    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd), style: TextStyle(color: colors.gray200, fontSize: 15, height: 1.4)));
    }

    if (spans.isEmpty) {
      return Text(text, style: TextStyle(color: colors.gray200, fontSize: 15, height: 1.4));
    }

    return RichText(text: TextSpan(children: spans));
  }
}

class _Match {
  final int start, end;
  final String type, content;
  _Match(this.start, this.end, this.type, this.content);
}

class _SpoilerText extends StatefulWidget {
  final String text;
  final InfernoColors colors;
  const _SpoilerText({required this.text, required this.colors});

  @override
  State<_SpoilerText> createState() => _SpoilerTextState();
}

class _SpoilerTextState extends State<_SpoilerText> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _revealed = !_revealed),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: _revealed ? widget.colors.gray700 : widget.colors.gray200,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          widget.text,
          style: TextStyle(
            color: _revealed ? widget.colors.gray200 : widget.colors.gray200,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}
