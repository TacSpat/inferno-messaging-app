class ContentRenderer {
  /// Extract URLs from message content
  static List<String> extractUrls(String content) {
    final regex = RegExp(
      r'https?://[^\s<>\[\]]+',
      caseSensitive: false,
    );
    return regex.allMatches(content).map((m) => m.group(0)!).toList();
  }

  /// Check if a URL is an image
  static bool isImageUrl(String url) {
    final lower = url.toLowerCase();
    return lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') || lower.endsWith('.webp') || lower.endsWith('.avif');
  }

  /// Check if a URL is a video
  static bool isVideoUrl(String url) {
    final lower = url.toLowerCase();
    return lower.endsWith('.mp4') || lower.endsWith('.webm') || lower.endsWith('.mov');
  }

  /// Check if a URL is a YouTube link
  static bool isYouTubeUrl(String url) {
    return url.contains('youtube.com/watch') || url.contains('youtu.be/');
  }

  /// Extract YouTube video ID
  static String? extractYouTubeId(String url) {
    final regex = RegExp(r'(?:youtube\.com/watch\?v=|youtu\.be/)([a-zA-Z0-9_-]{11})');
    final match = regex.firstMatch(url);
    return match?.group(1);
  }

  /// Replace :emoji_name: with custom emoji URLs
  static String replaceCustomEmoji(String content, Map<String, String> emojiMap) {
    return content.replaceAllMapped(
      RegExp(r':([a-z0-9_]+):'),
      (match) {
        final name = match.group(1)!;
        final url = emojiMap[name];
        if (url != null) return '![emoji]($url)';
        return match.group(0)!;
      },
    );
  }

  /// Get embed type for a URL
  static EmbedType getEmbedType(String url) {
    if (isImageUrl(url)) return EmbedType.image;
    if (isVideoUrl(url)) return EmbedType.video;
    if (isYouTubeUrl(url)) return EmbedType.youtube;
    return EmbedType.link;
  }
}

enum EmbedType { image, video, youtube, link }
