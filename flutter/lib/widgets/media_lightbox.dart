import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/theme_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void _showTopSnack(BuildContext context, String message) {
  final screenH = MediaQuery.of(context).size.height;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message),
    behavior: SnackBarBehavior.floating,
    width: 300,
    margin: EdgeInsets.only(bottom: screenH - 80),
    duration: const Duration(seconds: 2),
  ));
}

/// Full-screen image lightbox with zoom/pan, download, and context menu.
class MediaLightbox extends ConsumerStatefulWidget {
  final String url;
  final String? filename;

  const MediaLightbox({super.key, required this.url, this.filename});

  /// Open the lightbox as a full-screen overlay
  static void show(BuildContext context, {required String url, String? filename}) {
    Navigator.of(context, rootNavigator: true).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black87,
      barrierDismissible: true,
      pageBuilder: (_, __, ___) => MediaLightbox(url: url, filename: filename),
      transitionsBuilder: (_, animation, __, child) {
        return FadeTransition(opacity: animation, child: child);
      },
      transitionDuration: const Duration(milliseconds: 200),
    ));
  }

  @override
  ConsumerState<MediaLightbox> createState() => _MediaLightboxState();
}

class _MediaLightboxState extends ConsumerState<MediaLightbox> {
  final _transformController = TransformationController();
  bool _isZoomed = false;
  bool _saving = false;

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    if (_isZoomed) {
      _transformController.value = Matrix4.identity();
    } else {
      // Zoom to 3x centered
      final size = MediaQuery.of(context).size;
      _transformController.value = Matrix4.identity()
        ..storage[12] = -size.width  // translateX
        ..storage[13] = -size.height // translateY
        ..storage[0] = 3.0   // scaleX
        ..storage[5] = 3.0   // scaleY
        ..storage[10] = 3.0; // scaleZ
    }
    setState(() => _isZoomed = !_isZoomed);
  }

  Future<void> _saveImage() async {
    setState(() => _saving = true);
    try {
      final response = await http.get(Uri.parse(widget.url));
      if (response.statusCode == 200) {
        final dir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
        final fname = widget.filename ?? widget.url.split('/').last.split('?').first;
        final file = File('${dir.path}/$fname');
        await file.writeAsBytes(response.bodyBytes);
        if (mounted) _showTopSnack(context, 'Saved to ${file.path}');
      }
    } catch (e) {
      if (mounted) _showTopSnack(context, 'Failed to save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _copyLink() {
    Clipboard.setData(ClipboardData(text: widget.url));
    _showTopSnack(context, 'Link copied to clipboard');
  }

  void _openInBrowser() {
    launchUrl(Uri.parse(widget.url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);
    final accent = c.accent;
    final fname = widget.filename ?? widget.url.split('/').last.split('?').first;

    return KeyboardListener(
      focusNode: FocusNode()..requestFocus(),
      autofocus: true,
      onKeyEvent: (event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
        }
      },
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              // Image with zoom/pan
              Center(
                child: GestureDetector(
                  onTap: () {}, // Don't close when tapping image
                  onDoubleTap: _toggleZoom,
                  child: InteractiveViewer(
                    transformationController: _transformController,
                    minScale: 1.0,
                    maxScale: 8.0,
                    onInteractionEnd: (_) {
                      setState(() => _isZoomed = _transformController.value.getMaxScaleOnAxis() > 1.1);
                    },
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.9,
                        maxHeight: MediaQuery.of(context).size.height * 0.85,
                      ),
                      child: Image.network(
                        widget.url,
                        fit: BoxFit.contain,
                        loadingBuilder: (_, child, progress) {
                          if (progress == null) return child;
                          return Center(
                            child: CircularProgressIndicator(
                              value: progress.expectedTotalBytes != null
                                  ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
                                  : null,
                              color: accent,
                            ),
                          );
                        },
                        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 64, color: Colors.grey),
                      ),
                    ),
                  ),
                ),
              ),
              // Close button
              Positioned(
                top: 16,
                right: 16,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  onPressed: () => Navigator.of(context).pop(),
                  style: IconButton.styleFrom(backgroundColor: Colors.black54),
                ),
              ),
              // Bottom bar: filename + actions
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(fname,
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 16),
                      _ActionButton(
                        icon: Icons.link,
                        label: 'Copy Link',
                        onTap: _copyLink,
                      ),
                      const SizedBox(width: 12),
                      _ActionButton(
                        icon: Icons.open_in_new,
                        label: 'Open',
                        onTap: _openInBrowser,
                      ),
                      const SizedBox(width: 12),
                      _ActionButton(
                        icon: _saving ? Icons.hourglass_empty : Icons.download,
                        label: 'Save',
                        onTap: _saving ? null : _saveImage,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _ActionButton({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white12,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: Colors.white70),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Context menu for media (images, videos)
void showMediaContextMenu(
  BuildContext context, {
  required Offset position,
  required String url,
  String? filename,
  bool isVideo = false,
}) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return;

  showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx + 1, position.dy + 1),
    items: [
      if (!isVideo)
        const PopupMenuItem(value: 'copy_image', child: Row(
          children: [Icon(Icons.copy, size: 16), SizedBox(width: 8), Text('Copy Image')],
        )),
      PopupMenuItem(value: 'copy_link', child: Row(
        children: [const Icon(Icons.link, size: 16), const SizedBox(width: 8), Text(isVideo ? 'Copy Media Link' : 'Copy Image Link')],
      )),
      PopupMenuItem(value: 'save', child: Row(
        children: [const Icon(Icons.download, size: 16), const SizedBox(width: 8), Text(isVideo ? 'Save Video' : 'Save Image')],
      )),
      const PopupMenuItem(value: 'open', child: Row(
        children: [Icon(Icons.open_in_new, size: 16), SizedBox(width: 8), Text('Open in Browser')],
      )),
    ],
  ).then((value) async {
    if (value == null) return;
    switch (value) {
      case 'copy_link':
        Clipboard.setData(ClipboardData(text: url));
        if (context.mounted) _showTopSnack(context, 'Link copied to clipboard');
      case 'save':
        try {
          final response = await http.get(Uri.parse(url));
          if (response.statusCode == 200) {
            final dir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
            final fname = filename ?? url.split('/').last.split('?').first;
            final file = File('${dir.path}/$fname');
            await file.writeAsBytes(response.bodyBytes);
            if (context.mounted) _showTopSnack(context, 'Saved to ${file.path}');
          }
        } catch (_) {}
      case 'open':
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      case 'copy_image':
        Clipboard.setData(ClipboardData(text: url));
        if (context.mounted) _showTopSnack(context, 'Image link copied to clipboard');
    }
  });
}
