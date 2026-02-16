import 'package:flutter/material.dart';

class FogOverlayPainter extends CustomPainter {
  final List<Offset> revealedScreenPoints;
  final List<double> revealRadii;

  FogOverlayPainter({
    required this.revealedScreenPoints,
    required this.revealRadii,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fogPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    Path holesPath = Path();
    for (int i = 0; i < revealedScreenPoints.length; i++) {
      holesPath.addOval(Rect.fromCircle(
        center: revealedScreenPoints[i],
        radius: revealRadii[i],
      ));
    }

    final resultPath = Path.combine(
      PathOperation.difference,
      fogPath,
      holesPath,
    );

    final paint = Paint()
      ..color = const Color(0xE6000000)
      ..style = PaintingStyle.fill;

    canvas.drawPath(resultPath, paint);
  }

  @override
  bool shouldRepaint(FogOverlayPainter oldDelegate) {
    return true;
  }
}
