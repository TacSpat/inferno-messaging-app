import 'dart:math';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// UI effect theme — configurable visual effects independent of color theme.
/// Mix any color theme with any effect theme for customization.
class UiEffectTheme {
  final String name;
  final String label;

  /// Ember particles floating up from active elements
  final bool embers;
  /// Number of ember particles per emitter
  final int emberCount;
  /// Ember particle size range
  final double emberMinSize;
  final double emberMaxSize;
  /// Ember drift speed (pixels per second)
  final double emberSpeed;

  /// Glow pulse on active/focused elements
  final bool glowPulse;
  /// Glow pulse intensity (0.0 - 1.0)
  final double glowIntensity;
  /// Glow pulse speed (seconds per cycle)
  final double glowCycleSeconds;

  /// Accent tint on hover
  final bool hoverTint;
  /// Hover tint opacity (0.0 - 1.0)
  final double hoverTintOpacity;

  /// Left border accent on active/hovered items
  final bool accentBorder;
  /// Accent border width
  final double accentBorderWidth;

  /// Molten gradient shimmer on active indicators
  final bool moltenShimmer;

  /// Avatar glow ring on hover
  final bool avatarGlow;

  /// Online dot glow
  final bool onlineDotGlow;

  const UiEffectTheme({
    required this.name,
    required this.label,
    this.embers = false,
    this.emberCount = 6,
    this.emberMinSize = 1.5,
    this.emberMaxSize = 3.0,
    this.emberSpeed = 20.0,
    this.glowPulse = false,
    this.glowIntensity = 0.3,
    this.glowCycleSeconds = 3.0,
    this.hoverTint = false,
    this.hoverTintOpacity = 0.06,
    this.accentBorder = false,
    this.accentBorderWidth = 2.0,
    this.moltenShimmer = false,
    this.avatarGlow = false,
    this.onlineDotGlow = false,
  });

  /// All available effect themes
  static const none = UiEffectTheme(name: 'none', label: 'None');

  static const inferno = UiEffectTheme(
    name: 'inferno',
    label: 'Inferno',
    embers: true,
    emberCount: 8,
    emberMinSize: 1.5,
    emberMaxSize: 3.5,
    emberSpeed: 18.0,
    glowPulse: true,
    glowIntensity: 0.35,
    glowCycleSeconds: 3.0,
    hoverTint: true,
    hoverTintOpacity: 0.06,
    accentBorder: true,
    accentBorderWidth: 2.0,
    moltenShimmer: true,
    avatarGlow: true,
    onlineDotGlow: true,
  );

  static const subtle = UiEffectTheme(
    name: 'subtle',
    label: 'Subtle Glow',
    embers: false,
    glowPulse: true,
    glowIntensity: 0.15,
    glowCycleSeconds: 4.0,
    hoverTint: true,
    hoverTintOpacity: 0.04,
    accentBorder: true,
    accentBorderWidth: 1.5,
    avatarGlow: true,
    onlineDotGlow: true,
  );

  static const electric = UiEffectTheme(
    name: 'electric',
    label: 'Electric',
    embers: true,
    emberCount: 4,
    emberMinSize: 1.0,
    emberMaxSize: 2.0,
    emberSpeed: 30.0,
    glowPulse: true,
    glowIntensity: 0.5,
    glowCycleSeconds: 1.5,
    hoverTint: true,
    hoverTintOpacity: 0.08,
    accentBorder: true,
    accentBorderWidth: 2.0,
    moltenShimmer: true,
    avatarGlow: true,
    onlineDotGlow: true,
  );

  static List<UiEffectTheme> get all => [none, inferno, subtle, electric];
  static List<String> get names => all.map((e) => e.name).toList();
  static UiEffectTheme forName(String name) => all.firstWhere((e) => e.name == name, orElse: () => none);
}

// ──────────────────────────────────────────────────────────
// Ember Particle System
// ──────────────────────────────────────────────────────────

/// Floating ember particles that drift upward from a widget.
/// Attaches to any widget as an overlay.
class EmberParticles extends StatefulWidget {
  final Widget child;
  final Color color;
  final int count;
  final double minSize;
  final double maxSize;
  final double speed;
  final bool enabled;

  const EmberParticles({
    super.key,
    required this.child,
    required this.color,
    this.count = 6,
    this.minSize = 1.5,
    this.maxSize = 3.0,
    this.speed = 20.0,
    this.enabled = true,
  });

  @override
  State<EmberParticles> createState() => _EmberParticlesState();
}

class _EmberParticlesState extends State<EmberParticles> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<_Ember> _embers;
  final _random = Random();

  @override
  void initState() {
    super.initState();
    _embers = List.generate(widget.count, (_) => _createEmber());
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    _controller.addListener(_tick);
  }

  _Ember _createEmber() {
    return _Ember(
      x: _random.nextDouble(),
      y: _random.nextDouble(),
      size: widget.minSize + _random.nextDouble() * (widget.maxSize - widget.minSize),
      speed: 0.3 + _random.nextDouble() * 0.7,
      opacity: 0.2 + _random.nextDouble() * 0.6,
      wobble: _random.nextDouble() * 2 * pi,
      wobbleSpeed: 0.5 + _random.nextDouble() * 1.5,
    );
  }

  void _tick() {
    if (!mounted) return;
    final dt = 1.0 / 60.0; // ~60fps
    for (int i = 0; i < _embers.length; i++) {
      final e = _embers[i];
      e.y -= e.speed * widget.speed * dt / 200;
      e.wobble += e.wobbleSpeed * dt;
      e.x += sin(e.wobble) * 0.002;
      e.opacity *= 0.998; // Slow fade

      // Reset when off screen or faded
      if (e.y < -0.1 || e.opacity < 0.05) {
        _embers[i] = _createEmber();
        _embers[i].y = 1.0 + _random.nextDouble() * 0.2;
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_tick);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _EmberPainter(embers: _embers, color: widget.color),
            ),
          ),
        ),
      ],
    );
  }
}

