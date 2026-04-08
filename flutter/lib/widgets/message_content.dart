import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:http/http.dart' as http;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' as mkv;
import '../theme/all_themes.dart';
import '../theme/theme_provider.dart';
import '../providers/database_provider.dart';
import '../providers/servers_provider.dart';
import '../services/gif_favorites_service.dart';
import '../services/invite_service.dart';
import '../providers/realtime_provider.dart';
import '../services/media_cache_service.dart';
import '../services/presence_service.dart';
import 'media_lightbox.dart';

/// Cache of unfurled og:image URLs: page url -> image url
final _ogImageCache = <String, String>{};

/// Cache of Blossom URL content-types: url -> content-type (e.g. 'image/jpeg', 'video/mp4')
final _blossomTypeCache = <String, String>{};

/// Cache of video dimensions: url -> (width, height). Survives widget rebuilds
/// so the container is pre-sized before metadata loads — prevents scroll jumps.
final _videoDimensionCache = <String, (int, int)>{};

/// Regex patterns
final _imageUrlPattern = RegExp(r'\.(png|jpg|jpeg|gif|webp|avif|svg)(\?.*)?$', caseSensitive: false);
final _blossomPattern = RegExp(r'https?://blossom\.\S+', caseSensitive: false);
final _videoUrlPattern = RegExp(r'\.(mp4|webm|mov|ogv)(\?.*)?$', caseSensitive: false);
final _audioUrlPattern = RegExp(r'\.(mp3|ogg|wav|m4a|webm)(\?.*)?$', caseSensitive: false);
const _emojiFallback = ['NotoColorEmoji'];
final _documentUrlPattern = RegExp(r'\.(pdf|txt)(\?.*)?$', caseSensitive: false);
final _urlPattern = RegExp(r'https?://\S+', caseSensitive: false);
final _singleEmojiPattern = RegExp(r'^[\p{Emoji_Presentation}\p{Emoji}\u200d\ufe0f]{1,7}$', unicode: true);
final _customEmojiPattern = RegExp(r':([a-zA-Z0-9_]+):');
final _mentionPattern = RegExp(r'nostr:npub[a-z0-9]{59}');
final _atMentionPattern = RegExp(r'(?<=^|\s)@(\w+)');
final _youtubePattern = RegExp(r'(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/shorts/)([a-zA-Z0-9_-]{11})', caseSensitive: false);
final _tenorMediaPattern = RegExp(r'https?://media\.tenor\.com/\S+', caseSensitive: false);
final _tenorGifPattern = RegExp(r'https?://media\.tenor\.com/\S+\.gif', caseSensitive: false);
final _tenorPagePattern = RegExp(r'https?://tenor\.com/view/\S+', caseSensitive: false);
final _njumpInvitePattern = RegExp(r'https?://njump\.me/naddr1[a-z0-9]+');
final _nostrInvitePattern = RegExp(r'nostr:naddr1[a-z0-9]+');
final _httpInvitePattern = RegExp(r'https?://[^/]+/inferno/invite/(?:(?:inferno-[a-zA-Z0-9-]+)/)?[a-zA-Z0-9]+');

/// Cached MarkdownStyleSheet per theme (keyed by accent color value).
/// Avoids recreating 20+ TextStyle/BoxDecoration objects per message on every rebuild.
MarkdownStyleSheet? _cachedStyleSheet;
int _cachedStyleSheetKey = 0;

MarkdownStyleSheet _getStyleSheet(InfernoColors colors) {
  final key = colors.accent.value;
  if (_cachedStyleSheet != null && _cachedStyleSheetKey == key) return _cachedStyleSheet!;
  _cachedStyleSheetKey = key;
  _cachedStyleSheet = MarkdownStyleSheet(
    p: TextStyle(color: colors.gray200, fontSize: 15, height: 1.4),
    a: TextStyle(color: colors.accent, decoration: TextDecoration.none),
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
  );
  return _cachedStyleSheet!;
}

/// Renders message content with full markdown support matching Rails Redcarpet output:
/// - Bold, italic, strikethrough, inline code, fenced code blocks with syntax highlighting
/// - Headers, lists, blockquotes, tables
/// - Inline images for image URLs (Blossom, etc.)
/// - Large emoji for emoji-only messages
/// - Custom emoji (:name:) rendered as inline images
/// - @mention highlighting (nostr:npub...)
/// - Autolinked URLs
class MessageContent extends ConsumerWidget {
  final String content;
  final InfernoColors colors;
  final bool isSpoiler;
  /// Custom emoji map: name -> imageUrl (from server_emojis table)
  final Map<String, String>? customEmojis;
  /// DM file URLs from structured JSON payload (separate from content)
  final String? fileUrls;
  /// Whether images should be blurred (NSFW detection or manual hide)
  final bool blurImages;

  const MessageContent({
    super.key,
    required this.content,
    required this.colors,
    this.isSpoiler = false,
    this.customEmojis,
    this.fileUrls,
    this.blurImages = false,
  });

  /// Parse fileUrls JSON string into list of URLs for DM file attachments
  List<String> _parseFileUrls() {
    if (fileUrls == null || fileUrls!.isEmpty) return [];
    try {
      final decoded = (jsonDecode(fileUrls!) as List).cast<String>();
      return decoded;
    } catch (_) {
      return [];
    }
  }

  /// Build widget for a single file URL based on its type
  Widget _buildFileUrlEmbed(BuildContext context, String url, MediaCacheService mediaCache) {
    // Per-attachment spoiler: "spoiler:https://..." prefix
    final isSpoilered = url.startsWith('spoiler:');
    final actualUrl = isSpoilered ? url.substring(8) : url;
    Widget embed;
    if (_isImageUrl(actualUrl)) {
      embed = _buildImageEmbed(context, actualUrl, mediaCache);
    } else if (_isBlossomHashUrl(actualUrl)) {
      embed = _BlossomEmbed(key: ValueKey('blossom_$actualUrl'), url: actualUrl, colors: colors);
    } else if (_isVideoUrl(actualUrl)) {
      embed = _buildVideoEmbed(context, actualUrl);
    } else if (_isAudioUrl(actualUrl)) {
      embed = _buildAudioEmbed(context, actualUrl);
    } else if (_isDocumentUrl(actualUrl)) {
      embed = _buildDocumentCard(context, actualUrl);
    } else {
      embed = _buildDocumentCard(context, actualUrl);
    }
    if (isSpoilered) embed = _NsfwBlurWrap(colors: colors, label: 'SPOILER', child: embed);
    return embed;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaCache = ref.read(mediaCacheServiceProvider);
    final parsedFileUrls = _parseFileUrls();
    final hasContent = content.isNotEmpty;
    final hasFiles = parsedFileUrls.isNotEmpty;

    if (!hasContent && !hasFiles) return const SizedBox.shrink();

    final trimmed = content.trim();

    // Build content widget
    Widget? contentWidget;
    if (hasContent) {
      // Check if content is emoji-only (unicode or custom) — render large like Discord
      if (_isEmojiOnly(trimmed)) {
        contentWidget = _buildLargeEmojis(trimmed);
      }
      // Check if content is a single image/GIF URL (with optional spoiler: prefix)
      else if (!trimmed.contains('\n') && !trimmed.contains(' ')) {
        final hasSpoiler = trimmed.startsWith('spoiler:');
        final singleUrl = hasSpoiler ? trimmed.substring(8) : trimmed;
        if (_isImageUrl(singleUrl) || _tenorMediaPattern.hasMatch(singleUrl)) {
          contentWidget = _buildImageEmbed(context, singleUrl, mediaCache);
          // _buildImageEmbed already handles blurImages, but spoiler prefix needs explicit wrap
          if (hasSpoiler) contentWidget = _NsfwBlurWrap(colors: colors, label: 'SPOILER', child: contentWidget!);
        } else if (_isBlossomHashUrl(singleUrl)) {
          contentWidget = _BlossomEmbed(key: ValueKey('blossom_$singleUrl'), url: singleUrl, colors: colors);
          if (hasSpoiler || blurImages) contentWidget = _NsfwBlurWrap(colors: colors, label: hasSpoiler ? 'SPOILER' : 'NSFW', child: contentWidget!);
        } else if (_tenorPagePattern.hasMatch(singleUrl)) {
          contentWidget = _TenorUnfurl(url: singleUrl, colors: colors);
        } else if (_isInviteUrl(singleUrl)) {
          contentWidget = InviteEmbed(uri: singleUrl, colors: colors);
        }
      }

      if (contentWidget == null) {
        // Split content: extract media URLs on their own lines, render rest as markdown
        final parts = _splitContent(trimmed);
        if (parts.length == 1 && parts[0].type == 'text') {
          contentWidget = _buildMarkdown(parts[0].content);
        } else {
          // Mixed content — markdown blocks + inline images + embeds
          contentWidget = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: parts.map((part) {
              if (part.type == 'image') return _buildImageEmbed(context, part.content, mediaCache);
              if (part.type == 'spoiler_image') return _NsfwBlurWrap(colors: colors, label: 'SPOILER', child: _buildImageEmbed(context, part.content, mediaCache));
              if (part.type == 'blossom') {
                Widget w = _BlossomEmbed(key: ValueKey('blossom_${part.content}'), url: part.content, colors: colors);
                if (blurImages) w = _NsfwBlurWrap(colors: colors, child: w);
                return w;
              }
              if (part.type == 'spoiler_blossom') return _NsfwBlurWrap(colors: colors, label: 'SPOILER', child: _BlossomEmbed(key: ValueKey('blossom_${part.content}'), url: part.content, colors: colors));
              if (part.type == 'tenor') return _TenorUnfurl(url: part.content, colors: colors);
              if (part.type == 'youtube') return _buildYouTubeEmbed(part.content);
              if (part.type == 'video') return _buildVideoEmbed(context, part.content);
              if (part.type == 'spoiler_video') return _NsfwBlurWrap(colors: colors, label: 'SPOILER', child: _buildVideoEmbed(context, part.content));
              if (part.type == 'audio') return _buildAudioEmbed(context, part.content);
              if (part.type == 'document') return _buildDocumentCard(context, part.content);
              if (part.type == 'invite') return InviteEmbed(uri: part.content, colors: colors);
              return _buildMarkdown(part.content);
            }).toList(),
          );
        }
      }
    }

