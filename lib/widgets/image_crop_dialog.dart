import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// Mode for the crop dialog.
enum CropMode { avatar, banner }

/// Shows a crop dialog for avatar (circular, 512x512) or banner (full-width, cover).
/// Returns the cropped image bytes (PNG) or null if cancelled.
Future<Uint8List?> showImageCropDialog(
  BuildContext context, {
  required Uint8List imageBytes,
  required CropMode mode,
  required Color backgroundColor,
  required Color accentColor,
}) {
  return showDialog<Uint8List>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _ImageCropDialog(
      imageBytes: imageBytes,
      mode: mode,
      backgroundColor: backgroundColor,
      accentColor: accentColor,
    ),
  );
}

class _ImageCropDialog extends StatefulWidget {
  final Uint8List imageBytes;
  final CropMode mode;
  final Color backgroundColor;
  final Color accentColor;

  const _ImageCropDialog({
    required this.imageBytes,
    required this.mode,
    required this.backgroundColor,
    required this.accentColor,
  });

  @override
  State<_ImageCropDialog> createState() => _ImageCropDialogState();
}

class _ImageCropDialogState extends State<_ImageCropDialog> {
  ui.Image? _image;
  double _scale = 1.0;
  double _baseScale = 1.0;
  Offset _offset = Offset.zero;
  Offset _dragStart = Offset.zero;
  Offset _offsetStart = Offset.zero;
  bool _cropping = false;

  // Viewport dimensions
  double get _viewportWidth => widget.mode == CropMode.avatar ? 300 : 480;
  double get _viewportHeight => widget.mode == CropMode.avatar ? 300 : 200;

