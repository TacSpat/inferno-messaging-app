import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Animated fire shield widget — port of Rails fire_shield_controller.js
/// Shows embers when standard (active), windblown ash when relaxed.
class FireShield extends StatefulWidget {
  final bool isActive;
  final VoidCallback onToggle;
  final double scale;

  const FireShield({
    super.key,
    required this.isActive,
    required this.onToggle,
    this.scale = 1.0,
  });

  @override
  State<FireShield> createState() => _FireShieldState();
}

class _FireShieldState extends State<FireShield> with TickerProviderStateMixin {
  late AnimationController _controller;
  late AnimationController _breathController;
  final _particles = <_Particle>[];
  final _stillAshes = <_StillAsh>[];
  double _spawnAccum = 0;
  int _frame = 0;
  double _flashAlpha = 0;
  double _flashDecay = 0;
  bool _wasActive = true;
  final _random = Random();

  // Canvas dimensions (logical)
  static const _cw = 300.0;
  static const _ch = 330.0;
  static const _shieldCx = _cw / 2;
  static const _shieldCy = _ch / 2 + 20;
  static const _flameCx = _shieldCx;
  static const _flameCy = _shieldCy - 25;

  @override
  void initState() {
    super.initState();
    _wasActive = widget.isActive;
    _initStillAshes();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..repeat();
    _controller.addListener(_tick);
    _breathController = AnimationController(vsync: this, duration: const Duration(seconds: 6))
      ..repeat();
  }