    // Build file URLs widgets (from DM structured payload)
    List<Widget>? fileWidgets;
    if (hasFiles) {
      fileWidgets = parsedFileUrls.map((url) => _buildFileUrlEmbed(context, url, mediaCache)).toList();
    }

    // Combine content + file attachments
    if (contentWidget != null && fileWidgets != null) {
      return _maybeSpoiler(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [contentWidget, ...fileWidgets],
      ));
    }
    if (contentWidget != null) return _maybeSpoiler(contentWidget);
    if (fileWidgets != null) {
      return _maybeSpoiler(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: fileWidgets,
      ));
    }
    return const SizedBox.shrink();
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
      // Per-attachment spoiler prefix
      final hasSpoilerPrefix = trimmedLine.startsWith('spoiler:');
      final checkLine = hasSpoilerPrefix ? trimmedLine.substring(8) : trimmedLine;
      if (_isImageUrl(checkLine) || _tenorGifPattern.hasMatch(checkLine) || _tenorMediaPattern.hasMatch(checkLine)) {
        if (textBuffer.isNotEmpty) {
          parts.add(_ContentPart('text', textBuffer.toString().trimRight()));
          textBuffer.clear();
        }
        parts.add(_ContentPart(hasSpoilerPrefix ? 'spoiler_image' : 'image', checkLine));
      } else if (_tenorPagePattern.hasMatch(checkLine)) {
        if (textBuffer.isNotEmpty) {
          parts.add(_ContentPart('text', textBuffer.toString().trimRight()));
          textBuffer.clear();
        }
        parts.add(_ContentPart('tenor', checkLine));
      } else if (_youtubePattern.hasMatch(checkLine)) {
        if (textBuffer.isNotEmpty) {
          parts.add(_ContentPart('text', textBuffer.toString().trimRight()));
          textBuffer.clear();
        }
        parts.add(_ContentPart('youtube', checkLine));
      } else if (_isInviteUrl(checkLine)) {
        if (textBuffer.isNotEmpty) {
          parts.add(_ContentPart('text', textBuffer.toString().trimRight()));
          textBuffer.clear();
        }
        parts.add(_ContentPart('invite', checkLine));
      } else if (_isVideoUrl(checkLine)) {
        if (textBuffer.isNotEmpty) {
          parts.add(_ContentPart('text', textBuffer.toString().trimRight()));
          textBuffer.clear();
        }
        parts.add(_ContentPart(hasSpoilerPrefix ? 'spoiler_video' : 'video', checkLine));
      } else if (_isAudioUrl(checkLine)) {
        if (textBuffer.isNotEmpty) {
          parts.add(_ContentPart('text', textBuffer.toString().trimRight()));
          textBuffer.clear();
        }
        parts.add(_ContentPart('audio', checkLine));
      } else if (_isDocumentUrl(checkLine)) {
        if (textBuffer.isNotEmpty) {
          parts.add(_ContentPart('text', textBuffer.toString().trimRight()));
          textBuffer.clear();
        }
        parts.add(_ContentPart('document', checkLine));
      } else if (_isBlossomHashUrl(checkLine)) {
        if (textBuffer.isNotEmpty) {
          parts.add(_ContentPart('text', textBuffer.toString().trimRight()));
          textBuffer.clear();
        }
        parts.add(_ContentPart(hasSpoilerPrefix ? 'spoiler_blossom' : 'blossom', checkLine));
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
    return _imageUrlPattern.hasMatch(text);
  }

  /// Blossom hash URL with no file extension — could be image, video, audio, etc.
  bool _isBlossomHashUrl(String text) {
    if (!_blossomPattern.hasMatch(text)) return false;
    // If it already has a known media extension, it's not a bare hash URL
    return !_imageUrlPattern.hasMatch(text) &&
           !_videoUrlPattern.hasMatch(text) &&
           !_audioUrlPattern.hasMatch(text) &&
           !_documentUrlPattern.hasMatch(text);
  }

  bool _isVideoUrl(String text) {
    return _urlPattern.hasMatch(text) && _videoUrlPattern.hasMatch(text);
  }

  bool _isAudioUrl(String text) {
    return _urlPattern.hasMatch(text) && _audioUrlPattern.hasMatch(text);
  }

  bool _isDocumentUrl(String text) {
    return _urlPattern.hasMatch(text) && _documentUrlPattern.hasMatch(text);
  }

  bool _isInviteUrl(String text) {
    return _njumpInvitePattern.hasMatch(text) ||
           _nostrInvitePattern.hasMatch(text) ||
           _httpInvitePattern.hasMatch(text);
  }

  /// Check if message contains ONLY emojis (unicode and/or custom :name:), max ~27
  bool _isEmojiOnly(String text) {
    // Strip custom emoji tokens and whitespace, check if remainder is only unicode emoji
    var stripped = text.replaceAll(_customEmojiPattern, '').replaceAll(' ', '');
    // If there were custom emojis and stripping leaves only unicode emoji or empty
    final hasCustom = _customEmojiPattern.hasMatch(text);
    final isUnicodeOnly = stripped.isEmpty || _singleEmojiPattern.hasMatch(stripped);
    if (!hasCustom && !isUnicodeOnly) return false;
    if (hasCustom && !isUnicodeOnly) return false;
    // Count total emoji (custom + unicode) — Discord caps jumbo at ~27
    final customCount = _customEmojiPattern.allMatches(text).length;
    final unicodeCount = stripped.runes.length;
    return (customCount + unicodeCount) > 0 && (customCount + unicodeCount) <= 27;
  }

  /// Build large emoji display (48px) — matches Discord jumbo emoji
  Widget _buildLargeEmojis(String text) {
    final children = <InlineSpan>[];
    int lastEnd = 0;
    const emojiSize = 48.0;

    for (final match in _customEmojiPattern.allMatches(text)) {
      // Add any unicode emoji text before this custom emoji
      if (match.start > lastEnd) {
        final before = text.substring(lastEnd, match.start).trim();
        if (before.isNotEmpty) {
          children.add(TextSpan(text: before, style: const TextStyle(fontSize: emojiSize, fontFamilyFallback: _emojiFallback)));
        }
      }

      final name = match.group(1)!;
      final url = customEmojis?[name];
      if (url != null) {
        children.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: CachedNetworkImage(
              imageUrl: url,
              width: emojiSize, height: emojiSize,
              fit: BoxFit.contain,
            ),
          ),
        ));
      } else {
        children.add(TextSpan(text: match.group(0)!, style: const TextStyle(fontSize: emojiSize, fontFamilyFallback: _emojiFallback)));
      }
      lastEnd = match.end;
    }

    // Remaining unicode emoji
    if (lastEnd < text.length) {
      final remaining = text.substring(lastEnd).trim();
      if (remaining.isNotEmpty) {
        children.add(TextSpan(text: remaining, style: const TextStyle(fontSize: emojiSize, fontFamilyFallback: _emojiFallback)));
      }
    }

    return Text.rich(TextSpan(children: children));
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

    // Highlight @username mentions (including @everyone, @here)
    processed = processed.replaceAllMapped(_atMentionPattern, (match) {
      final username = match.group(1)!;
      return '**@$username**';
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
      styleSheet: _getStyleSheet(colors),
      sizedImageBuilder: (config) {
        // Custom emoji: render inline at 1.375em (~22px)
        if (config.alt == 'emoji') {
          return CachedNetworkImage(
            imageUrl: config.uri.toString(),
            height: 22,
            width: 22,
            fit: BoxFit.contain,
            placeholder: (_, __) => const SizedBox(width: 22, height: 22),
            errorWidget: (_, __, ___) => Text(':?:', style: TextStyle(color: colors.gray500, fontSize: 14)),
          );
        }
        // Regular images — render full-size
        return CachedNetworkImage(
          imageUrl: config.uri.toString(),
          fit: BoxFit.contain,
          placeholder: (_, __) => const SizedBox(width: 100, height: 100),
          errorWidget: (_, __, ___) => Icon(Icons.broken_image, color: colors.gray500),
        );
      },
      onTapLink: (text, href, title) {
        if (href != null) {
          launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
        }
      },
    );
  }

  bool _isGifUrl(String url) {
    return _tenorMediaPattern.hasMatch(url) || _tenorGifPattern.hasMatch(url) ||
        url.toLowerCase().endsWith('.gif');
  }

  Widget _buildImageEmbed(BuildContext context, String url, MediaCacheService mediaCache) {
    const maxW = 400.0;
    const maxH = 350.0;
    final cached = mediaCache.get(url);
    final isGif = _isGifUrl(url);

    Widget image = Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: cached != null
            // Known dimensions — use SizedBox to lock layout before image loads
            ? SizedBox(
                width: cached.width,
                height: cached.height,
                child: CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.contain,
                  memCacheWidth: 800,
                  placeholder: (context, url) => Container(
                    decoration: BoxDecoration(color: colors.gray700, borderRadius: BorderRadius.circular(8)),
                  ),
                  errorWidget: (context, url, error) => Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: colors.gray700, borderRadius: BorderRadius.circular(4)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.broken_image, size: 16, color: colors.gray500),
                      const SizedBox(width: 4),
                      Flexible(child: Text(url, style: TextStyle(color: colors.gray500, fontSize: 12), overflow: TextOverflow.ellipsis)),
                    ]),
                  ),
                ),
              )
            // Unknown dimensions — resolve on load, cache for next time
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.contain,
                memCacheWidth: 800,
                imageBuilder: (context, imageProvider) {
                  imageProvider.resolve(ImageConfiguration.empty).addListener(
                    ImageStreamListener((info, _) {
                      final w = info.image.width.toDouble();
                      final h = info.image.height.toDouble();
                      final scale = (w / maxW).clamp(1.0, double.infinity);
                      final scaledW = w / scale;
                      final scaledH = h / scale;
                      final finalH = scaledH.clamp(0.0, maxH);
                      final finalW = finalH < scaledH ? scaledW * (finalH / scaledH) : scaledW;
                      mediaCache.put(url, finalW, finalH);
                    }),
                  );
                  return ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: maxW, maxHeight: maxH),
                    child: Image(image: imageProvider, fit: BoxFit.contain),
                  );
                },
                placeholder: (context, url) => Container(
                  width: 300, height: 200,
                  decoration: BoxDecoration(color: colors.gray700, borderRadius: BorderRadius.circular(8)),
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: colors.gray500)),
                ),
                errorWidget: (context, url, error) => Container(
                  width: 300, height: 40,
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

    if (isGif) {
      image = GifSaveOverlay(gifUrl: url, child: image);
    }

    // Wrap with click-to-lightbox and right-click context menu
    Widget result = GestureDetector(
      onTap: () => MediaLightbox.show(context, url: url, filename: url.split('/').last.split('?').first),
      onSecondaryTapUp: (details) => showMediaContextMenu(
        context,
        position: details.globalPosition,
        url: url,
      ),
      child: MouseRegion(cursor: SystemMouseCursors.click, child: image),
    );

    if (blurImages) {
      result = _NsfwBlurWrap(colors: colors, child: result);
    }

    return result;
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

  Widget _buildVideoEmbed(BuildContext context, String url) {
    final fname = url.split('/').last.split('?').first;
    return GestureDetector(
      onSecondaryTapUp: (details) => showMediaContextMenu(
        context, position: details.globalPosition, url: url, filename: fname, isVideo: true,
      ),
      child: _InlineVideoPlayer(key: ValueKey('video_$url'), url: url, colors: colors),
    );
  }

  Widget _buildAudioEmbed(BuildContext context, String url) {
    final fname = url.split('/').last.split('?').first;
    return GestureDetector(
      onSecondaryTapUp: (details) => showMediaContextMenu(
        context, position: details.globalPosition, url: url, filename: fname,
      ),
      child: _InlineAudioPlayer(url: url, filename: fname, colors: colors),
    );
  }

  Widget _buildDocumentCard(BuildContext context, String url) {
    final fname = url.split('/').last.split('?').first;
    final ext = fname.split('.').last.toLowerCase();
    final icon = ext == 'pdf' ? Icons.picture_as_pdf : Icons.description;
    return GestureDetector(
      onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      onSecondaryTapUp: (details) => showMediaContextMenu(
        context, position: details.globalPosition, url: url, filename: fname,
      ),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 350),
        decoration: BoxDecoration(
          color: colors.gray900,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.gray700),
        ),
        child: Row(children: [
          Icon(icon, size: 32, color: colors.accent),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(fname, style: TextStyle(color: colors.gray200, fontSize: 13, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(ext.toUpperCase(), style: TextStyle(color: colors.gray500, fontSize: 11)),
            ],
          )),
          Icon(Icons.download, size: 20, color: colors.gray400),
        ]),
      ),
    );
  }
}

