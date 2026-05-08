import 'dart:math';
import 'package:flutter/material.dart';

class WaveformPainter extends CustomPainter {
  final List<double> samples;
  final double position;
  final Color activeColor;
  final Color inactiveColor;

  const WaveformPainter({
    required this.samples,
    required this.position,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;
    final barWidth = size.width / samples.length;
    final playedPaint = Paint()..color = activeColor;
    final remainingPaint = Paint()..color = inactiveColor;
    final posX = position * size.width;

    for (int i = 0; i < samples.length; i++) {
      final x = i * barWidth;
      final barHeight = max(2.0, samples[i] * size.height);
      final top = (size.height - barHeight) / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x + 0.5, top, max(1.0, barWidth - 1.0), barHeight),
        const Radius.circular(1),
      );
      canvas.drawRRect(rect, x <= posX ? playedPaint : remainingPaint);
    }

    final headPaint = Paint()
      ..color = activeColor
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(posX, 0), Offset(posX, size.height), headPaint);
  }

  @override
  bool shouldRepaint(WaveformPainter old) =>
      old.position != position || old.samples != samples;
}