  @override
  void didUpdateWidget(covariant FireShield old) {
    super.didUpdateWidget(old);
    if (old.isActive != widget.isActive) {
      if (_wasActive && !widget.isActive) {
        _whoosh();
      } else if (!_wasActive && widget.isActive) {
        _combust();
      }
      _wasActive = widget.isActive;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _breathController.dispose();
    super.dispose();
  }

  void _tick() {
    _frame++;
    setState(() {});
  }

  // ── Hearth beat ──

  double _hearthBeat(int frame) {
    final slow = sin(frame * 0.007) * 0.5 + 0.5;
    final medium = sin(frame * 0.019 + 1.2) * 0.3 + 0.5;
    final fast = sin(frame * 0.05 + 2.7) * 0.1 + 0.5;
    return slow * 0.6 + medium * 0.28 + fast * 0.12;
  }

  // ── Alpha envelope ──

  double _alphaEnvelope(double t, double maxAlpha) {
    if (t < 0.15) {
      final n = t / 0.15;
      return maxAlpha * n * n;
    } else if (t < 0.55) {
      return maxAlpha;
    } else {
      final n = (t - 0.55) / 0.45;
      return maxAlpha * (1 - n * n);
    }
  }

  // ── Spawn embers ──
  // Logo center is roughly at canvas center (_cw/2, _ch/2)
  // Embers spawn around the logo edges and rise upward

  void _spawnEmber(double beat) {
    final t = _random.nextDouble();
    final intensity = 0.6 + beat * 0.4;
    // Spawn from a ring around the logo (radius ~40-55px from center)
    final angle = _random.nextDouble() * pi * 2;
    final dist = 35 + _random.nextDouble() * 20;
    final spawnX = _shieldCx + cos(angle) * dist;
    final spawnY = _shieldCy - 25 + sin(angle) * dist * 0.5; // shifted up 25px, compressed vertically
    _particles.add(_Particle(
      type: _ParticleType.ember,
      x: spawnX,
      y: spawnY,
      vx: (_random.nextDouble() - 0.5) * 0.5 + cos(angle) * 0.15,
      vy: -(0.3 + _random.nextDouble() * 0.7) * intensity,
      wobbleAmp: 0.1 + _random.nextDouble() * 0.3,
      wobbleFreq: 0.012 + _random.nextDouble() * 0.018,
      wobblePhase: _random.nextDouble() * pi * 2,
      lifespan: 80 + _random.nextDouble() * 120,
      size: (1.2 + _random.nextDouble() * 2.0) * intensity,
      r: 220 + t * 35,
      g: 80 + t * 130,
      b: 5 + _random.nextDouble() * 30,
      maxAlpha: (0.4 + _random.nextDouble() * 0.4) * intensity,
    ));
  }

  // ── Spawn ash ──

  void _spawnAsh() {
    final t = _random.nextDouble();
    final warm = _random.nextDouble() < 0.15;
    _particles.add(_Particle(
      type: _ParticleType.ash,
      x: -5 - _random.nextDouble() * 20,
      y: 30 + _random.nextDouble() * (_ch - 80),
      vx: 0.5 + _random.nextDouble() * 0.8,
      vy: -0.1 + (_random.nextDouble() - 0.5) * 0.3,
      tumble: _random.nextDouble() * pi * 2,
      tumbleSpeed: 0.02 + _random.nextDouble() * 0.04,
      flutterAmp: 0.3 + _random.nextDouble() * 0.6,
      flutterFreq: 0.015 + _random.nextDouble() * 0.025,
      flutterPhase: _random.nextDouble() * pi * 2,
      lifespan: 200 + _random.nextDouble() * 120,
      sizeW: 1 + _random.nextDouble() * 2.5,
      sizeH: 0.5 + _random.nextDouble() * 1,
      r: warm ? 140 + t * 40 : 130 + t * 50,
      g: warm ? 90 + t * 20 : 125 + t * 45,
      b: warm ? 70 + t * 15 : 120 + t * 45,
      maxAlpha: 0.15 + _random.nextDouble() * 0.2,
    ));
  }

  // ── Still ashes ──

  void _initStillAshes() {
    _stillAshes.clear();
    for (var i = 0; i < 12; i++) {
      final angle = _random.nextDouble() * pi * 2;
      final dist = 30 + _random.nextDouble() * 45;
      _stillAshes.add(_StillAsh(
        x: _shieldCx + cos(angle) * dist,
        y: _shieldCy + sin(angle) * dist + 10,
        size: 0.8 + _random.nextDouble() * 1.5,
        pulseSpeed: 0.008 + _random.nextDouble() * 0.015,
        pulsePhase: _random.nextDouble() * pi * 2,
        baseAlpha: 0.08 + _random.nextDouble() * 0.15,
        warm: _random.nextDouble() < 0.4,
      ));
    }
  }

  // ── Transitions ──

  void _whoosh() {
    for (final p in _particles) {
      if (p.type == _ParticleType.ember) {
        p.vx += 2.5 + _random.nextDouble() * 2;
        p.vy -= 0.5 + _random.nextDouble() * 1;
        p.lifespan = p.age + 20 + _random.nextDouble() * 25;
      }
    }
    for (var i = 0; i < 8; i++) {
      final t = _random.nextDouble();
      _particles.add(_Particle(
        type: _ParticleType.ember,
        x: _flameCx + (_random.nextDouble() - 0.5) * 16,
        y: _flameCy + (_random.nextDouble() - 0.5) * 12,
        vx: 1.5 + _random.nextDouble() * 2.5,
        vy: -(0.3 + _random.nextDouble() * 0.8),
        wobbleAmp: 0.1, wobbleFreq: 0.02,
        wobblePhase: _random.nextDouble() * pi * 2,
        lifespan: 30 + _random.nextDouble() * 30,
        size: 0.8 + _random.nextDouble() * 1.2,
        r: 160 + t * 40, g: 100 + t * 40, b: 60 + t * 30,
        maxAlpha: 0.2 + _random.nextDouble() * 0.2,
      ));
    }
  }

  void _combust() {
    _flashAlpha = 0.6;
    _flashDecay = 0.03;
    for (var i = 0; i < 50; i++) {
      final angle = _random.nextDouble() * pi * 2;
      final speed = 0.8 + _random.nextDouble() * 2.5;
      final t = _random.nextDouble();
      _particles.add(_Particle(
        type: _ParticleType.ember,
        x: _flameCx,
        y: _flameCy,
        vx: cos(angle) * speed,
        vy: sin(angle) * speed - 1,
        wobbleAmp: 0.1 + _random.nextDouble() * 0.2,
        wobbleFreq: 0.02 + _random.nextDouble() * 0.02,
        wobblePhase: _random.nextDouble() * pi * 2,
        lifespan: 50 + _random.nextDouble() * 70,
        size: 1.2 + _random.nextDouble() * 2.2,
        r: 240 + t * 15, g: 140 + t * 80, b: 10 + _random.nextDouble() * 40,
        maxAlpha: 0.5 + _random.nextDouble() * 0.5,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isStandard = widget.isActive;
    final beat = _hearthBeat(_frame);

    // Spawn particles
    final rate = isStandard ? 0.35 + beat * 0.5 : 0.18;
    _spawnAccum += rate;
    while (_spawnAccum >= 1) {
      if (isStandard) {
        _spawnEmber(beat);
      } else {
        _spawnAsh();
      }
      _spawnAccum -= 1;
    }

    // Update particles
    _particles.removeWhere((p) {
      p.age++;
      final t = p.age / p.lifespan;
      if (t >= 1) return true;

      if (p.type == _ParticleType.ember) {
        p.vy *= 0.997;
        p.x += p.vx + sin(p.age * p.wobbleFreq + p.wobblePhase) * p.wobbleAmp;
        p.y += p.vy;
      } else {
        p.tumble += p.tumbleSpeed;
        final flutter = sin(p.age * p.flutterFreq + p.flutterPhase) * p.flutterAmp;
        p.x += p.vx;
        p.y += p.vy + flutter * 0.15;
      }
      return false;
    });

    // Flash decay
    if (_flashAlpha > 0) {
      _flashAlpha -= _flashDecay;
      if (_flashAlpha < 0) _flashAlpha = 0;
    }

    return GestureDetector(
      onTap: widget.onToggle,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          width: _cw * widget.scale,
          height: _ch * widget.scale,
          child: CustomPaint(
            painter: _FireShieldPainter(
              particles: _particles,
              stillAshes: _stillAshes,
              isStandard: isStandard,
              beat: beat,
              frame: _frame,
              flashAlpha: _flashAlpha,
              alphaEnvelope: _alphaEnvelope,
              scale: widget.scale,
            ),
            child: _buildShieldOverlay(isStandard, beat),
          ),
        ),
      ),
    );
  }

  Widget _buildShieldOverlay(bool isStandard, double beat) {
    final shieldColor = isStandard
        ? const Color(0x22DC2626) // rgba(220,38,38,0.13)
        : const Color(0x4032302E); // rgba(50,48,46,0.25)
    final shieldStroke = isStandard
        ? const Color(0xFFF87171)
        : const Color(0xFF3A3836);
    return Center(
      child: SizedBox(
        width: 200 * widget.scale,
        height: 200 * widget.scale,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Shield outline
            CustomPaint(
              size: Size(200 * widget.scale, 200 * widget.scale),
              painter: _ShieldIconPainter(
                shieldFill: shieldColor,
                shieldStroke: shieldStroke,
              ),
            ),
            // Inferno logo inside shield — slow breathing pulse
            if (isStandard)
              _BreathingLogo(
                controller: _breathController,
                widgetScale: widget.scale,
              ),
          ],
        ),
      ),
    );
  }
}