/// Smart embed for Blossom hash URLs (no extension).
/// Does a HEAD request to detect content-type, then renders image, video, audio, or document.
class _BlossomEmbed extends StatefulWidget {
  final String url;
  final InfernoColors colors;
  const _BlossomEmbed({required this.url, required this.colors, super.key});

  @override
  State<_BlossomEmbed> createState() => _BlossomEmbedState();
}

class _BlossomEmbedState extends State<_BlossomEmbed> {
  String? _type; // 'image', 'video', 'audio', 'document'
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _detectType();
  }

  Future<void> _detectType() async {
    // Check cache first
    final cached = _blossomTypeCache[widget.url];
    if (cached != null) {
      if (mounted) setState(() { _type = _classifyContentType(cached); _loading = false; });
      return;
    }

    try {
      final response = await http.head(Uri.parse(widget.url)).timeout(const Duration(seconds: 8));
      final contentType = response.headers['content-type'] ?? '';
      _blossomTypeCache[widget.url] = contentType;
      if (mounted) setState(() { _type = _classifyContentType(contentType); _loading = false; });
    } catch (_) {
      // Default to image on failure
      if (mounted) setState(() { _type = 'image'; _loading = false; });
    }
  }

  String _classifyContentType(String ct) {
    final lower = ct.toLowerCase();
    if (lower.startsWith('image/')) return 'image';
    if (lower.startsWith('video/')) return 'video';
    if (lower.startsWith('audio/')) return 'audio';
    if (lower.contains('pdf') || lower.startsWith('text/')) return 'document';
    // Default: try as image (most common for Blossom)
    return 'image';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Container(
          width: 300, height: 200,
          decoration: BoxDecoration(color: widget.colors.gray700, borderRadius: BorderRadius.circular(8)),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: widget.colors.gray500)),
        ),
      );
    }

    switch (_type) {
      case 'video':
        return GestureDetector(
          onSecondaryTapUp: (details) => showMediaContextMenu(
            context, position: details.globalPosition, url: widget.url, isVideo: true,
          ),
          child: _InlineVideoPlayer(key: ValueKey('video_${widget.url}'), url: widget.url, colors: widget.colors),
        );
      case 'audio':
        final fname = widget.url.split('/').last.split('?').first;
        return _InlineAudioPlayer(url: widget.url, filename: fname, colors: widget.colors);
      case 'document':
        return _BlossomDocumentCard(url: widget.url, colors: widget.colors);
      default: // 'image'
        return _BlossomImageEmbed(url: widget.url, colors: widget.colors);
    }
  }
}

