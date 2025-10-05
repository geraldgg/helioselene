import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/transit.dart';

/// Information about a transit chord across the target body.
class ChordInfo {
  final bool isTransit;
  final double chordArcmin;
  final double offsetArcmin; // separation from center
  final GlobalKey repaintKey;
  ChordInfo({
    required this.isTransit,
    required this.chordArcmin,
    required this.offsetArcmin,
    GlobalKey? repaintKey,
  }) : repaintKey = repaintKey ?? GlobalKey();

  factory ChordInfo.fromTransit(Transit t, {GlobalKey? repaintKey}) {
    final r = t.targetRadiusArcmin;
    final d = t.minSeparationArcmin;
    if (r <= 0) {
      return ChordInfo(isTransit: false, chordArcmin: 0, offsetArcmin: 0, repaintKey: repaintKey);
    }
    if (d <= r) {
      final chord = 2 * math.sqrt(r * r - d * d);
      return ChordInfo(isTransit: true, chordArcmin: chord, offsetArcmin: d, repaintKey: repaintKey);
    } else {
      return ChordInfo(isTransit: false, chordArcmin: 0, offsetArcmin: d, repaintKey: repaintKey);
    }
  }
}

/// Painter for a transit depiction. Optionally draws a legend and direction arrow.
class TransitPainter extends CustomPainter {
  final Transit transit;
  final ChordInfo chord;
  final bool showLegend;
  final bool mini;
  final bool showDirectionArrow;
  final bool arrowRightward; // if false, arrow points left

  TransitPainter({
    required this.transit,
    required this.chord,
    this.showLegend = true,
    this.mini = false,
    this.showDirectionArrow = true,
    this.arrowRightward = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = mini ? 1 : 2
      ..color = Colors.amber;
    final bodyPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(colors: transit.body == 'Sun'
          ? [Colors.orangeAccent, Colors.deepOrange]
          : [Colors.grey.shade300, Colors.grey.shade600]).createShader(Rect.fromCircle(center: center, radius: size.width * 0.4));

    final rPx = size.width * 0.4; // body radius in pixels
    canvas.drawCircle(center, rPx, bodyPaint);
    canvas.drawCircle(center, rPx, paint..color = Colors.white70..strokeWidth = mini ? 0.5 : 1);

    // Mark center (smaller in mini mode)
    canvas.drawCircle(center, mini ? 1.5 : 3, Paint()..color = Colors.white);

    // Draw satellite path approximation: horizontal line offset by separation ratio
    final rArc = transit.targetRadiusArcmin;
    double? lineStartX;
    double? lineEndX;
    double? lineY;
    if (rArc > 0) {
      final dArc = chord.offsetArcmin;
      final offsetFrac = (dArc / rArc).clamp(-1.0, 1.0);
      final y = center.dy - offsetFrac * rPx; // invert so positive offset plots upward consistently
      final pathPaint = Paint()
        ..color = chord.isTransit ? Colors.lightBlueAccent : Colors.orangeAccent
        ..strokeWidth = mini ? 1.5 : 3
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      if (chord.isTransit) {
        // chord segment within disk
        final halfChordFrac = chord.chordArcmin / (2 * rArc); // relative to diameter
        final halfChordPx = halfChordFrac * (2 * rPx);
        lineStartX = center.dx - halfChordPx;
        lineEndX = center.dx + halfChordPx;
        lineY = y;
        canvas.drawLine(Offset(lineStartX, y), Offset(lineEndX, y), pathPaint);
      } else {
        // near miss: draw approximate path near disk
        lineStartX = center.dx - rPx * 1.2;
        lineEndX = center.dx + rPx * 1.2;
        lineY = y;
        canvas.drawLine(Offset(lineStartX, y), Offset(lineEndX, y), pathPaint
          ..color = Colors.deepOrangeAccent
          ..strokeWidth = mini ? 1 : 2);
      }

      // Draw satellite marker at closest approach (center of chord)
      final satMarker = Paint()..color = Colors.cyanAccent;
      canvas.drawCircle(Offset(center.dx, y), mini ? 2.5 : 5, satMarker);
    }

    // Draw arrow if enabled and we have a path
    if (showDirectionArrow && lineStartX != null && lineEndX != null && lineY != null) {
      final arrowSize = mini ? 6.0 : 10.0;
      final arrowPaint = Paint()
        ..color = Colors.yellowAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = mini ? 1 : 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final headX = arrowRightward ? lineEndX : lineStartX;
      final baseDir = arrowRightward ? -1 : 1; // direction to go back along line
      final centerHead = Offset(headX, lineY);
      // Two lines forming a simple arrow head
      final p1 = centerHead + Offset(baseDir * arrowSize, -arrowSize * 0.55);
      final p2 = centerHead + Offset(baseDir * arrowSize, arrowSize * 0.55);
      canvas.drawLine(centerHead, p1, arrowPaint);
      canvas.drawLine(centerHead, p2, arrowPaint);
    }

    if (showLegend && !mini) {
      // Legend / text
      final textPainter = (String txt, double dy, {Color color = Colors.white, double sizePx = 12}) {
        final tp = TextPainter(
          text: TextSpan(style: TextStyle(color: color, fontSize: sizePx), text: txt),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        tp.paint(canvas, Offset(8, dy));
      };

      textPainter('${transit.body} ${transit.kind}', 8, sizePx: 14);
      textPainter('Sep: ${transit.minSeparationArcmin.toStringAsFixed(2)}\'  Rad: ${transit.targetRadiusArcmin.toStringAsFixed(2)}\'', 26);
      if (chord.isTransit) {
        textPainter('Chord: ${chord.chordArcmin.toStringAsFixed(2)}\'', 44);
      } else {
        textPainter('Near miss (outside disk)', 44, color: Colors.orangeAccent);
      }
      textPainter('Dur: ${transit.durationSeconds.toStringAsFixed(2)}s  Alt: ${transit.satAltitudeDeg.toStringAsFixed(1)}°', 62);
    }
  }

  @override
  bool shouldRepaint(covariant TransitPainter oldDelegate) =>
      oldDelegate.transit != transit ||
      oldDelegate.showLegend != showLegend ||
      oldDelegate.mini != mini ||
      oldDelegate.showDirectionArrow != showDirectionArrow ||
      oldDelegate.arrowRightward != arrowRightward;
}

/// Widget for a transit preview (mini) or full visualization.
class TransitVisual extends StatelessWidget {
  final Transit transit;
  final bool showLegend;
  final double? size; // if provided, enforces square size
  final bool mini;
  final ChordInfo? chordInfo; // allow reuse of precomputed chord
  final bool showDirectionArrow;
  final bool arrowRightward;
  const TransitVisual({
    super.key,
    required this.transit,
    this.showLegend = true,
    this.size,
    this.mini = false,
    this.chordInfo,
    this.showDirectionArrow = true,
    this.arrowRightward = true,
  });

  @override
  Widget build(BuildContext context) {
    final chord = chordInfo ?? ChordInfo.fromTransit(transit, repaintKey: GlobalKey());
    final painter = TransitPainter(
      transit: transit,
      chord: chord,
      showLegend: showLegend,
      mini: mini,
      showDirectionArrow: showDirectionArrow,
      arrowRightward: arrowRightward,
    );
    final content = RepaintBoundary(
      key: chord.repaintKey,
      child: AspectRatio(
        aspectRatio: 1,
        child: CustomPaint(painter: painter),
      ),
    );
    if (size != null) {
      return SizedBox(width: size, height: size, child: content);
    }
    return content;
  }
}