class _Ember {
  double x, y, size, speed, opacity, wobble, wobbleSpeed;
  _Ember({
    required this.x, required this.y, required this.size,
    required this.speed, required this.opacity,
    required this.wobble, required this.wobbleSpeed,
  });
}

class _EmberPainter extends CustomPainter {
  final List<_Ember> embers;
  final Color color;
  _EmberPainter({required this.embers, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    for (final e in embers) {
      final paint = Paint()
        ..color = color.withValues(alpha: e.opacity)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, e.size * 0.8);
      canvas.drawCircle(
        Offset(e.x * size.width, e.y * size.height),
        e.size,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_EmberPainter old) => true;
}

// ──────────────────────────────────────────────────────────
// Glow Pulse Wrapper
// ──────────────────────────────────────────────────────────

/// Wraps a widget with a breathing glow effect using the accent color.
class GlowPulse extends StatefulWidget {
  final Widget child;
  final Color color;
  final double intensity;
  final double cycleSeconds;
  final double blurRadius;
  final bool enabled;

  const GlowPulse({
    super.key,
    required this.child,
    required this.color,
    this.intensity = 0.3,
    this.cycleSeconds = 3.0,
    this.blurRadius = 12.0,
    this.enabled = true,
  });

  @override
  State<GlowPulse> createState() => _GlowPulseState();
}

class _GlowPulseState extends State<GlowPulse> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (widget.cycleSeconds * 1000).round()),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final glow = widget.intensity * (0.3 + 0.7 * _controller.value);
        return Container(
          decoration: BoxDecoration(
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: glow),
                blurRadius: widget.blurRadius,
                spreadRadius: 0,
              ),
            ],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

// ──────────────────────────────────────────────────────────
// Accent Hover Tint
// ──────────────────────────────────────────────────────────

/// Applies accent-colored tint on hover with optional left border.
/// Replaces plain color hover backgrounds with themed glow effects.
class AccentHoverTint extends StatefulWidget {
  final Widget child;
  final Color accentColor;
  final double tintOpacity;
  final bool showBorder;
  final double borderWidth;
  final bool isActive;
  final bool enabled;

  const AccentHoverTint({
    super.key,
    required this.child,
    required this.accentColor,
    this.tintOpacity = 0.06,
    this.showBorder = true,
    this.borderWidth = 2.0,
    this.isActive = false,
    this.enabled = true,
  });

  @override
  State<AccentHoverTint> createState() => _AccentHoverTintState();
}

class _AccentHoverTintState extends State<AccentHoverTint> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    final showEffect = _hovering || widget.isActive;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          gradient: showEffect
              ? LinearGradient(
                  colors: [
                    widget.accentColor.withValues(alpha: widget.isActive ? widget.tintOpacity * 2.5 : widget.tintOpacity),
                    widget.accentColor.withValues(alpha: widget.isActive ? widget.tintOpacity : 0),
                  ],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                )
              : null,
          border: widget.showBorder && showEffect
              ? Border(left: BorderSide(
                  color: widget.accentColor.withValues(alpha: widget.isActive ? 0.8 : 0.4),
                  width: widget.borderWidth,
                ))
              : null,
          boxShadow: showEffect
              ? [BoxShadow(
                  color: widget.accentColor.withValues(alpha: 0.15),
                  blurRadius: 8,
                  offset: const Offset(4, 0),
                )]
              : null,
        ),
        child: widget.child,
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────
// Online Dot Glow
// ──────────────────────────────────────────────────────────

/// Status dot with optional animated glow for online state.
class GlowDot extends StatelessWidget {
  final Color color;
  final double size;
  final bool glow;
  final Color borderColor;
  final double borderWidth;

  const GlowDot({
    super.key,
    required this.color,
    this.size = 12,
    this.glow = false,
    this.borderColor = Colors.transparent,
    this.borderWidth = 2,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: borderColor, width: borderWidth),
        boxShadow: glow ? [
          BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 5, spreadRadius: 1),
          BoxShadow(color: color.withValues(alpha: 0.3), blurRadius: 10, spreadRadius: 0),
        ] : null,
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────
// Bar Fire — alcohol fire effect for input bar
// ──────────────────────────────────────────────────────────

/// Small flames that sit on top of a widget.
/// Ignites with a spark burst on [lit] = true, blows away when [lit] = false.
class BarFire extends StatefulWidget {
  final Widget child;
  final bool lit;
  final Color color;
  final Color? colorLight;
  final int flameCount;
  final double maxFlameHeight;
  /// 0.0 = calm, 1.0 = raging. Typing fuels the fire.
  final double fuel;

  const BarFire({
    super.key,
    required this.child,
    required this.lit,
    required this.color,
    this.colorLight,
    this.flameCount = 14,
    this.maxFlameHeight = 12,
    this.fuel = 0.0,
  });