/// Image embed for Blossom hash URLs — wraps with lightbox + context menu.
class _BlossomImageEmbed extends ConsumerWidget {
  final String url;
  final InfernoColors colors;
  const _BlossomImageEmbed({required this.url, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaCache = ref.read(mediaCacheServiceProvider);
    const maxW = 400.0;
    const maxH = 350.0;
    final cached = mediaCache.get(url);

    final image = Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: cached != null
            ? SizedBox(
                width: cached.width,
                height: cached.height,
                child: CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.contain,
                  memCacheWidth: 800,
                  placeholder: (_, _) => Container(
                    decoration: BoxDecoration(color: colors.gray700, borderRadius: BorderRadius.circular(8)),
                  ),
                  errorWidget: (_, _, _) => _brokenImage(colors, url),
                ),
              )
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.contain,
                memCacheWidth: 800,
                imageBuilder: (_, imageProvider) {
                  imageProvider.resolve(ImageConfiguration.empty).addListener(
                    ImageStreamListener((info, _) {
                      final w = info.image.width.toDouble();
                      final h = info.image.height.toDouble();
                      final scale = (w / maxW).clamp(1.0, double.infinity);
                      final scaledW = w / scale;
                      final scaledH = h / scale;
                      final finalH = scaledH.clamp(0.0, maxH);
                      final finalW = finalH < scaledH ? scaledW * (finalH / scaledH) : scaledW;
                      mediaCache.put(url, finalW, finalH);
                    }),
                  );
                  return ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: maxW, maxHeight: maxH),
                    child: Image(image: imageProvider, fit: BoxFit.contain),
                  );
                },
                placeholder: (_, _) => Container(
                  width: 300, height: 200,
                  decoration: BoxDecoration(color: colors.gray700, borderRadius: BorderRadius.circular(8)),
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: colors.gray500)),
                ),
                errorWidget: (_, _, _) => _brokenImage(colors, url),
              ),
      ),
    );

    return GestureDetector(
      onTap: () => MediaLightbox.show(context, url: url, filename: url.split('/').last),
      onSecondaryTapUp: (details) => showMediaContextMenu(context, position: details.globalPosition, url: url),
      child: MouseRegion(cursor: SystemMouseCursors.click, child: image),
    );
  }

  static Widget _brokenImage(InfernoColors colors, String url) {
    return Container(
      width: 300, height: 40,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: colors.gray700, borderRadius: BorderRadius.circular(4)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.broken_image, size: 16, color: colors.gray500),
        const SizedBox(width: 4),
        Flexible(child: Text(url, style: TextStyle(color: colors.gray500, fontSize: 12), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}

/// Document card for Blossom hash URLs.
class _BlossomDocumentCard extends StatelessWidget {
  final String url;
  final InfernoColors colors;
  const _BlossomDocumentCard({required this.url, required this.colors});

  @override
  Widget build(BuildContext context) {
    final fname = url.split('/').last.split('?').first;
    return GestureDetector(
      onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      onSecondaryTapUp: (details) => showMediaContextMenu(context, position: details.globalPosition, url: url, filename: fname),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 350),
        decoration: BoxDecoration(
          color: colors.gray900,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.gray700),
        ),
        child: Row(children: [
          Icon(Icons.insert_drive_file, size: 32, color: colors.accent),
          const SizedBox(width: 12),
          Expanded(child: Text(fname, style: TextStyle(color: colors.gray200, fontSize: 13, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
          Icon(Icons.download, size: 20, color: colors.gray400),
        ]),
      ),
    );
  }
}

/// Inline video player using media_kit (max 512×384).
/// Global registry of active video players — disposed on hot restart to prevent
/// native libmpv callbacks into a dead Dart isolate.
final _activeVideoPlayers = <_InlineVideoPlayerState>{};

class _InlineVideoPlayer extends StatefulWidget {
  final String url;
  final InfernoColors colors;
  const _InlineVideoPlayer({required this.url, required this.colors, super.key});

  @override
  State<_InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends State<_InlineVideoPlayer> with WidgetsBindingObserver {
  Player? _player;
  mkv.VideoController? _controller;
  bool _initialized = false;
  bool _disposed = false;
  int? _videoWidth;
  int? _videoHeight;

  /// Seed dimensions from cache so container is pre-sized before metadata loads
  void _seedFromCache() {
    final cached = _videoDimensionCache[widget.url];
    if (cached != null) {
      _videoWidth = cached.$1;
      _videoHeight = cached.$2;
    }
  }

  // Playback state
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  double _volume = 1.0;
  bool _hovering = false;
  bool _controlsVisible = false;
  bool _seeking = false;
  bool _showVolumePopup = false;
  bool _draggingVolume = false;
  Timer? _hideTimer;

  // Subscriptions
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    _seedFromCache();
    WidgetsBinding.instance.addObserver(this);
    _activeVideoPlayers.add(this);
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    if (_disposed) return;
    final player = Player();
    final controller = mkv.VideoController(
      player,
      configuration: const mkv.VideoControllerConfiguration(
        vo: 'libmpv',
        hwdec: 'no',
        enableHardwareAcceleration: false,
      ),
    );

    if (_disposed) { player.dispose(); return; }

    _player = player;
    _controller = controller;

    _subs.add(player.stream.width.listen((w) {
      if (w != null && mounted && !_disposed) {
        setState(() => _videoWidth = w);
        if (_videoHeight != null) _videoDimensionCache[widget.url] = (w, _videoHeight!);
      }
    }));
    _subs.add(player.stream.height.listen((h) {
      if (h != null && mounted && !_disposed) {
        setState(() => _videoHeight = h);
        if (_videoWidth != null) _videoDimensionCache[widget.url] = (_videoWidth!, h);
      }
    }));
    _subs.add(player.stream.playing.listen((playing) {
      if (!mounted || _disposed) return;
      setState(() => _playing = playing);
      if (playing) {
        _startHideTimer();
      } else {
        _hideTimer?.cancel();
        if (mounted) setState(() => _controlsVisible = true);
      }
    }));
    _subs.add(player.stream.position.listen((pos) {
      if (!_seeking && mounted && !_disposed) setState(() => _position = pos);
    }));
    _subs.add(player.stream.duration.listen((dur) {
      if (mounted && !_disposed) setState(() => _duration = dur);
    }));
    _subs.add(player.stream.buffer.listen((buf) {
      if (mounted && !_disposed) setState(() => _buffer = buf);
    }));
    _subs.add(player.stream.volume.listen((vol) {
      if (mounted && !_disposed) setState(() => _volume = vol / 100.0);
    }));

    if (_disposed) { _teardown(); return; }

    // Open paused — user clicks play to start
    await player.open(Media(widget.url), play: false);
    if (mounted && !_disposed) setState(() => _initialized = true);
  }

  void _teardown() {
    _hideTimer?.cancel();
    for (final sub in _subs) { sub.cancel(); }
    _subs.clear();
    // Cancel subs first so native callbacks hit no-ops, then dispose
    _player?.dispose();
    _player = null;
    _controller = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _activeVideoPlayers.remove(this);
    WidgetsBinding.instance.removeObserver(this);
    _teardown();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause on detach (covers hot restart on some platforms)
    if (state == AppLifecycleState.detached) {
      _teardown();
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _playing && !_draggingVolume && !_seeking) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _togglePlay() {
    _player?.playOrPause();
  }

  void _openFullscreen() {
    final player = _player;
    final controller = _controller;
    if (player == null || controller == null) return;
    Navigator.of(context, rootNavigator: true).push(PageRouteBuilder(
      opaque: true,
      pageBuilder: (_, __, ___) => _VideoFullscreen(
        player: player,
        controller: controller,
        url: widget.url,
        colors: widget.colors,
      ),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
      transitionDuration: const Duration(milliseconds: 150),
    ));
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m}:${s.toString().padLeft(2, '0')}';
  }

  double get _aspectRatio {
    if (_videoWidth != null && _videoHeight != null && _videoHeight! > 0) {
      return _videoWidth! / _videoHeight!;
    }
    return 16 / 9; // default before metadata loads
  }

  bool get _isVertical => _aspectRatio < 1.0;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final accent = c.accent;

    // Match image/GIF embed max bounds (400x350)
    const double maxW = 400;
    const double maxH = 350;
    double displayW, displayH;
    if (_aspectRatio >= maxW / maxH) {
      // Wider than bounding box — constrain by width
      displayW = maxW;
      displayH = maxW / _aspectRatio;
    } else {
      // Taller than bounding box — constrain by height
      displayH = maxH;
      displayW = maxH * _aspectRatio;
    }

    return MouseRegion(
      cursor: _controlsVisible ? SystemMouseCursors.basic : SystemMouseCursors.none,
      onEnter: (_) { setState(() { _hovering = true; _controlsVisible = true; }); _startHideTimer(); },
      onExit: (_) {
        if (!_draggingVolume) setState(() { _hovering = false; _showVolumePopup = false; });
        if (_playing) _startHideTimer();
      },
      onHover: (_) { if (!_controlsVisible) setState(() => _controlsVisible = true); _startHideTimer(); },
      child: GestureDetector(
        onTap: _togglePlay,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          width: displayW,
          height: displayH,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.gray700),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Video surface — no controls from media_kit
                if (_controller != null)
                  mkv.Video(
                    controller: _controller!,
                    controls: mkv.NoVideoControls,
                    fit: BoxFit.cover,
                  )
                else
                  Container(color: Colors.black),

                // Big play button (centered) — shown when paused
                if (!_playing)
                  Center(child: _VideoBigPlayButton(size: 56, iconSize: 36)),

                // Controls bar — bottom gradient overlay
                Positioned(
                  bottom: 0, left: 0, right: 0,
                  child: AnimatedOpacity(
                    opacity: _controlsVisible ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 250),
                    child: _buildControls(c, accent, displayW),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControls(InfernoColors c, Color accent, double playerWidth) {
    final progressFraction = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final bufferFraction = _duration.inMilliseconds > 0
        ? (_buffer.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    // For narrow/vertical videos, use a compact layout
    final isCompact = playerWidth < 320;

    return GestureDetector(
      onTap: () {}, // absorb taps so clicking controls doesn't toggle play
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xCC000000), Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Seek bar — full width, always on top of controls
            _buildSeekBar(accent, bufferFraction, progressFraction),
            // Controls row
            Padding(
              padding: EdgeInsets.fromLTRB(isCompact ? 4 : 8, 0, isCompact ? 4 : 8, isCompact ? 4 : 6),
              child: Row(
                children: [
                  // Play/pause button
                  _controlButton(
                    icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    onTap: _togglePlay,
                  ),
                  const SizedBox(width: 4),
                  // Time display
                  if (!isCompact)
                    Text(
                      '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                      style: TextStyle(color: c.gray400, fontSize: 12, fontFamily: 'monospace'),
                    ),
                  if (isCompact)
                    Text(
                      _formatDuration(_position),
                      style: TextStyle(color: c.gray400, fontSize: 11, fontFamily: 'monospace'),
                    ),
                  const Spacer(),
                  // Volume control
                  _buildVolumeControl(c, accent, isCompact),
                  const SizedBox(width: 2),
                  // Fullscreen button
                  _controlButton(
                    icon: Icons.fullscreen_rounded,
                    onTap: _openFullscreen,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeekBar(Color accent, double bufferFraction, double progressFraction) {
    return _VideoSeekBar(
      accent: accent,
      bufferFraction: bufferFraction,
      progressFraction: progressFraction,
      duration: _duration,
      onSeekStart: () => _seeking = true,
      onSeekUpdate: (frac) => setState(() => _position = Duration(milliseconds: (_duration.inMilliseconds * frac).round())),
      onSeekEnd: (frac) { _seeking = false; _player?.seek(Duration(milliseconds: (_duration.inMilliseconds * frac).round())); },
    );
  }

  Widget _buildVolumeControl(InfernoColors c, Color accent, bool isCompact) {
    final volumeIcon = _volume <= 0
        ? Icons.volume_off_rounded
        : _volume < 0.5
            ? Icons.volume_down_rounded
            : Icons.volume_up_rounded;

    if (_isVertical || isCompact) {
      // Vertical/compact: volume button with popup slider
      return Stack(
        clipBehavior: Clip.none,
        children: [
          _controlButton(
            icon: volumeIcon,
            onTap: () => setState(() => _showVolumePopup = !_showVolumePopup),
          ),
          if (_showVolumePopup)
            Positioned(
              bottom: 40,
              left: -4,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xDD000000),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: SizedBox(
                      width: 80,
                      child: SliderTheme(
                        data: _volumeSliderTheme(accent),
                        child: Slider(
                          value: _volume,
                          onChangeStart: (_) => _draggingVolume = true,
                          onChanged: (v) => _player?.setVolume(v * 100),
                          onChangeEnd: (_) { _draggingVolume = false; _startHideTimer(); },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }

    // Landscape: inline horizontal volume slider
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _controlButton(
          icon: volumeIcon,
          onTap: () {
            // Toggle mute
            if (_volume > 0) {
              _player?.setVolume(0);
            } else {
              _player?.setVolume(100);
            }
          },
        ),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: SizedBox(
            width: 60,
            child: SliderTheme(
              data: _volumeSliderTheme(accent),
              child: Slider(
                value: _volume,
                onChangeStart: (_) => _draggingVolume = true,
                onChanged: (v) => _player?.setVolume(v * 100),
                onChangeEnd: (_) { _draggingVolume = false; _startHideTimer(); },
              ),
            ),
          ),
        ),
      ],
    );
  }

  SliderThemeData _volumeSliderTheme(Color accent) {
    return SliderThemeData(
      trackHeight: 4,
      activeTrackColor: accent,
      inactiveTrackColor: Colors.white.withValues(alpha: 0.2),
      thumbColor: Colors.white,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
      overlayColor: accent.withValues(alpha: 0.2),
    );
  }

  Widget _controlButton({required IconData icon, required VoidCallback onTap}) {
    return _VideoControlButton(icon: icon, onTap: onTap, size: 20);
  }
}

/// Video control button with hover highlight — used by both inline and fullscreen players.
class _VideoControlButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;
  const _VideoControlButton({required this.icon, required this.onTap, this.size = 20});

  @override
  State<_VideoControlButton> createState() => _VideoControlButtonState();
}

class _VideoControlButtonState extends State<_VideoControlButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            widget.icon,
            color: _hovered ? Colors.white : const Color(0xFFE5E7EB),
            size: widget.size,
          ),
        ),
      ),
    );
  }
}

/// Big centered play button with hover brightening.
class _VideoBigPlayButton extends StatefulWidget {
  final double size;
  final double iconSize;
  const _VideoBigPlayButton({required this.size, required this.iconSize});

  @override
  State<_VideoBigPlayButton> createState() => _VideoBigPlayButtonState();
}

class _VideoBigPlayButtonState extends State<_VideoBigPlayButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: _hovered ? Colors.black87 : Colors.black54,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.play_arrow_rounded,
          color: _hovered ? Colors.white : Colors.white70,
          size: widget.iconSize,
        ),
      ),
    );
  }
}

