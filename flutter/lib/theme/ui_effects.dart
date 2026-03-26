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
        Positioned.fill(
          top: -widget.maxFlameHeight,
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