  @override
  State<BarFire> createState() => _BarFireState();
}

class _BarFireState extends State<BarFire> with TickerProviderStateMixin {
  late AnimationController _fireController;
  late AnimationController _igniteController;
  late List<_Flame> _flames;
  final List<_Spark> _sparks = [];
  final _random = Random();
  bool _wasLit = false;
  double _windForce = 0.0;
  double _igniteProgress = 0.0;
  double _igniteOrigin = 0.5;
  bool _igniting = false;
  double _currentFuel = 0.0; // smoothed fuel level for animation

  @override
  void initState() {
    super.initState();
    _flames = List.generate(widget.flameCount, (i) =>
      _createFlameAt((i + 0.5) / widget.flameCount));
    _fireController = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..repeat()
      ..addListener(_tickFire);
    _igniteController = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
  }

  @override
  void didUpdateWidget(BarFire old) {
    super.didUpdateWidget(old);
    if (widget.lit && !_wasLit) {
      _ignite();
    } else if (!widget.lit && _wasLit) {
      _blowOut();
    }
    _wasLit = widget.lit;
  }

  void _ignite() {
    _windForce = 0.0;
    _igniting = true;
    _igniteProgress = 0.0;
    // Spark origin: random point along the top edge (middle 60%)
    _igniteOrigin = 0.2 + _random.nextDouble() * 0.6;
    // Reset all flames but keep them invisible — cascade will light them
    for (int i = 0; i < _flames.length; i++) {
      _flames[i] = _createFlameAt((i + 0.5) / _flames.length);
      _flames[i].opacity = 0;
      // Give the spark origin flame a height boost
    }
    _igniteController.forward(from: 0);
  }

  void _blowOut() {
    _igniting = false;
    _windForce = 1.0;
    _igniteController.reverse(from: 1);
  }

  _Flame _createFlameAt(double baseX, {bool sparkBurst = false}) {
    // Position near the assigned slot with small jitter
    final jitter = (_random.nextDouble() - 0.5) * (1.0 / widget.flameCount);
    return _Flame(
      x: (baseX + jitter).clamp(0.01, 0.99),
      baseHeight: 0.3 + _random.nextDouble() * 0.7,
      phase: _random.nextDouble() * 2 * pi,
      speed: 1.2 + _random.nextDouble() * 1.8,
      width: 0.015 + _random.nextDouble() * 0.02,
      opacity: sparkBurst ? (0.6 + _random.nextDouble() * 0.4) : 0.0,
      tipSway: (_random.nextDouble() - 0.5) * 2,
    );
  }