/// Seek bar with hover thickening — matches Rails .vp-seek-wrap:hover { height: 6px }
class _VideoSeekBar extends StatefulWidget {
  final Color accent;
  final double bufferFraction;
  final double progressFraction;
  final Duration duration;
  final VoidCallback onSeekStart;
  final void Function(double fraction) onSeekUpdate;
  final void Function(double fraction) onSeekEnd;
  final EdgeInsets padding;

  const _VideoSeekBar({
    required this.accent,
    required this.bufferFraction,
    required this.progressFraction,
    required this.duration,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekEnd,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
  });

  @override
  State<_VideoSeekBar> createState() => _VideoSeekBarState();
}

class _VideoSeekBarState extends State<_VideoSeekBar> {
  bool _hovered = false;
  final _barKey = GlobalKey();

  double _fractionFromLocal(Offset local) {
    final box = _barKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return 0;
    return (local.dx / box.size.width).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final trackHeight = _hovered ? 6.0 : 4.0;

    return GestureDetector(
      onHorizontalDragStart: (d) { widget.onSeekStart(); },
      onHorizontalDragUpdate: (d) {
        if (widget.duration.inMilliseconds == 0) return;
        widget.onSeekUpdate(_fractionFromLocal(d.localPosition));
      },
      onHorizontalDragEnd: (d) {
        // Use last known position via progressFraction
        widget.onSeekEnd(widget.progressFraction);
      },
      onTapUp: (d) {
        if (widget.duration.inMilliseconds == 0) return;
        final frac = _fractionFromLocal(d.localPosition);
        widget.onSeekEnd(frac);
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Container(
          key: _barKey,
          height: 16,
          padding: widget.padding,
          alignment: Alignment.center,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            height: trackHeight,
            child: Stack(
              children: [
                Container(decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(3))),
                FractionallySizedBox(
                  widthFactor: widget.bufferFraction,
                  child: Container(decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(3))),
                ),
                FractionallySizedBox(
                  widthFactor: widget.progressFraction,
                  child: Container(decoration: BoxDecoration(color: widget.accent, borderRadius: BorderRadius.circular(3))),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Fullscreen video overlay — reuses the existing Player instance from the inline player.
class _VideoFullscreen extends StatefulWidget {
  final Player player;
  final mkv.VideoController controller;
  final String url;
  final InfernoColors colors;
  const _VideoFullscreen({required this.player, required this.controller, required this.url, required this.colors});

  @override
  State<_VideoFullscreen> createState() => _VideoFullscreenState();
}

class _VideoFullscreenState extends State<_VideoFullscreen> {
  bool _controlsVisible = true;
  bool _playing = false;
  bool _seeking = false;
  bool _draggingVolume = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  double _volume = 1.0;
  Timer? _hideTimer;
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    final p = widget.player;
    // Seed current state
    _playing = p.state.playing;
    _position = p.state.position;
    _duration = p.state.duration;
    _buffer = p.state.buffer;
    _volume = p.state.volume / 100.0;

    _subs.add(p.stream.playing.listen((v) { if (mounted) setState(() => _playing = v); }));
    _subs.add(p.stream.position.listen((v) { if (!_seeking && mounted) setState(() => _position = v); }));
    _subs.add(p.stream.duration.listen((v) { if (mounted) setState(() => _duration = v); }));
    _subs.add(p.stream.buffer.listen((v) { if (mounted) setState(() => _buffer = v); }));
    _subs.add(p.stream.volume.listen((v) { if (mounted) setState(() => _volume = v / 100.0); }));

    if (_playing) _startHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    for (final sub in _subs) { sub.cancel(); }
    super.dispose();
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _playing && !_draggingVolume && !_seeking) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final accent = c.accent;
    final progressFrac = _duration.inMilliseconds > 0 ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0) : 0.0;
    final bufferFrac = _duration.inMilliseconds > 0 ? (_buffer.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0) : 0.0;
    final volIcon = _volume <= 0 ? Icons.volume_off_rounded : _volume < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded;

    final sliderTheme = SliderThemeData(
      trackHeight: 4,
      activeTrackColor: accent,
      inactiveTrackColor: Colors.white.withValues(alpha: 0.2),
      thumbColor: Colors.white,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
      overlayColor: accent.withValues(alpha: 0.2),
    );

    return KeyboardListener(
      focusNode: FocusNode()..requestFocus(),
      autofocus: true,
      onKeyEvent: (event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.escape) Navigator.of(context).pop();
          if (event.logicalKey == LogicalKeyboardKey.space) widget.player.playOrPause();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: MouseRegion(
          cursor: _controlsVisible ? SystemMouseCursors.basic : SystemMouseCursors.none,
          onHover: (_) { if (!_controlsVisible) setState(() => _controlsVisible = true); _startHideTimer(); },
          child: GestureDetector(
            onTap: () => widget.player.playOrPause(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Video surface — fills entire screen, aspect ratio preserved
                mkv.Video(
                  controller: widget.controller,
                  controls: null,
                  fit: BoxFit.contain,
                ),

                // Big play button
                if (!_playing)
                  Center(child: _VideoBigPlayButton(size: 72, iconSize: 48)),

                // Close button — top right
                Positioned(
                  top: 16, right: 16,
                  child: AnimatedOpacity(
                    opacity: _controlsVisible ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white, size: 28),
                        onPressed: () => Navigator.of(context).pop(),
                        style: IconButton.styleFrom(backgroundColor: Colors.black54),
                      ),
                    ),
                  ),
                ),

                // Controls bar — bottom
                Positioned(
                  bottom: 0, left: 0, right: 0,
                  child: AnimatedOpacity(
                    opacity: _controlsVisible ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 250),
                    child: GestureDetector(
                      onTap: () {}, // absorb
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter, end: Alignment.topCenter,
                            colors: [Color(0xCC000000), Colors.transparent],
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Seek bar
                            _VideoSeekBar(
                              accent: accent,
                              bufferFraction: bufferFrac,
                              progressFraction: progressFrac,
                              duration: _duration,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              onSeekStart: () => _seeking = true,
                              onSeekUpdate: (frac) => setState(() => _position = Duration(milliseconds: (_duration.inMilliseconds * frac).round())),
                              onSeekEnd: (frac) { _seeking = false; widget.player.seek(Duration(milliseconds: (_duration.inMilliseconds * frac).round())); },
                            ),
                            // Controls row
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                              child: Row(children: [
                                _fsBtn(icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded, onTap: () => widget.player.playOrPause()),
                                const SizedBox(width: 8),
                                Text('${_fmt(_position)} / ${_fmt(_duration)}', style: TextStyle(color: c.gray400, fontSize: 13, fontFamily: 'monospace')),
                                const Spacer(),
                                _fsBtn(icon: volIcon, onTap: () => widget.player.setVolume(_volume > 0 ? 0 : 100)),
                                MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: SizedBox(
                                    width: 80,
                                    child: SliderTheme(
                                      data: sliderTheme,
                                      child: Slider(
                                        value: _volume,
                                        onChangeStart: (_) => _draggingVolume = true,
                                        onChanged: (v) => widget.player.setVolume(v * 100),
                                        onChangeEnd: (_) { _draggingVolume = false; _startHideTimer(); },
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _fsBtn(icon: Icons.fullscreen_exit_rounded, onTap: () => Navigator.of(context).pop()),
                              ]),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fsBtn({required IconData icon, required VoidCallback onTap}) {
    return _VideoControlButton(icon: icon, onTap: onTap, size: 22);
  }
}

/// Compact inline audio player with play/pause and progress.
class _InlineAudioPlayer extends StatefulWidget {
  final String url;
  final String filename;
  final InfernoColors colors;
  const _InlineAudioPlayer({required this.url, required this.filename, required this.colors});

  @override
  State<_InlineAudioPlayer> createState() => _InlineAudioPlayerState();
}

class _InlineAudioPlayerState extends State<_InlineAudioPlayer> {
  @override
  Widget build(BuildContext context) {
    // Compact player card — full just_audio integration will be wired later
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      constraints: const BoxConstraints(maxWidth: 400),
      decoration: BoxDecoration(
        color: widget.colors.gray900,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: widget.colors.gray700),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: () => launchUrl(Uri.parse(widget.url), mode: LaunchMode.externalApplication),
          child: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: widget.colors.accent.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.play_arrow, color: widget.colors.accent, size: 20),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.filename, style: TextStyle(color: widget.colors.gray200, fontSize: 13), overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            // Progress bar placeholder
            Container(
              height: 4,
              decoration: BoxDecoration(
                color: widget.colors.gray700,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        )),
        const SizedBox(width: 12),
        Icon(Icons.audiotrack, size: 16, color: widget.colors.gray500),
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
  final String type; // 'text', 'image', 'blossom', 'tenor', 'youtube', 'video', 'audio', 'document', 'invite'
  final String content;
  _ContentPart(this.type, this.content);
}

/// Rich invite embed card shown inline in messages when an invite link is detected.
class InviteEmbed extends ConsumerStatefulWidget {
  final String uri;
  final InfernoColors colors;
  const InviteEmbed({super.key, required this.uri, required this.colors});

  @override
  ConsumerState<InviteEmbed> createState() => _InviteEmbedState();
}

class _InviteEmbedState extends ConsumerState<InviteEmbed> {
  InviteResolution? _resolution;
  bool _loading = true;
  bool _joining = false;
  int _memberCount = 0;
  int _onlineCount = 0;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    try {
      final inviteService = ref.read(inviteServiceProvider);
      final res = await inviteService.resolveInviteFromUri(widget.uri);
      if (!mounted) return;

      // Try enriching with local server data
      if (res != null && res.nostrGroupId.isNotEmpty) {
        final db = ref.read(databaseProvider);
        final server = await (db.select(db.servers)
              ..where((s) => s.nostrGroupId.equals(res.nostrGroupId)))
            .getSingleOrNull();
        if (server != null) {
          final members = await (db.select(db.remoteMembers)
                ..where((m) => m.serverId.equals(server.id)))
              .get();
          final presenceService = ref.read(presenceServiceProvider);
          final online = members.where((m) =>
              presenceService.getPresence(m.pubkey) == OnlineState.online).length;

          setState(() {
            _resolution = InviteResolution(
              code: res.code,
              nostrGroupId: res.nostrGroupId,
              serverName: server.name,
              description: server.description,
              iconUrl: server.iconUrl,
              naddr: res.naddr,
              state: res.state,
              maxUses: res.maxUses,
              usesCount: res.usesCount,
              expiresAt: res.expiresAt,
            );
            _memberCount = members.length;
            _onlineCount = online;
            _loading = false;
          });
          return;
        }
      }

      setState(() { _resolution = res; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _joinServer() async {
    final res = _resolution;
    if (res == null || res.state != InviteState.valid) return;

    // Check if already a member
    final db = ref.read(databaseProvider);
    if (res.nostrGroupId.isNotEmpty) {
      final server = await (db.select(db.servers)
            ..where((s) => s.nostrGroupId.equals(res.nostrGroupId)))
          .getSingleOrNull();
      if (server != null) {
        final membership = await (db.select(db.serverMemberships)
              ..where((m) => m.serverId.equals(server.id)))
            .getSingleOrNull();
        if (membership != null) {
          // Already a member — navigate there
          if (mounted) {
            final router = GoRouter.of(context);
            router.go('/servers/${server.publicId}');
          }
          return;
        }
      }
    }

    setState(() => _joining = true);
    try {
      final syncService = ref.read(serverSyncServiceProvider);
      final inviteService = ref.read(inviteServiceProvider);
      final server = await inviteService.acceptInvite(
        nostrGroupId: res.nostrGroupId,
        userId: 1,
        syncService: syncService,
      );
      if (!mounted) return;
      if (server != null) {
        GoRouter.of(context).go('/servers/${server.publicId}');
      }
    } catch (_) {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;

    if (_loading) {
      return Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(16),
        constraints: const BoxConstraints(maxWidth: 380),
        decoration: BoxDecoration(
          color: c.gray800.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.gray700),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: c.gray500)),
            const SizedBox(width: 10),
            Text('Resolving invite...', style: TextStyle(color: c.gray400, fontSize: 13)),
          ],
        ),
      );
    }

    if (_resolution == null) {
      return Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 380),
        decoration: BoxDecoration(
          color: c.gray800.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.gray700),
        ),
        child: Text('Could not resolve invite', style: TextStyle(color: c.gray500, fontSize: 13)),
      );
    }

    final res = _resolution!;
    final name = res.serverName ?? 'Unknown Server';
    final isValid = res.state == InviteState.valid;

    String? stateText;
    if (res.state == InviteState.expired) stateText = 'Invite Expired';
    if (res.state == InviteState.revoked) stateText = 'Invite No Longer Valid';
    if (res.state == InviteState.maxedOut) stateText = 'Invite Reached Max Uses';

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      constraints: const BoxConstraints(maxWidth: 380),
      decoration: BoxDecoration(
        color: c.gray800.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.gray700),
      ),
      child: Row(
        children: [
          // Server icon
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: c.gray700,
              borderRadius: BorderRadius.circular(10),
              image: res.iconUrl != null
                  ? DecorationImage(image: NetworkImage(res.iconUrl!), fit: BoxFit.cover)
                  : null,
            ),
            child: res.iconUrl == null
                ? Center(child: Text(name[0].toUpperCase(), style: TextStyle(color: c.gray200, fontWeight: FontWeight.bold, fontSize: 18)))
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("You've been invited to join a server",
                    style: TextStyle(color: c.gray500, fontSize: 11)),
                const SizedBox(height: 2),
                Text(name, style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                if (_memberCount > 0) ...[
                  const SizedBox(height: 4),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: Colors.green, shape: BoxShape.circle)),
                    const SizedBox(width: 4),
                    Text('$_onlineCount Online', style: TextStyle(color: c.gray400, fontSize: 11)),
                    const SizedBox(width: 10),
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: c.gray500, shape: BoxShape.circle)),
                    const SizedBox(width: 4),
                    Text('$_memberCount Members', style: TextStyle(color: c.gray400, fontSize: 11)),
                  ]),
                ],
                if (stateText != null) ...[
                  const SizedBox(height: 4),
                  Text(stateText, style: TextStyle(color: c.accent, fontSize: 11, fontWeight: FontWeight.w500)),
                ],
              ],
            ),
          ),
          if (isValid)
            _joining
                ? Padding(
                    padding: const EdgeInsets.all(8),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: c.accent)),
                  )
                : ElevatedButton(
                    onPressed: _joinServer,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Join', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
        ],
      ),
    );
  }
}