// ── Data classes ──

enum _ParticleType { ember, ash }

class _Particle {
  _ParticleType type;
  double x, y, vx, vy;
  double wobbleAmp, wobbleFreq, wobblePhase;
  double tumble, tumbleSpeed;
  double flutterAmp, flutterFreq, flutterPhase;
  double age;
  double lifespan;
  double size, sizeW, sizeH;
  double r, g, b, maxAlpha;

  _Particle({
    required this.type,
    required this.x, required this.y,
    required this.vx, required this.vy,
    this.wobbleAmp = 0, this.wobbleFreq = 0, this.wobblePhase = 0,
    this.tumble = 0, this.tumbleSpeed = 0,
    this.flutterAmp = 0, this.flutterFreq = 0, this.flutterPhase = 0,
    required this.lifespan,
    this.size = 1, this.sizeW = 1, this.sizeH = 1,
    required this.r, required this.g, required this.b,
    required this.maxAlpha,
  }) : age = 0;
}

class _StillAsh {
  final double x, y, size, pulseSpeed, pulsePhase, baseAlpha;
  final bool warm;
  const _StillAsh({
    required this.x, required this.y, required this.size,
    required this.pulseSpeed, required this.pulsePhase,
    required this.baseAlpha, required this.warm,
  });
}

// ── Particle painter ──

