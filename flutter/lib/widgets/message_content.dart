import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/all_themes.dart';

/// Regex patterns
final _imageUrlPattern = RegExp(r'\.(png|jpg|jpeg|gif|webp|avif|svg)(\?.*)?$', caseSensitive: false);
final _blossomPattern = RegExp(r'https?://blossom\.\S+', caseSensitive: false);
final _videoUrlPattern = RegExp(r'\.(mp4|webm|mov|ogv)(\?.*)?$', caseSensitive: false);
final _urlPattern = RegExp(r'https?://\S+', caseSensitive: false);
final _singleEmojiPattern = RegExp(r'^[\p{Emoji_Presentation}\p{Emoji}\u200d\ufe0f]{1,7}$', unicode: true);
final _customEmojiPattern = RegExp(r':([a-zA-Z0-9_]+):');

/// Renders message content with full markdown support matching Rails Redcarpet output:
/// - Bold, italic, strikethrough, inline code, fenced code blocks
/// - Headers, lists, blockquotes, tables
/// - Inline images for image URLs (Blossom, etc.)
/// - Large emoji for emoji-only messages
/// - Autolinked URLs
class MessageContent extends StatelessWidget {
  final String content;
  final InfernoColors colors;
  final bool isSpoiler;

  const MessageContent({super.key, required this.content, required this.colors, this.isSpoiler = false});

  @override
  Widget build(BuildContext context) {
    if (content.isEmpty) return const SizedBox.shrink();

    final trimmed = content.trim();

    // Check if content is a single emoji (render large)
    if (_singleEmojiPattern.hasMatch(trimmed) && trimmed.length <= 10) {
      return _maybeSpoiler(Text(trimmed, style: const TextStyle(fontSize: 48)));
    }

    // Check if content is a single image URL
    if (_isImageUrl(trimmed) && !trimmed.contains('\n') && !trimmed.contains(' ')) {
      return _maybeSpoiler(_buildImageEmbed(trimmed));
    }

    // Split content: extract image URLs on their own lines, render rest as markdown
    final parts = _splitContent(trimmed);
    if (parts.length == 1 && parts[0].type == 'text') {
      // Pure text — render as markdown
      return _maybeSpoiler(_buildMarkdown(parts[0].content));
    }

    // Mixed content — markdown blocks + inline images
    return _maybeSpoiler(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: parts.map((part) {
        if (part.type == 'image') return _buildImageEmbed(part.content);
        if (part.type == 'video') return _buildVideoPlaceholder(part.content);
        return _buildMarkdown(part.content);
      }).toList(),
    ));
  }

  Widget _maybeSpoiler(Widget child) {
    if (!isSpoiler) return child;
    return _SpoilerWrap(colors: colors, child: child);
  }

  List<_ContentPart> _splitContent(String text) {
    final parts = <_ContentPart>[];
    final lines = text.split('\n');
    final textBuffer = StringBuffer();

    for (final line in lines) {
      final trimmedLine = line.trim();
      if (_isImageUrl(trimmedLine)) {
        if (textBuffer.isNotEmpty) {
          parts.add(_ContentPart('text', textBuffer.toString().trimRight()));
          textBuffer.clear();
        }
        parts.add(_ContentPart('image', trimmedLine));
      } else if (_isVideoUrl(trimmedLine)) {
        if (textBuffer.isNotEmpty) {
          parts.add(_ContentPart('text', textBuffer.toString().trimRight()));
          textBuffer.clear();
        }
        parts.add(_ContentPart('video', trimmedLine));
      } else {
        textBuffer.writeln(line);
      }
    }

    if (textBuffer.isNotEmpty) {
      final remaining = textBuffer.toString().trimRight();
      if (remaining.isNotEmpty) parts.add(_ContentPart('text', remaining));
    }

    return parts.isEmpty ? [_ContentPart('text', text)] : parts;
  }

  bool _isImageUrl(String text) {
    if (!_urlPattern.hasMatch(text)) return false;
    return _imageUrlPattern.hasMatch(text) || _blossomPattern.hasMatch(text);
  }

  bool _isVideoUrl(String text) {
    return _urlPattern.hasMatch(text) && _videoUrlPattern.hasMatch(text);
  }

  Widget _buildMarkdown(String text) {
    return MarkdownBody(
      data: text,
      selectable: true,
      softLineBreak: true, // hard_wrap: true equivalent
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(color: colors.gray200, fontSize: 15, height: 1.4),
        a: TextStyle(color: colors.accent, decoration: TextDecoration.underline),
        strong: TextStyle(color: colors.gray200, fontWeight: FontWeight.bold),
        em: TextStyle(color: colors.gray200, fontStyle: FontStyle.italic),
        del: TextStyle(color: colors.gray400, decoration: TextDecoration.lineThrough),
        code: TextStyle(color: colors.gray200, fontSize: 13, fontFamily: 'monospace', backgroundColor: colors.gray900),
        codeblockDecoration: BoxDecoration(
          color: colors.gray900,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: colors.gray700),
        ),
        codeblockPadding: const EdgeInsets.all(12),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: colors.gray500, width: 3)),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
        h1: TextStyle(color: colors.gray50, fontSize: 24, fontWeight: FontWeight.bold),
        h2: TextStyle(color: colors.gray50, fontSize: 20, fontWeight: FontWeight.bold),
        h3: TextStyle(color: colors.gray50, fontSize: 18, fontWeight: FontWeight.bold),
        h4: TextStyle(color: colors.gray50, fontSize: 16, fontWeight: FontWeight.bold),
        h5: TextStyle(color: colors.gray50, fontSize: 15, fontWeight: FontWeight.bold),
        h6: TextStyle(color: colors.gray200, fontSize: 14, fontWeight: FontWeight.bold),
        listBullet: TextStyle(color: colors.gray400),
        tableHead: TextStyle(color: colors.gray200, fontWeight: FontWeight.bold),
        tableBody: TextStyle(color: colors.gray200),
        tableBorder: TableBorder.all(color: colors.gray700, width: 1),
        tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        horizontalRuleDecoration: BoxDecoration(border: Border(top: BorderSide(color: colors.gray700))),
      ),
      onTapLink: (text, href, title) {
        if (href != null) {
          launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
        }
      },
    );
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

  Widget _buildVideoPlaceholder(String url) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: colors.gray900, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        Icon(Icons.play_circle_outline, size: 24, color: colors.accent),
        const SizedBox(width: 8),
        Expanded(child: Text(url, style: TextStyle(color: colors.accent, fontSize: 13), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}

class _ContentPart {
  final String type; // 'text', 'image', 'video'
  final String content;
  _ContentPart(this.type, this.content);
}

/// Spoiler wrapper — click to reveal
class _SpoilerWrap extends StatefulWidget {
  final InfernoColors colors;
  final Widget child;
  const _SpoilerWrap({required this.colors, required this.child});

  @override
  State<_SpoilerWrap> createState() => _SpoilerWrapState();
}

class _SpoilerWrapState extends State<_SpoilerWrap> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _revealed = !_revealed),
      child: Stack(
        children: [
          widget.child,
          if (!_revealed)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: widget.colors.gray900,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Center(
                  child: Text('Spoiler — click to reveal',
                    style: TextStyle(color: widget.colors.gray500, fontSize: 13)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
