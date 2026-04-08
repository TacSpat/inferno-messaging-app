import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/theme_provider.dart';

/// Inferno flame logo.
/// Uses the multicolor SVG for the inferno theme, mono SVG for all others.
/// The mono version is tinted with `color` (defaults to white).
class InfernoLogo extends ConsumerWidget {
  final double size;
  final Color? color;

  const InfernoLogo({super.key, this.size = 48, this.color});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(infernoColorsProvider);
    final isInfernoTheme = c.accent == const Color(0xFFDC2626); // inferno accent

    if (isInfernoTheme) {
      // Multicolor logo for inferno theme
      return SvgPicture.asset(
        'assets/icons/inferno_color.svg',
        width: size,
        height: size,
      );
    }

    // Single-color logo for all other themes, tinted to the provided color
    return SvgPicture.asset(
      'assets/icons/inferno_mono.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(
        color ?? Colors.white,
        BlendMode.srcIn,
      ),
    );
  }
}
