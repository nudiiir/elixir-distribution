import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Small mint sparkline used inside stat cards.
class Sparkline extends StatelessWidget {
  const Sparkline({super.key, required this.values, this.height = 30});
  final List<double> values;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _SparklinePainter(values)),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.values);
  final List<double> values;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final min = values.reduce(math.min);
    final max = values.reduce(math.max);
    final range = (max - min) == 0 ? 1.0 : (max - min);
    final dx = size.width / (values.length - 1);

    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i * dx;
      final y = size.height - ((values[i] - min) / range) * (size.height - 4) - 2;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = T.mint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => old.values != values;
}

/// Donut chart with a hole; [slices] are (value, color).
class Donut extends StatelessWidget {
  const Donut({super.key, required this.slices, this.size = 150, this.center});
  final List<(double, Color)> slices;
  final double size;
  final Widget? center;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
              size: Size.square(size), painter: _DonutPainter(slices)),
          ?center,
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.slices);
  final List<(double, Color)> slices;

  @override
  void paint(Canvas canvas, Size size) {
    final total = slices.fold<double>(0, (s, e) => s + e.$1);
    if (total <= 0) {
      canvas.drawCircle(
          size.center(Offset.zero),
          size.width / 2 - 11,
          Paint()
            ..color = T.border2
            ..style = PaintingStyle.stroke
            ..strokeWidth = 22);
      return;
    }
    final rect = Rect.fromLTWH(11, 11, size.width - 22, size.height - 22);
    var start = -math.pi / 2;
    for (final (value, color) in slices) {
      if (value <= 0) continue;
      final sweep = (value / total) * 2 * math.pi;
      canvas.drawArc(
          rect,
          start,
          sweep - 0.03,
          false,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 22
            ..strokeCap = StrokeCap.butt);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.slices != slices;
}

/// Vertical bar chart with labels under each bar; last bar is highlighted.
class Bars extends StatelessWidget {
  const Bars({super.key, required this.data, this.height = 150});
  final List<(String, double)> data; // (label, value)
  final double height;

  @override
  Widget build(BuildContext context) {
    final max = data.isEmpty
        ? 1.0
        : data.map((e) => e.$2).reduce(math.max).clamp(1, double.infinity);
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < data.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Container(
                    height: data[i].$2 <= 0
                        ? 3
                        : ((height - 24) * (data[i].$2 / max))
                            .clamp(3, height - 24),
                    decoration: BoxDecoration(
                      color: i == data.length - 1
                          ? T.mint
                          : T.mint.withValues(alpha: 0.25),
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(4)),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(data[i].$1,
                      style: T.monoSmall.copyWith(fontSize: 9.5),
                      maxLines: 1,
                      overflow: TextOverflow.clip),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
