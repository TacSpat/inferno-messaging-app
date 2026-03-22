import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/content_renderer.dart';

class LinkEmbed extends StatelessWidget {
  final String url;

  const LinkEmbed({super.key, required this.url});

  @override
  Widget build(BuildContext context) {
    final type = ContentRenderer.getEmbedType(url);

    switch (type) {
      case EmbedType.image:
        return _ImageEmbed(url: url);
      case EmbedType.youtube:
        return _YouTubeEmbed(url: url);
      case EmbedType.video:
        return _VideoPlaceholder(url: url);
      case EmbedType.link:
        return const SizedBox.shrink(); // Plain links rendered as text
    }
  }
}

class _ImageEmbed extends StatelessWidget {
  final String url;
  const _ImageEmbed({required this.url});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300, maxWidth: 400),
          child: CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.contain,
            placeholder: (_, s) => Container(
              height: 100, color: const Color(0xFF1E2A4A),
              child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            errorWidget: (_, s, e) => Container(
              height: 60, color: const Color(0xFF1E2A4A),
              child: const Center(child: Icon(Icons.broken_image, color: Color(0xFF5C6B77))),
            ),
          ),
        ),
      ),
    );
  }
}

class _YouTubeEmbed extends StatelessWidget {
  final String url;
  const _YouTubeEmbed({required this.url});

  @override
  Widget build(BuildContext context) {
    final videoId = ContentRenderer.extractYouTubeId(url);
    if (videoId == null) return const SizedBox.shrink();

    final thumbnailUrl = 'https://img.youtube.com/vi/$videoId/hqdefault.jpg';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Stack(
            alignment: Alignment.center,
            children: [
              CachedNetworkImage(
                imageUrl: thumbnailUrl,
                fit: BoxFit.cover,
                placeholder: (_, s) => Container(height: 200, color: const Color(0xFF1E2A4A)),
              ),
              Container(
                width: 60, height: 60,
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(30),
                ),
                child: const Icon(Icons.play_arrow, color: Colors.white, size: 36),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoPlaceholder extends StatelessWidget {
  final String url;
  const _VideoPlaceholder({required this.url});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        height: 60,
        decoration: BoxDecoration(
          color: const Color(0xFF1E2A4A),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const SizedBox(width: 16),
            const Icon(Icons.videocam, color: Color(0xFF8899A6)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                url.split('/').last,
                style: const TextStyle(color: Color(0xFF8899A6), fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