  // Output dimensions
  static const _avatarSize = 512;
  static const _bannerWidth = 960;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    final codec = await ui.instantiateImageCodec(widget.imageBytes);
    final frame = await codec.getNextFrame();
    if (mounted) {
      setState(() {
        _image = frame.image;
        _initializeTransform();
      });
    }
  }

  void _initializeTransform() {
    if (_image == null) return;
    final iw = _image!.width.toDouble();
    final ih = _image!.height.toDouble();

    if (widget.mode == CropMode.avatar) {
      // Fit: scale so image fits inside viewport
      _baseScale = math.min(_viewportWidth / iw, _viewportHeight / ih);
    } else {
      // Cover: scale so image fully covers viewport
      _baseScale = math.max(_viewportWidth / iw, _viewportHeight / ih);
    }
    _scale = _baseScale;
    // Center the image
    _offset = Offset(
      (_viewportWidth - iw * _scale) / 2,
      (_viewportHeight - ih * _scale) / 2,
    );
  }

  void _onScaleChanged(double newScale) {
    if (_image == null) return;
    final oldScale = _scale;
    setState(() {
      _scale = newScale;
      // Zoom around viewport center
      final cx = _viewportWidth / 2;
      final cy = _viewportHeight / 2;
      _offset = Offset(
        cx - (cx - _offset.dx) * (_scale / oldScale),
        cy - (cy - _offset.dy) * (_scale / oldScale),
      );
      _constrainOffset();
    });
  }

  void _onPanStart(DragStartDetails details) {
    _dragStart = details.localPosition;
    _offsetStart = _offset;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      _offset = _offsetStart + (details.localPosition - _dragStart);
      _constrainOffset();
    });
  }

  void _constrainOffset() {
    if (_image == null) return;
    final iw = _image!.width * _scale;
    final ih = _image!.height * _scale;

    // For banner (cover mode): image must fully cover viewport
    // For avatar: allow some freedom but keep circle area covered
    double minX, maxX, minY, maxY;

    if (widget.mode == CropMode.banner) {
      minX = _viewportWidth - iw;
      maxX = 0;
      minY = _viewportHeight - ih;
      maxY = 0;
    } else {
      // Avatar: ensure the circle area (centered, radius = viewportWidth/2 * 0.8) is covered
      final circleR = _viewportWidth * 0.4;
      final cx = _viewportWidth / 2;
      final cy = _viewportHeight / 2;
      minX = (cx + circleR) - iw;
      maxX = cx - circleR;
      minY = (cy + circleR) - ih;
      maxY = cy - circleR;
    }

    _offset = Offset(
      _offset.dx.clamp(math.min(minX, maxX), math.max(minX, maxX)),
      _offset.dy.clamp(math.min(minY, maxY), math.max(minY, maxY)),
    );
  }

  Future<void> _crop() async {
    if (_image == null || _cropping) return;
    setState(() => _cropping = true);

    try {
      // Decode the source image with the `image` package for pixel manipulation
      final srcImage = img.decodeImage(widget.imageBytes);
      if (srcImage == null) return;

      // Calculate source rectangle from current viewport transform
      final natPerPx = srcImage.width / (_image!.width * _scale);

      if (widget.mode == CropMode.avatar) {
        // Circle crop: extract square around the circle center
        final circleR = _viewportWidth * 0.4;
        final cx = _viewportWidth / 2;
        final cy = _viewportHeight / 2;

        final srcX = ((cx - circleR - _offset.dx) * natPerPx).round();
        final srcY = ((cy - circleR - _offset.dy) * natPerPx).round();
        final srcSize = (circleR * 2 * natPerPx).round();

        var cropped = img.copyCrop(srcImage,
            x: srcX.clamp(0, srcImage.width - 1),
            y: srcY.clamp(0, srcImage.height - 1),
            width: srcSize.clamp(1, srcImage.width - srcX.clamp(0, srcImage.width - 1)),
            height: srcSize.clamp(1, srcImage.height - srcY.clamp(0, srcImage.height - 1)));
        cropped = img.copyResize(cropped, width: _avatarSize, height: _avatarSize);

        // Apply circular mask
        final radius = _avatarSize ~/ 2;
        for (var y = 0; y < _avatarSize; y++) {
          for (var x = 0; x < _avatarSize; x++) {
            final dx = x - radius;
            final dy = y - radius;
            if (dx * dx + dy * dy > radius * radius) {
              cropped.setPixelRgba(x, y, 0, 0, 0, 0);
            }
          }
        }

        final png = Uint8List.fromList(img.encodePng(cropped));
        if (mounted) Navigator.pop(context, png);
      } else {
        // Banner crop: extract viewport area
        final srcX = (-_offset.dx * natPerPx).round();
        final srcY = (-_offset.dy * natPerPx).round();
        final srcW = (_viewportWidth * natPerPx).round();
        final srcH = (_viewportHeight * natPerPx).round();

        var cropped = img.copyCrop(srcImage,
            x: srcX.clamp(0, srcImage.width - 1),
            y: srcY.clamp(0, srcImage.height - 1),
            width: srcW.clamp(1, srcImage.width - srcX.clamp(0, srcImage.width - 1)),
            height: srcH.clamp(1, srcImage.height - srcY.clamp(0, srcImage.height - 1)));

        final outH = (_bannerWidth * _viewportHeight / _viewportWidth).round();
        cropped = img.copyResize(cropped, width: _bannerWidth, height: outH);

        final png = Uint8List.fromList(img.encodePng(cropped));
        if (mounted) Navigator.pop(context, png);
      }
    } finally {
      if (mounted) setState(() => _cropping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.backgroundColor;
    final accent = widget.accentColor;
    final title = widget.mode == CropMode.avatar ? 'Crop Avatar' : 'Crop Banner';

    return AlertDialog(
      backgroundColor: bg,
      title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16)),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      content: SizedBox(
        width: _viewportWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Viewport
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: _viewportWidth,
                height: _viewportHeight,
                color: Colors.black,
                child: _image == null
                    ? const Center(child: CircularProgressIndicator())
                    : GestureDetector(
                        onPanStart: _onPanStart,
                        onPanUpdate: _onPanUpdate,
                        child: CustomPaint(
                          size: Size(_viewportWidth, _viewportHeight),
                          painter: _CropPainter(
                            image: _image!,
                            offset: _offset,
                            scale: _scale,
                            mode: widget.mode,
                            viewportWidth: _viewportWidth,
                            viewportHeight: _viewportHeight,
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 16),
            // Zoom slider
            Row(
              children: [
                const Icon(Icons.photo_size_select_small, color: Colors.white54, size: 16),
                Expanded(
                  child: Slider(
                    value: _scale,
                    min: _baseScale * 0.8,
                    max: _baseScale * 3.0,
                    activeColor: accent,
                    inactiveColor: Colors.white24,
                    onChanged: _onScaleChanged,
                  ),
                ),
                const Icon(Icons.photo_size_select_large, color: Colors.white54, size: 16),
              ],
            ),
            const SizedBox(height: 4),
            Text('Drag to reposition', style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel', style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
        ),
        ElevatedButton(
          onPressed: _cropping ? null : _crop,
          style: ElevatedButton.styleFrom(backgroundColor: accent),
          child: _cropping
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Apply'),
        ),
      ],
    );
  }
}

/// Paints the image with offset/scale and draws the crop overlay.
class _CropPainter extends CustomPainter {
  final ui.Image image;
  final Offset offset;
  final double scale;
  final CropMode mode;
  final double viewportWidth;
  final double viewportHeight;

  _CropPainter({
    required this.image,
    required this.offset,
    required this.scale,
    required this.mode,
    required this.viewportWidth,
    required this.viewportHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw image
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);
    canvas.drawImage(image, Offset.zero, Paint());
    canvas.restore();

    // Draw overlay
    if (mode == CropMode.avatar) {
      _drawCircularOverlay(canvas, size);
    }
    // Banner: no overlay needed — entire viewport is the crop area
  }

  void _drawCircularOverlay(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final radius = size.width * 0.4;

    // Dark overlay outside the circle
    final overlayPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: radius))
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(overlayPath, Paint()..color = Colors.black.withValues(alpha: 0.6));

    // Circle border
    canvas.drawCircle(
      Offset(cx, cy),
      radius,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.offset != offset || old.scale != scale || old.image != image;
}