class _FireShieldPainter extends CustomPainter {
  final List<_Particle> particles;
  final List<_StillAsh> stillAshes;
  final bool isStandard;
  final double beat;
  final int frame;
  final double flashAlpha;
  final double Function(double t, double maxAlpha) alphaEnvelope;
  final double scale;

  _FireShieldPainter({
    required this.particles, required this.stillAshes,
    required this.isStandard, required this.beat,
    required this.frame, required this.flashAlpha,
    required this.alphaEnvelope, required this.scale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scale, scale);

    // Flash
    if (flashAlpha > 0) {
      _drawFlash(canvas);
    }

    // Glow (standard mode)
    if (isStandard) {
      _drawGlow(canvas, beat);
    } else {
      _drawStillAshes(canvas, frame);
    }

    // Particles
    for (final p in particles) {
      final t = p.age / p.lifespan;
      if (t >= 1) continue;
      final alpha = alphaEnvelope(t, p.maxAlpha);

      if (p.type == _ParticleType.ember) {
        final sz = p.size * (t < 0.65 ? 1 : 1 - (t - 0.65) / 0.35 * 0.5);
        final color = Color.fromRGBO(p.r.toInt().clamp(0, 255), p.g.toInt().clamp(0, 255), p.b.toInt().clamp(0, 255), 1);

        // Glow
        final glowPaint = Paint()
          ..color = color.withValues(alpha: alpha * 0.08)
          ..blendMode = BlendMode.plus;
        canvas.drawCircle(Offset(p.x, p.y), sz * 2.8, glowPaint);

        // Core
        final corePaint = Paint()
          ..color = color.withValues(alpha: alpha)
          ..blendMode = BlendMode.plus;
        canvas.drawCircle(Offset(p.x, p.y), sz, corePaint);
      } else {
        // Ash
        final apparentW = p.sizeW * cos(p.tumble).abs();
        final color = Color.fromRGBO(p.r.toInt().clamp(0, 255), p.g.toInt().clamp(0, 255), p.b.toInt().clamp(0, 255), alpha);

        canvas.save();
        canvas.translate(p.x, p.y);
        canvas.rotate(p.tumble * 0.3);
        final ashPaint = Paint()..color = color;
        final rx = apparentW < 0.4 ? 0.4 : apparentW;
        canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: rx * 2, height: p.sizeH * 2), ashPaint);
        canvas.restore();
      }
    }

    canvas.restore();
  }

  void _drawFlash(Canvas canvas) {
    final gradient = ui.Gradient.radial(
      const Offset(_FireShieldState._flameCx, _FireShieldState._flameCy),
      90,
      [
        Color.fromRGBO(255, 200, 50, flashAlpha),
        Color.fromRGBO(249, 115, 22, flashAlpha * 0.5),
        Colors.transparent,
      ],
      [0, 0.4, 1],
    );
    final paint = Paint()
      ..shader = gradient
      ..blendMode = BlendMode.plus;
    canvas.drawCircle(const Offset(_FireShieldState._flameCx, _FireShieldState._flameCy), 90, paint);
  }

  void _drawGlow(Canvas canvas, double beat) {
    final glowRadius = 60 + beat * 50;
    final glowAlpha = 0.1 + beat * 0.18;

    final gradient = ui.Gradient.radial(
      const Offset(_FireShieldState._flameCx, _FireShieldState._flameCy),
      glowRadius,
      [
        Color.fromRGBO(249, 115, 22, glowAlpha),
        Color.fromRGBO(220, 38, 38, glowAlpha * 0.4),
        Colors.transparent,
      ],
      [0, 0.5, 1],
    );
    final paint = Paint()
      ..shader = gradient
      ..blendMode = BlendMode.plus;
    canvas.drawCircle(
      const Offset(_FireShieldState._flameCx, _FireShieldState._flameCy),
      glowRadius,
      paint,
    );
  }

  void _drawStillAshes(Canvas canvas, int frame) {
    for (final a in stillAshes) {
      final pulse = sin(frame * a.pulseSpeed + a.pulsePhase) * 0.5 + 0.5;
      final alpha = a.baseAlpha + pulse * 0.12;
      final r = a.warm ? (160 + pulse * 40).toInt() : 120;
      final g = a.warm ? (80 + pulse * 20).toInt() : 110;
      final b = a.warm ? 30 : 105;

      if (a.warm) {
        final warmPaint = Paint()
          ..color = Color.fromRGBO(r, g, b, alpha * 0.06)
          ..blendMode = BlendMode.plus;
        canvas.drawCircle(Offset(a.x, a.y), a.size * 3, warmPaint);
      }

      final ashPaint = Paint()..color = Color.fromRGBO(r, g, b, alpha);
      canvas.drawCircle(Offset(a.x, a.y), a.size, ashPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _FireShieldPainter old) => true;
}

// ── Shield outline painter ──

class _ShieldIconPainter extends CustomPainter {
  final Color shieldFill, shieldStroke;

  _ShieldIconPainter({
    required this.shieldFill,
    required this.shieldStroke,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Scale SVG from 24x24 viewBox to the widget size
    final sx = size.width / 24;
    final sy = size.height / 24;
    canvas.save();
    canvas.scale(sx, sy);

    // Shield outline: M12 2l8 4v5c0 5.25-3.5 10.74-8 12-4.5-1.26-8-6.75-8-12V6l8-4z
    final shieldPath = Path()
      ..moveTo(12, 2)
      ..lineTo(20, 6)
      ..lineTo(20, 11)
      ..cubicTo(20, 16.25, 16.5, 21.74, 12, 23)
      ..cubicTo(7.5, 21.74, 4, 16.25, 4, 11)
      ..lineTo(4, 6)
      ..lineTo(12, 2)
      ..close();

    canvas.drawPath(shieldPath, Paint()..color = shieldFill);
    canvas.drawPath(shieldPath, Paint()
      ..color = shieldStroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ShieldIconPainter old) =>
      old.shieldFill != shieldFill || old.shieldStroke != shieldStroke;
}

// ── Breathing logo — smooth single-frequency scale pulse ──

class _BreathingLogo extends AnimatedWidget {
  final double widgetScale;

  const _BreathingLogo({
    required AnimationController controller,
    required this.widgetScale,
  }) : super(listenable: controller);

  @override
  Widget build(BuildContext context) {
    final controller = listenable as AnimationController;
    final t = sin(controller.value * pi * 2) * 0.5 + 0.5; // 0..1 smooth
    final pulseScale = 0.95 + t * 0.10; // 0.95 → 1.05
    final opacity = 0.7 + t * 0.3; // 0.7 → 1.0

    return Opacity(
      opacity: opacity,
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(pulseScale, pulseScale, 1.0),
        transformHitTests: false,
        child: SizedBox(
          width: 105 * widgetScale,
          height: 105 * widgetScale,
          child: SvgPicture.asset(
            'assets/icons/inferno_mono.svg',
            colorFilter: const ColorFilter.mode(Color(0xFFF97316), BlendMode.srcIn),
          ),
        ),
      ),
    );
  }
}

