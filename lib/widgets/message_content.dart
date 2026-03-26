import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:markdown/markdown.dart' as md;
import '../theme/all_themes.dart';

/// Cache of resolved image dimensions: url -> Size
final _imageSizeCache = <String, Size>{};

/// Regex patterns
final _imageUrlPattern = RegExp(r'\.(png|jpg|jpeg|gif|webp|avif|svg)(\?.*)?$', caseSensitive: false);
final _blossomPattern = RegExp(r'https?://blossom\.\S+', caseSensitive: false);
final _videoUrlPattern = RegExp(r'\.(mp4|webm|mov|ogv)(\?.*)?$', caseSensitive: false);
final _urlPattern = RegExp(r'https?://\S+', caseSensitive: false);
final _singleEmojiPattern = RegExp(r'^[\p{Emoji_Presentation}\p{Emoji}\u200d\ufe0f]{1,7}$', unicode: true);
final _customEmojiPattern = RegExp(r':([a-zA-Z0-9_]+):');
final _mentionPattern = RegExp(r'nostr:npub[a-z0-9]{59}');
final _youtubePattern = RegExp(r'(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/shorts/)([a-zA-Z0-9_-]{11})', caseSensitive: false);
final _tenorPattern = RegExp(r'https?://(?:tenor\.com/view/|media\.tenor\.com/)\S+', caseSensitive: false);
final _tenorGifPattern = RegExp(r'https?://media\.tenor\.com/\S+\.gif', caseSensitive: false);

/// Renders message content with full markdown support matching Rails Redcarpet output:
/// - Bold, italic, strikethrough, inline code, fenced code blocks with syntax highlighting
/// - Headers, lists, blockquotes, tables
/// - Inline images for image URLs (Blossom, etc.)
/// - Large emoji for emoji-only messages
/// - Custom emoji (:name:) rendered as inline images
/// - @mention highlighting (nostr:npub...)
/// - Autolinked URLs
class MessageContent extends StatelessWidget {
  final String content;
  final InfernoColors colors;
  final bool isSpoiler;
  /// Custom emoji map: name -> imageUrl (from server_emojis table)
  final Map<String, String>? customEmojis;

  const MessageContent({
    super.key,
    required this.content,
    required this.colors,
    this.isSpoiler = false,
    this.customEmojis,
  });

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

