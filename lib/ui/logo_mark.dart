import 'package:flutter/material.dart';

/// The Tapnab logo drawn in code (same geometry as assets/branding/tapnab_logo.svg),
/// so the app needs no image assets.
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _LogoPainter()),
    );
  }
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 108;
    canvas.scale(s);

    final bg = RRect.fromRectAndRadius(
      const Rect.fromLTWH(0, 0, 108, 108),
      const Radius.circular(24),
    );
    canvas.drawRRect(
      bg,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF5A5F), Color(0xFF7B2FF7)],
        ).createShader(const Rect.fromLTWH(0, 0, 108, 108)),
    );

    final ripple = Paint()..color = Colors.white.withValues(alpha: 0.18);
    canvas.drawCircle(const Offset(54, 50), 26, ripple);
    canvas.drawCircle(const Offset(54, 50), 17, Paint()..color = Colors.white.withValues(alpha: 0.14));

    final white = Paint()..color = Colors.white;
    final arrow = Path()
      ..moveTo(48, 28)
      ..lineTo(60, 28)
      ..lineTo(60, 48)
      ..lineTo(70, 48)
      ..lineTo(54, 66)
      ..lineTo(38, 48)
      ..lineTo(48, 48)
      ..close();
    canvas.drawPath(arrow, white);

    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(32, 72, 44, 6), const Radius.circular(3)),
      white,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