  void _tickFire() {
    if (!mounted) return;
    final dt = 1.0 / 60.0;

    // Ease fuel level toward target — fast rise, faster decay
    final fuelTarget = widget.fuel;
    if (fuelTarget > _currentFuel) {
      _currentFuel += (fuelTarget - _currentFuel) * 0.25;
    } else {
      _currentFuel += (fuelTarget - _currentFuel) * 0.08;
    }
    _currentFuel = _currentFuel.clamp(0.0, 1.0);

    // Advance ignition cascade
    if (_igniting && _igniteProgress < 1.0) {
      _igniteProgress = (_igniteProgress + dt * 2.5).clamp(0.0, 1.0);
      // Spawn sparks at the cascade front
      if (_random.nextDouble() < 0.6) {
        final edge = _igniteOrigin + _igniteProgress * (_random.nextBool() ? 1 : -1);
        _sparks.add(_Spark(
          x: edge.clamp(0.0, 1.0),
          y: 0,
          vx: (_random.nextDouble() - 0.5) * 40,
          vy: -30 - _random.nextDouble() * 60,
          life: 0.5 + _random.nextDouble() * 0.5,
          age: 0,
          size: 1.5 + _random.nextDouble() * 2,
        ));
      }
    }

    // Spawn sparks — more when fueled
    if (widget.lit && !_igniting && _random.nextDouble() < (0.06 + _currentFuel * 0.2)) {
      final f = _flames[_random.nextInt(_flames.length)];
      if (f.opacity > 0.2) {
        _sparks.add(_Spark(
          x: f.x,
          y: 0,
          vx: (_random.nextDouble() - 0.5) * 20,
          vy: -20 - _random.nextDouble() * 40,
          life: 0.3 + _random.nextDouble() * 0.4,
          age: 0,
          size: 1.0 + _random.nextDouble() * 1.5,
        ));
      }
    }

    // Tick sparks
    for (final s in _sparks) {
      s.age += dt;
      s.x += s.vx * dt / 200; // normalize to 0..1 space
      s.y += s.vy * dt;
      s.vy += 30 * dt; // slight gravity
      s.vx *= 0.98; // air resistance
    }
    _sparks.removeWhere((s) => s.age > s.life);

    for (final f in _flames) {
      // Fuel boosts animation speed slightly — not too fast
      f.phase += f.speed * dt * (3.0 + _currentFuel * 1.5);

      if (widget.lit && _windForce < 0.1) {
        // Fuel-boosted targets: taller, brighter, more movement when typing
        final fuelBoost = _currentFuel;
        final targetOpacity = 0.55 + sin(f.phase) * (0.15 + fuelBoost * 0.2);
        final targetHeight = 0.55 + fuelBoost * 0.7 + sin(f.phase * 1.3 + f.x * 8) * fuelBoost * 0.2;

        if (_igniting && _igniteProgress < 1.0) {
          final dist = (f.x - _igniteOrigin).abs();
          final threshold = _igniteProgress;
          if (dist < threshold) {
            final litAmount = ((threshold - dist) / 0.3).clamp(0.0, 1.0);
            f.opacity += (targetOpacity * litAmount - f.opacity) * 0.15;
            f.baseHeight += (targetHeight - f.baseHeight) * 0.1;
          }
        } else {
          f.baseHeight += (targetHeight - f.baseHeight) * (0.05 + fuelBoost * 0.1);
          f.baseHeight += (_random.nextDouble() - 0.5) * (0.02 + fuelBoost * 0.04);
          f.baseHeight = f.baseHeight.clamp(0.2, 1.3);
          // Fuel makes flames drift/dance more
          f.x += (_random.nextDouble() - 0.5) * (0.001 + fuelBoost * 0.003);
          f.x = f.x.clamp(0.01, 0.99);
          f.opacity += (targetOpacity - f.opacity) * (0.08 + fuelBoost * 0.1);
          if (_igniting) _igniting = false;
        }
      } else if (_windForce > 0.1) {
        // Blowing out: drift outward, shrink, fade
        f.x += (_windForce * dt * 0.3) * (f.x > 0.5 ? 1 : -1); // drift away from center
        f.opacity *= 0.92;
        f.baseHeight *= 0.96;
        _windForce *= 0.97;
      } else {
        f.opacity *= 0.9;
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    _fireController.removeListener(_tickFire);
    _fireController.dispose();
    _igniteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        // Flames wrap around the top and corners of the child
        Positioned(
          left: 10,
          right: 10,
          top: -widget.maxFlameHeight,
          bottom: 0,
          child: IgnorePointer(
            child: CustomPaint(
              painter: _BarFirePainter(
                flames: _flames,
                sparks: _sparks,
                color: widget.color,
                colorLight: widget.colorLight ?? Color.lerp(widget.color, Colors.yellow, 0.4)!,
                maxHeight: widget.maxFlameHeight,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Flame {
  double x, baseHeight, phase, speed, width, opacity;
  double tipSway; // how much the tip sways left/right
  _Flame({
    required this.x, required this.baseHeight, required this.phase,
    required this.speed, required this.width, required this.opacity,
    this.tipSway = 0,
  });
}

class _BarFirePainter extends CustomPainter {
  final List<_Flame> flames;
  final List<_Spark> sparks;
  final Color color;
  final Color colorLight;
  final double maxHeight;

  _BarFirePainter({required this.flames, required this.sparks, required this.color, required this.colorLight, required this.maxHeight});

  @override
  void paint(Canvas canvas, Size size) {
    final barTop = maxHeight; // y where the input bar starts
    final activeFlames = flames.where((f) => f.opacity > 0.02).toList();
    if (activeFlames.isEmpty) return;

    // Compute average opacity for the overall fire intensity
    final avgOpacity = activeFlames.fold<double>(0, (s, f) => s + f.opacity) / activeFlames.length;

    final barBottom = size.height;
    const borderRadius = 8.0; // match the input bar's border radius

    // Place flames along the perimeter: top edge + curving around corners + down sides.
    // Map each flame's x (0..1) onto this perimeter path.
    // 0.0 = bottom of left side, wraps up left side, across top, down right side to 1.0
    for (final f in activeFlames) {
      final flicker = sin(f.phase) * 0.2 + 0.8;

      // Map x position to perimeter coordinates + outward normal direction
      final pos = _perimeterPoint(f.x, size, barTop, barBottom, borderRadius);
      final cx = pos.x;
      final cy = pos.y;
      final nx = pos.nx;
      final ny = pos.ny;

      // Skip anything not on the top edge
      if (ny > -0.7) continue;

      // Edge taper: flames near corners grow/shrink smoothly
      // cx ranges from ~8 (left corner) to ~width-8 (right corner)
      final distFromLeft = cx;
      final distFromRight = size.width - cx;
      final edgeDist = min(distFromLeft, distFromRight);
      final taper = (edgeDist / 40.0).clamp(0.0, 1.0); // 0 at edge, 1 after 40px

      final h = f.baseHeight * flicker * maxHeight * taper;
      final sway = sin(f.phase * 0.6 + f.x * 6) * 2.5;
      if (h < 1.5) continue;

      final tipX = cx + sway;
      final tipY = barTop - h;
      final halfW = 8.0 + h * 0.5;

      // Build flame with noisy jagged edges instead of smooth hills
      final path = Path();
      path.moveTo(cx - halfW, barTop);

      // Left edge going up: 4 segments with noise
      const segs = 4;
      for (int s = 1; s <= segs; s++) {
        final t = s / (segs + 1);
        final lx = cx - halfW + (tipX - (cx - halfW)) * t;
        final ly = barTop - h * _flameNoise(t, f.phase + f.x * 5 + s * 1.7);
        final nx = sin(f.phase * 2.3 + s * 3.1 + f.x * 7) * halfW * 0.15; // jagged offset
        path.lineTo(lx + nx, ly);
      }
      // Tip
      path.lineTo(tipX, tipY);
      // Right edge going down: 4 segments with noise
      for (int s = segs; s >= 1; s--) {
        final t = s / (segs + 1);
        final rx = tipX + ((cx + halfW) - tipX) * (1 - t);
        final ry = barTop - h * _flameNoise(t, f.phase + f.x * 5 + s * 2.3 + 10);
        final nx = sin(f.phase * 1.9 + s * 2.7 + f.x * 9) * halfW * 0.15;
        path.lineTo(rx + nx, ry);
      }
      path.lineTo(cx + halfW, barTop);
      path.close();

      final gradStart = Offset(cx, barTop);
      final gradEnd = Offset(tipX, tipY);
      canvas.drawPath(path, Paint()
        ..shader = ui.Gradient.linear(gradStart, gradEnd, [
          colorLight.withValues(alpha: f.opacity * 0.85 * taper),
          color.withValues(alpha: f.opacity * 0.5 * taper),
          color.withValues(alpha: f.opacity * 0.1),
          Colors.transparent,
        ], [0.0, 0.25, 0.6, 1.0]));
    }

    // ── SPARKS: small glowing particles flying off the flames ──
    for (final s in sparks) {
      final lifeRatio = 1.0 - (s.age / s.life); // 1 at birth, 0 at death
      final opacity = lifeRatio * 0.9;
      final sz = s.size * lifeRatio;
      if (opacity < 0.02 || sz < 0.5) continue;

      final sx = s.x * size.width;
      final sy = barTop + s.y; // y is negative (going up)

      canvas.drawCircle(
        Offset(sx, sy),
        sz,
        Paint()
          ..color = colorLight.withValues(alpha: opacity)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, sz * 0.6),
      );
      // Hot white core
      canvas.drawCircle(
        Offset(sx, sy),
        sz * 0.4,
        Paint()..color = Colors.white.withValues(alpha: opacity * 0.6),
      );
    }
  }

  /// Map a normalized position (0..1) to a point on the element's perimeter + outward normal.
  /// The perimeter goes: left side (bottom to top) → top-left corner → top edge → top-right corner → right side (top to bottom)
  _PerimPoint _perimeterPoint(double t, Size size, double barTop, double barBottom, double r) {
    final sideH = barBottom - barTop - r; // side length excluding corner
    final topW = size.width - 2 * r; // top length excluding corners
    final cornerArc = r * pi / 2; // quarter circle arc length
    final totalPerim = sideH + cornerArc + topW + cornerArc + sideH;

    var d = t * totalPerim;

    // Left side going up
    if (d < sideH) {
      final y = barBottom - d;
      return _PerimPoint(0, y, -1, 0); // normal points left
    }
    d -= sideH;

    // Top-left corner arc
    if (d < cornerArc) {
      final angle = pi + (d / cornerArc) * (pi / 2); // pi to 3pi/2
      final cx = r;
      final cy = barTop + r;
      return _PerimPoint(
        cx + r * cos(angle), cy + r * sin(angle),
        cos(angle), sin(angle),
      );
    }
    d -= cornerArc;

    // Top edge going right
    if (d < topW) {
      final x = r + d;
      return _PerimPoint(x, barTop, 0, -1); // normal points up
    }
    d -= topW;

    // Top-right corner arc
    if (d < cornerArc) {
      final angle = (3 * pi / 2) + (d / cornerArc) * (pi / 2); // 3pi/2 to 2pi
      final cx = size.width - r;
      final cy = barTop + r;
      return _PerimPoint(
        cx + r * cos(angle), cy + r * sin(angle),
        cos(angle), sin(angle),
      );
    }
    d -= cornerArc;

    // Right side going down
    final y = barTop + r + d.clamp(0, sideH);
    return _PerimPoint(size.width, y, 1, 0); // normal points right
  }

  /// Flame edge height noise — creates jagged fire contour instead of smooth hills
  /// Returns 0..1 height multiplier at position t along the edge
  static double _flameNoise(double t, double seed) {
    // Mix of sine waves at different frequencies for organic noise
    final n = sin(seed + t * 12) * 0.3 +
              sin(seed * 1.7 + t * 7) * 0.4 +
              sin(seed * 0.5 + t * 20) * 0.15;
    return (t * 2 * (1 - t) * 2 + n * 0.3).clamp(0.0, 1.0); // parabolic base + noise
  }

  @override
  bool shouldRepaint(_BarFirePainter old) => true;
}

class _PerimPoint {
  final double x, y, nx, ny;
  _PerimPoint(this.x, this.y, this.nx, this.ny);
}

class _Spark {
  double x, y; // x in 0..1 normalized, y in pixels relative to bar top (negative = above)
  double vx, vy; // velocity: vx in pixels/sec mapped to 0..1, vy in pixels/sec
  double life, age, size;
  _Spark({
    required this.x, required this.y, required this.vx, required this.vy,
    required this.life, required this.age, required this.size,
  });
}

// ═══════════════════════════════════════════════════════════
// BarElectric — Lightning arcs wrapping the input bar perimeter
// Two layers: steady "power supply" hum + sporadic discharge arcs
// ═══════════════════════════════════════════════════════════

class BarElectric extends StatefulWidget {
  final Widget child;
  final bool lit;
  final Color color;
  final Color? colorLight;
  final double fuel;

  const BarElectric({
    super.key, required this.child, required this.lit,
    required this.color, this.colorLight, this.fuel = 0.0,
  });

  @override
  State<BarElectric> createState() => _BarElectricState();
}

class _BarElectricState extends State<BarElectric> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  final _rng = Random();

  // Hum — jagged energy ring wrapping the perimeter
  List<double> _humJitter = List.filled(200, 0);
  double _humIntensity = 0;

  // Circuit arcs — two points pathfind to each other along the perimeter
  final List<_CircuitArc> _circuits = [];
  // Shower sparks — small glowing particles that spray outward with gravity
  final List<_SparkParticle> _particles = [];
  double _glow = 0;
  bool _wasLit = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..repeat()..addListener(_tick);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_tick);
    _ctrl.stop();
    _ctrl.dispose();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    try { setState(() {
      final dt = 0.016;

      // Detect focus gain → init circuit + spark shower
      if (widget.lit && !_wasLit) _onPowerOn();
      _wasLit = widget.lit;

      if (widget.lit) {
        final targetGlow = 0.15 + widget.fuel * 0.3;
        _glow += (targetGlow - _glow) * 0.06;
        _humIntensity += (1.0 - _humIntensity) * 0.04;

        // Hum jitter
        for (int i = 0; i < _humJitter.length; i++) {
          _humJitter[i] += (_rng.nextDouble() - 0.5) * (2.0 + widget.fuel * 4.0);
          _humJitter[i] *= 0.75;
        }

        // Spawn circuit arcs — two random perimeter points connected by jagged bolt
        final circuitRate = widget.fuel > 0.05 ? 0.08 + widget.fuel * 0.25 : 0.015;
        if (_rng.nextDouble() < circuitRate) _spawnCircuit();

        // Spawn spark particles from random perimeter points
        final sparkRate = (2 + widget.fuel * 12).round();
        for (int i = 0; i < sparkRate; i++) {
          if (_rng.nextDouble() < 0.3 + widget.fuel * 0.5) _spawnParticle();
        }
      } else {
        // Lightbulb fade
        _glow *= 0.96;
        _humIntensity *= 0.97;
        for (int i = 0; i < _humJitter.length; i++) _humJitter[i] *= 0.92;
      }

      // Age circuits
      for (final c in _circuits) c.age += dt;
      _circuits.removeWhere((c) => c.age > c.life);

      // Age particles — strong gravity, minimal drag (welding sparks)
      for (final p in _particles) {
        p.age += dt;
        p.x += p.vx * dt;
        p.y += p.vy * dt;
        p.vy += 200 * dt; // heavy gravity — sparks arc down fast
        p.vx *= 0.995; // minimal air drag — they fly far
        p.vy *= 0.995;
      }
      _particles.removeWhere((p) => p.age > p.life);
    }); } catch (_) {}
  }

  void _onPowerOn() {
    _glow = 0.35;
    _humIntensity = 0.2;
    // Welding spark shower from corners
    for (int i = 0; i < 40 + _rng.nextInt(30); i++) {
      _spawnParticle(burst: true);
    }
    // Initial circuit connections
    for (int i = 0; i < 2 + _rng.nextInt(2); i++) {
      _spawnCircuit();
    }
  }

  /// Two random points on the perimeter connected by a jagged bolt
  void _spawnCircuit() {
    final startT = _rng.nextDouble() * 4.0;
    // End point is 0.3..1.5 perimeter distance away
    final endT = (startT + 0.3 + _rng.nextDouble() * 1.2) % 4.0;
    final segs = 5 + _rng.nextInt(6) + (widget.fuel * 4).round();

    final positions = <double>[];
    final jitter = <double>[];
    for (int i = 0; i <= segs; i++) {
      final t = startT + (endT - startT + (endT < startT ? 4 : 0)) * (i / segs);
      positions.add(t % 4.0);
      // Jitter perpendicular to the path — more in the middle, less at endpoints
      final midFactor = sin(i / segs * pi); // 0 at ends, 1 in middle
      jitter.add((_rng.nextDouble() - 0.5) * midFactor * (4 + widget.fuel * 8));
    }

    _circuits.add(_CircuitArc(
      positions: positions, jitter: jitter,
      life: 0.08 + _rng.nextDouble() * 0.15,
      age: 0,
      width: 0.8 + _rng.nextDouble() * (1.5 + widget.fuel * 1.5),
      brightness: 0.6 + _rng.nextDouble() * 0.4,
    ));
  }

  /// Spawn a welding-style spark — shoots outward from the perimeter normal.
  /// Computes the actual outward normal by sampling two nearby perimeter points.
  void _spawnParticle({bool burst = false}) {
    final perimT = _rng.nextDouble() * 4.0;

    // Store normal direction — will be resolved in the painter using _perimToXY.
    // We store nx/ny on the particle so the painter can compute velocity in screen space.
    _particles.add(_SparkParticle(
      perimT: perimT,
      x: 0, y: 0,
      // vx/vy will be set to screen-space velocity by the painter on first frame.
      // For now, store speed + spread as raw values.
      vx: burst ? 150 + _rng.nextDouble() * 250 : 80 + _rng.nextDouble() * 150 + widget.fuel * 100, // speed
      vy: (_rng.nextDouble() - 0.5) * 1.4, // spread angle
      life: 0.1 + _rng.nextDouble() * (burst ? 0.3 : 0.2),
      age: 0,
      size: 0.4 + _rng.nextDouble() * 0.6,
      brightness: 0.7 + _rng.nextDouble() * 0.3,
      needsInit: true,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isActive = _glow > 0.005 || _circuits.isNotEmpty || _particles.isNotEmpty;
    return Stack(clipBehavior: Clip.none, children: [
      widget.child,
      if (isActive)
        Positioned(left: -30, right: -30, top: -30, bottom: -30,
          child: IgnorePointer(child: CustomPaint(
            painter: _ElectricPainter(
              color: widget.color,
              colorLight: widget.colorLight ?? Color.lerp(widget.color, Colors.white, 0.6)!,
              glow: _glow,
              humJitter: _humJitter,
              humIntensity: _humIntensity,
              circuits: _circuits,
              particles: _particles,
              fuel: widget.fuel,
              radius: 22,
              overflow: 30,
            ),
          ))),
    ]);
  }
}

class _CircuitArc {
  final List<double> positions; // perimeter positions 0..4
  final List<double> jitter; // perpendicular offset
  final double life, width, brightness;
  double age;
  _CircuitArc({required this.positions, required this.jitter, required this.life,
    required this.age, required this.width, required this.brightness});
}

class _SparkParticle {
  final double perimT;
  double x, y;
  double vx, vy;
  final double life, size, brightness;
  double age;
  bool needsInit;
  _SparkParticle({required this.perimT, required this.x, required this.y,
    required this.vx, required this.vy, required this.life,
    required this.age, required this.size, required this.brightness,
    this.needsInit = false});
}

class _ElectricPainter extends CustomPainter {
  final Color color, colorLight;
  final double glow, fuel, radius, overflow, humIntensity;
  final List<double> humJitter;
  final List<_CircuitArc> circuits;
  final List<_SparkParticle> particles;

  _ElectricPainter({required this.color, required this.colorLight, required this.glow,
    required this.humJitter, required this.humIntensity, required this.circuits,
    required this.particles, required this.fuel, required this.radius, required this.overflow});

  /// Convert perimeter position (0..1 normalized around full perimeter) to canvas XY.
  /// Properly follows the rounded rectangle path including corner arcs.
  Offset _perimToXY(double t, double perpJitter, Size size) {
    final r = radius;
    final w = size.width, h = size.height;
    t = t % 4.0;
    if (t < 0) t += 4.0;

    // Perimeter segments: each edge has a straight part + a corner arc.
    // Layout (clockwise from top-left corner):
    //   0.0       → corner TL arc
    //   ...       → top straight edge
    //   ~1.0      → corner TR arc
    //   ...       → right straight edge
    //   ~2.0      → corner BR arc
    //   ...       → bottom straight edge
    //   ~3.0      → corner BL arc
    //   ...       → left straight edge
    //   4.0       → back to start

    // Total perimeter length for proportional mapping
    final cornerArc = r * pi / 2; // quarter circle arc length
    final topLen = w - 2 * r;
    final rightLen = h - 2 * r;
    final bottomLen = w - 2 * r;
    final leftLen = h - 2 * r;
    final totalPerim = topLen + rightLen + bottomLen + leftLen + 4 * cornerArc;

    // Map t (0..4) to distance along perimeter
    double dist = (t / 4.0) * totalPerim;

    double x, y, nx, ny;

    // Segment boundaries
    final seg0 = cornerArc;             // TL corner done
    final seg1 = seg0 + topLen;         // top edge done
    final seg2 = seg1 + cornerArc;      // TR corner done
    final seg3 = seg2 + rightLen;       // right edge done
    final seg4 = seg3 + cornerArc;      // BR corner done
    final seg5 = seg4 + bottomLen;      // bottom edge done
    final seg6 = seg5 + cornerArc;      // BL corner done
    // seg6..totalPerim = left edge

    if (dist < seg0) {
      // TL corner arc
      final angle = pi + (dist / cornerArc) * (pi / 2); // pi to 3pi/2
      x = r + r * cos(angle);
      y = r + r * sin(angle);
      nx = cos(angle); ny = sin(angle);
    } else if (dist < seg1) {
      // Top straight edge
      final s = (dist - seg0) / topLen;
      x = r + s * topLen; y = 0; nx = 0; ny = -1;
    } else if (dist < seg2) {
      // TR corner arc
      final angle = -pi / 2 + ((dist - seg1) / cornerArc) * (pi / 2); // -pi/2 to 0
      x = w - r + r * cos(angle);
      y = r + r * sin(angle);
      nx = cos(angle); ny = sin(angle);
    } else if (dist < seg3) {
      // Right straight edge
      final s = (dist - seg2) / rightLen;
      x = w; y = r + s * rightLen; nx = 1; ny = 0;
    } else if (dist < seg4) {
      // BR corner arc
      final angle = 0 + ((dist - seg3) / cornerArc) * (pi / 2); // 0 to pi/2
      x = w - r + r * cos(angle);
      y = h - r + r * sin(angle);
      nx = cos(angle); ny = sin(angle);
    } else if (dist < seg5) {
      // Bottom straight edge
      final s = (dist - seg4) / bottomLen;
      x = w - r - s * bottomLen; y = h; nx = 0; ny = 1;
    } else if (dist < seg6) {
      // BL corner arc
      final angle = pi / 2 + ((dist - seg5) / cornerArc) * (pi / 2); // pi/2 to pi
      x = r + r * cos(angle);
      y = h - r + r * sin(angle);
      nx = cos(angle); ny = sin(angle);
    } else {
      // Left straight edge
      final s = (dist - seg6) / leftLen;
      x = 0; y = h - r - s * leftLen; nx = -1; ny = 0;
    }

    return Offset(x + nx * perpJitter, y + ny * perpJitter);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final barSize = Size(size.width - overflow * 2, size.height - overflow * 2);
    canvas.save();
    canvas.translate(overflow, overflow);

    final hi = humIntensity;

    // Layer 1: Ambient glow
    if (glow > 0.01) {
      final glowRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, barSize.width, barSize.height), Radius.circular(radius));
      canvas.drawRRect(glowRect, Paint()
        ..color = color.withValues(alpha: glow * hi * 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4 + fuel * 6
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 8 + fuel * 6));
    }

    // Layer 2: Energy hum ring
    if (hi > 0.01) {
      final n = humJitter.length;
      final humPath = Path();
      for (int i = 0; i <= n; i++) {
        final t = (i / n) * 4.0;
        final ji = humJitter[i % n] * (1.5 + fuel * 3.0);
        final pt = _perimToXY(t, ji, barSize);
        if (i == 0) { humPath.moveTo(pt.dx, pt.dy); } else { humPath.lineTo(pt.dx, pt.dy); }
      }
      humPath.close();

      canvas.drawPath(humPath, Paint()
        ..color = color.withValues(alpha: ((0.3 + fuel * 0.3) * hi).clamp(0.0, 0.7))
        ..strokeWidth = 4 + fuel * 4..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
      canvas.drawPath(humPath, Paint()
        ..color = colorLight.withValues(alpha: ((0.4 + fuel * 0.3) * hi).clamp(0.0, 0.8))
        ..strokeWidth = 2 + fuel * 2..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
      canvas.drawPath(humPath, Paint()
        ..color = colorLight.withValues(alpha: ((0.6 + fuel * 0.3) * hi).clamp(0.0, 1.0))
        ..strokeWidth = 1.0 + fuel * 1.0..style = PaintingStyle.stroke);
    }

    // Layer 3: Circuit arcs — two points pathfinding to each other
    for (final arc in circuits) {
      final alpha = ((1.0 - arc.age / arc.life) * arc.brightness).clamp(0.0, 1.0);
      if (alpha < 0.01 || arc.positions.length < 2) continue;

      final path = Path();
      for (int i = 0; i < arc.positions.length; i++) {
        final pt = _perimToXY(arc.positions[i], arc.jitter[i], barSize);
        if (i == 0) { path.moveTo(pt.dx, pt.dy); } else { path.lineTo(pt.dx, pt.dy); }
      }

      canvas.drawPath(path, Paint()
        ..color = color.withValues(alpha: alpha * 0.4)
        ..strokeWidth = arc.width * 5..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
      canvas.drawPath(path, Paint()
        ..color = colorLight.withValues(alpha: alpha)
        ..strokeWidth = arc.width * 1.5..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke);
    }

    // Layer 4: Welding sparks — init velocities from perimeter normals, then draw
    for (final p in particles) {
      if (p.needsInit) {
        // Compute outward normal by sampling two nearby points
        final p1 = _perimToXY(p.perimT - 0.01, 0, barSize);
        final p2 = _perimToXY(p.perimT + 0.01, 0, barSize);
        // Tangent direction
        var tx = p2.dx - p1.dx;
        var ty = p2.dy - p1.dy;
        final tLen = sqrt(tx * tx + ty * ty);
        if (tLen > 0) { tx /= tLen; ty /= tLen; }
        // Normal = perpendicular to tangent, pointing outward
        // For clockwise perimeter: outward normal is (-ty, tx)
        final nx = -ty;
        final ny = tx;
        final speed = p.vx; // stored speed
        final spread = p.vy; // stored spread angle
        p.vx = nx * speed + tx * spread * speed * 0.4;
        p.vy = ny * speed - tx * spread * speed * 0.4;
        p.needsInit = false;
      }
      final alpha = ((1.0 - p.age / p.life) * p.brightness).clamp(0.0, 1.0);
      if (alpha < 0.01) continue;

      final origin = _perimToXY(p.perimT, 0, barSize);
      final px = origin.dx + p.x;
      final py = origin.dy + p.y;

      final speed = sqrt(p.vx * p.vx + p.vy * p.vy);
      if (speed < 1) continue;
      // Long streak trailing behind the spark
      final trailLen = (speed * 0.03).clamp(2.0, 18.0);
      final dx = p.vx / speed;
      final dy = p.vy / speed;
      final tailX = px - dx * trailLen;
      final tailY = py - dy * trailLen;

      // Glow trail
      canvas.drawLine(Offset(tailX, tailY), Offset(px, py), Paint()
        ..color = color.withValues(alpha: alpha * 0.4)
        ..strokeWidth = p.size * 3
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
      // Bright core streak
      canvas.drawLine(Offset(tailX, tailY), Offset(px, py), Paint()
        ..color = colorLight.withValues(alpha: alpha)
        ..strokeWidth = p.size
        ..strokeCap = StrokeCap.round);
      // Hot white head
      canvas.drawCircle(Offset(px, py), p.size * 0.5, Paint()
        ..color = Colors.white.withValues(alpha: alpha * 0.8));
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_ElectricPainter old) => true;
}