/// Wraps a GIF image with a hover-to-show fire save button (matches Rails gif_save_controller).
/// The fire icon is outlined when not saved, solid+lit when saved.
class GifSaveOverlay extends ConsumerStatefulWidget {
  final String gifUrl;
  final Widget child;
  const GifSaveOverlay({super.key, required this.gifUrl, required this.child});

  @override
  ConsumerState<GifSaveOverlay> createState() => _GifSaveOverlayState();
}

class _GifSaveOverlayState extends ConsumerState<GifSaveOverlay> {
  bool _hovering = false;
  bool _favorited = false;
  bool _animating = false;
  GifFavoritesService? _favService;

  @override
  void initState() {
    super.initState();
    _initService();
  }

  Future<void> _initService() async {
    final db = ref.read(databaseProvider);
    _favService = GifFavoritesService(db, 1);
    // Check if this GIF URL is in the default Favorites collection
    final fav = await _favService!.getFavoriteInDefaultByGifUrl(widget.gifUrl);
    if (mounted && fav != null) {
      setState(() => _favorited = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        children: [
          widget.child,
          // Fire save button — top-left, visible on hover
          Positioned(
            top: 8, left: 8,
            child: AnimatedOpacity(
              opacity: _hovering ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 150),
              child: GestureDetector(
                onTap: _toggleFavorite,
                child: Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: AnimatedScale(
                      scale: _animating ? 1.3 : 1.0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutBack,
                      child: SvgPicture.asset(
                        'assets/icons/inferno_mono.svg',
                        width: 20, height: 20,
                        colorFilter: ColorFilter.mode(
                          _favorited ? c.accent : Colors.white.withValues(alpha: 0.8),
                          BlendMode.srcIn,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleFavorite() async {
    if (_favService == null) return;
    setState(() => _animating = true);

    // Use gifUrl as the tenorGifId for GIFs encountered in message history
    // (we don't have the real Tenor numeric ID from the media URL)
    final nowFavorited = await _favService!.toggleFavorite(
      tenorGifId: widget.gifUrl,
      tenorUrl: widget.gifUrl,
      previewUrl: widget.gifUrl,
      gifUrl: widget.gifUrl,
    );

    if (mounted) {
      setState(() {
        _favorited = nowFavorited;
        _animating = false;
      });
    }
  }
}

/// Unfurls a tenor.com/view/ page URL by fetching og:image, then renders inline.
/// Matches Rails TenorUnfurlJob: fetches the HTML, extracts og:image meta tag.
class _TenorUnfurl extends ConsumerStatefulWidget {
  final String url;
  final InfernoColors colors;
  const _TenorUnfurl({required this.url, required this.colors});

  @override
  ConsumerState<_TenorUnfurl> createState() => _TenorUnfurlState();
}

class _TenorUnfurlState extends ConsumerState<_TenorUnfurl> {
  String? _imageUrl;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _unfurl();
  }

  Future<void> _unfurl() async {
    // Check cache first
    final cached = _ogImageCache[widget.url];
    if (cached != null) {
      if (mounted) setState(() { _imageUrl = cached; _loading = false; });
      return;
    }

    try {
      final response = await http.get(
        Uri.parse(widget.url),
        headers: {'User-Agent': 'Mozilla/5.0'},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        // Extract og:image from HTML
        final ogMatch = RegExp(r'property="og:image"\s+content="([^"]+)"').firstMatch(response.body);
        // Also try the reverse attribute order
        final ogMatch2 = ogMatch ?? RegExp(r'content="([^"]+)"\s+property="og:image"').firstMatch(response.body);
        final imgUrl = (ogMatch ?? ogMatch2)?.group(1);
        if (imgUrl != null) {
          _ogImageCache[widget.url] = imgUrl;
          if (mounted) setState(() { _imageUrl = imgUrl; _loading = false; });
          return;
        }
      }
    } catch (_) {}

    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final mediaCache = ref.read(mediaCacheServiceProvider);

    if (_loading) {
      // Use cached dimensions if known from a previous session
      final cached = _imageUrl != null ? mediaCache.get(_imageUrl!) : null;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Container(
          width: cached?.width ?? 300, height: cached?.height ?? 200,
          decoration: BoxDecoration(color: c.gray700, borderRadius: BorderRadius.circular(8)),
          child: cached == null
              ? Center(child: CircularProgressIndicator(strokeWidth: 2, color: c.gray500))
              : null,
        ),
      );
    }

    if (_imageUrl == null) {
      return GestureDetector(
        onTap: () => launchUrl(Uri.parse(widget.url), mode: LaunchMode.externalApplication),
        child: Text(widget.url, style: TextStyle(color: c.accent, fontSize: 14)),
      );
    }

    final cachedSize = mediaCache.get(_imageUrl!);

    final imageWidget = GifSaveOverlay(
      gifUrl: _imageUrl!,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: cachedSize != null
              ? SizedBox(
                  width: cachedSize.width,
                  height: cachedSize.height,
                  child: CachedNetworkImage(
                    imageUrl: _imageUrl!,
                    fit: BoxFit.contain,
                    memCacheWidth: 800,
                    placeholder: (context, url) => Container(
                      decoration: BoxDecoration(color: c.gray700, borderRadius: BorderRadius.circular(8)),
                    ),
                    errorWidget: (context, url, error) => GestureDetector(
                      onTap: () => launchUrl(Uri.parse(widget.url), mode: LaunchMode.externalApplication),
                      child: Text(widget.url, style: TextStyle(color: c.accent, fontSize: 14)),
                    ),
                  ),
                )
              : CachedNetworkImage(
                  imageUrl: _imageUrl!,
                  fit: BoxFit.contain,
                  memCacheWidth: 800,
                  imageBuilder: (context, imageProvider) {
                    imageProvider.resolve(ImageConfiguration.empty).addListener(
                      ImageStreamListener((info, _) {
                        final w = info.image.width.toDouble();
                        final h = info.image.height.toDouble();
                        const maxW = 400.0;
                        const maxH = 350.0;
                        final scale = (w / maxW).clamp(1.0, double.infinity);
                        final scaledW = w / scale;
                        final scaledH = h / scale;
                        final finalH = scaledH.clamp(0.0, maxH);
                        final finalW = finalH < scaledH ? scaledW * (finalH / scaledH) : scaledW;
                        mediaCache.put(_imageUrl!, finalW, finalH);
                      }),
                    );
                    return ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 400, maxHeight: 350),
                      child: Image(image: imageProvider, fit: BoxFit.contain),
                    );
                  },
                  placeholder: (context, url) => Container(
                    width: 300, height: 200,
                    decoration: BoxDecoration(color: c.gray700, borderRadius: BorderRadius.circular(8)),
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: c.gray500)),
                  ),
                  errorWidget: (context, url, error) => GestureDetector(
                    onTap: () => launchUrl(Uri.parse(widget.url), mode: LaunchMode.externalApplication),
                    child: Text(widget.url, style: TextStyle(color: c.accent, fontSize: 14)),
                  ),
                ),
        ),
      ),
    );

    // Wrap with click-to-lightbox and right-click context menu
    return GestureDetector(
      onTap: () => MediaLightbox.show(context, url: _imageUrl!, filename: _imageUrl!.split('/').last.split('?').first),
      onSecondaryTapUp: (details) => showMediaContextMenu(
        context,
        position: details.globalPosition,
        url: _imageUrl!,
      ),
      child: MouseRegion(cursor: SystemMouseCursors.click, child: imageWidget),
    );
  }
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

/// NSFW/Spoiler blur overlay — click to reveal, with gaussian blur
class _NsfwBlurWrap extends StatefulWidget {
  final InfernoColors colors;
  final Widget child;
  final String label;
  const _NsfwBlurWrap({required this.colors, required this.child, this.label = 'NSFW'});

  @override
  State<_NsfwBlurWrap> createState() => _NsfwBlurWrapState();
}

class _NsfwBlurWrapState extends State<_NsfwBlurWrap> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Always render the child so it sizes the stack
        if (_revealed) widget.child
        else ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: widget.child,
          ),
        ),
        // Overlay label + click target
        if (!_revealed)
          Positioned.fill(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _revealed = true),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xF01a1a1a),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.visibility_off, color: Colors.white70, size: 16),
                          const SizedBox(width: 6),
                          Text('${widget.label} — click to reveal', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