    // Mixed content — markdown blocks + inline images + embeds
    return _maybeSpoiler(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: parts.map((part) {
        if (part.type == 'image') return _buildImageEmbed(part.content);
        if (part.type == 'youtube') return _buildYouTubeEmbed(part.content);
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
      if (_isImageUrl(trimmedLine) || _tenorGifPattern.hasMatch(trimmedLine)) {
        if (textBuffer.isNotEmpty) {
          parts.add(_ContentPart('text', textBuffer.toString().trimRight()));
          textBuffer.clear();
        }
        parts.add(_ContentPart('image', trimmedLine));
      } else if (_youtubePattern.hasMatch(trimmedLine)) {
        if (textBuffer.isNotEmpty) {
          parts.add(_ContentPart('text', textBuffer.toString().trimRight()));
          textBuffer.clear();
        }
        parts.add(_ContentPart('youtube', trimmedLine));
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

  /// Pre-process text to replace custom emoji and mention patterns before markdown
  String _preprocessContent(String text) {
    var processed = text;

    // Replace custom emoji :name: with inline image markdown (if emoji map provided)
    if (customEmojis != null && customEmojis!.isNotEmpty) {
      processed = processed.replaceAllMapped(_customEmojiPattern, (match) {
        final name = match.group(1)!;
        final url = customEmojis![name];
        if (url != null) {
          return '![emoji]($url)';
        }
        return match.group(0)!; // Leave as-is if not found
      });
    }

    // Highlight nostr:npub mentions — wrap in bold+color via markdown
    processed = processed.replaceAllMapped(_mentionPattern, (match) {
      final npub = match.group(0)!;
      final short = '${npub.substring(6, 14)}...';
      return '**@$short**';
    });

    return processed;
  }

  Widget _buildMarkdown(String text) {
    final processed = _preprocessContent(text);

    return MarkdownBody(
      data: processed,
      selectable: true,
      softLineBreak: true,
      builders: {
        'code': _CodeBlockBuilder(colors: colors),
      },
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(color: colors.gray200, fontSize: 15, height: 1.4),
        a: TextStyle(color: colors.accent, decoration: TextDecoration.underline),
        strong: TextStyle(color: colors.accent, fontWeight: FontWeight.bold),
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
    const maxW = 400.0;
    const maxH = 350.0;
    final cached = _imageSizeCache[url];

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.contain,
          memCacheWidth: 800,
          imageBuilder: (context, imageProvider) {
            // Resolve actual dimensions and cache them
            imageProvider.resolve(ImageConfiguration.empty).addListener(
              ImageStreamListener((info, _) {
                final w = info.image.width.toDouble();
                final h = info.image.height.toDouble();
                // Scale to fit within maxW x maxH
                final scale = (w / maxW).clamp(1.0, double.infinity);
                final scaledW = w / scale;
                final scaledH = h / scale;
                final finalH = scaledH.clamp(0.0, maxH);
                final finalW = finalH < scaledH ? scaledW * (finalH / scaledH) : scaledW;
                _imageSizeCache[url] = Size(finalW, finalH);
              }),
            );
            return ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: maxW, maxHeight: maxH),
              child: Image(image: imageProvider, fit: BoxFit.contain),
            );
          },
          // Use cached dimensions for placeholder, or default
          placeholder: (context, url) => Container(
            width: cached?.width ?? 300,
            height: cached?.height ?? 200,
            decoration: BoxDecoration(color: colors.gray700, borderRadius: BorderRadius.circular(8)),
            child: cached == null
                ? Center(child: CircularProgressIndicator(strokeWidth: 2, color: colors.gray500))
                : null, // if we know the size, just show the box (image loads fast from disk cache)
          ),
          errorWidget: (context, url, error) => Container(
            width: cached?.width ?? 300, height: 40,
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
    );
  }

  Widget _buildYouTubeEmbed(String url) {
    final match = _youtubePattern.firstMatch(url);
    final videoId = match?.group(1) ?? '';
    final thumbUrl = 'https://img.youtube.com/vi/$videoId/hqdefault.jpg';

    return GestureDetector(
      onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: const BoxConstraints(maxWidth: 400),
        decoration: BoxDecoration(
          color: colors.gray900,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.gray700),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Thumbnail with play button overlay
          ClipRRect(
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(7), topRight: Radius.circular(7)),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Image.network(thumbUrl, width: 400, height: 225, fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(width: 400, height: 225, color: colors.gray700)),
                Container(
                  width: 56, height: 40,
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.play_arrow, color: Colors.white, size: 28),
                ),
              ],
            ),
          ),
          // YouTube label
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              const Icon(Icons.play_circle_filled, size: 16, color: Colors.red),
              const SizedBox(width: 6),
              Expanded(child: Text('YouTube', style: TextStyle(color: colors.gray400, fontSize: 12))),
            ]),
          ),
        ]),
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

/// Custom code block builder with syntax highlighting via flutter_highlight
class _CodeBlockBuilder extends MarkdownElementBuilder {
  final InfernoColors colors;

  _CodeBlockBuilder({required this.colors});

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    // Only handle fenced code blocks (pre > code)
    if (element.tag != 'code') return null;
    final parent = element.attributes['class'];
    String language = '';
    if (parent != null && parent.startsWith('language-')) {
      language = parent.substring(9);
    }

    final code = element.textContent;

    // If no language specified or very short, use plain styled text
    if (language.isEmpty || code.length < 10) {
      return null; // Fall back to default rendering
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: HighlightView(
        code,
        language: language,
        theme: monokaiSublimeTheme,
        padding: const EdgeInsets.all(12),
        textStyle: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
      ),
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
    return MouseRegion(
      cursor: _revealed ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _revealed = !_revealed);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: _revealed ? Colors.transparent : widget.colors.gray900,
            borderRadius: BorderRadius.circular(4),
          ),
          clipBehavior: Clip.antiAlias,
          child: _revealed
              ? widget.child
              : IgnorePointer(
                  // Block all child gestures so tapping anywhere reveals
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 20, minWidth: 60),
                    child: Opacity(opacity: 0, child: widget.child),
                  ),
                ),
        ),
      ),
    );
  }
}
