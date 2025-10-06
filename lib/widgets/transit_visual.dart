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
          ? [Colors.yellowAccent, Colors.yellow.shade700]
          : [Colors.grey.shade100, Colors.grey.shade400]).createShader(Rect.fromCircle(center: center, radius: size.width * 0.4));

    final rPx = size.width * 0.4; // body radius in pixels
    canvas.drawCircle(center, rPx, bodyPaint);
    canvas.drawCircle(center, rPx, paint..color = Colors.white70..strokeWidth = mini ? 0.5 : 1);

    // Mark center (smaller in mini mode)
    canvas.drawCircle(center, mini ? 1.5 : 3, Paint()..color = Colors.white);

    // ===== New motion-based path orientation logic =====
    final rArc = transit.targetRadiusArcmin;
    double? halfLenPx; // half-length actually drawn
    Offset? lineCenter; // closest approach point
    Offset? vDir; // unit vector along motion in canvas coords
    Offset? pStart; Offset? pEnd; // endpoints

    if (rArc > 0) {
      // Determine motion bearing.
      // Rust provides motion_direction_deg where: 0° = North (up), 90° = East (right), increasing clockwise.
      // Canvas coordinates: +x = right (East), +y = down (South). So bearing b maps to unit vector:
      //   v = (sin(b), -cos(b)). (Because for b=0 => (0,-1) up; b=90 => (1,0) right; b=180 => (0,1) down; b=270 => (-1,0) left.)
      double bearingDeg;
      if (transit.motionDirectionDeg.isFinite && transit.motionDirectionDeg.abs() > 1e-9) {
        bearingDeg = transit.motionDirectionDeg % 360.0;
        if (bearingDeg < 0) bearingDeg += 360.0;
      } else if ((transit.velocityAltDegPerS.abs() + transit.velocityAzDegPerS.abs()) > 1e-9) {
        // Reconstruct bearing consistent with Rust's definition: atan2(vel_az, vel_alt)
        bearingDeg = math.atan2(transit.velocityAzDegPerS, transit.velocityAltDegPerS) * 180.0 / math.pi;
        if (bearingDeg < 0) bearingDeg += 360.0;
      } else {
        // Fallback: arbitrary eastward motion
        bearingDeg = 90.0;
      }
      final bRad = bearingDeg * math.pi / 180.0;

      final v = Offset(math.sin(bRad), -math.cos(bRad));
      final vMag = v.distance;
      vDir = vMag > 0 ? (v / vMag) : const Offset(1,0);
      // Perpendicular (shift) vector (rotate vDir 90° CCW). Keep previous semantic: positive offsetArcmin moves upward visually.
      final nDir = Offset(-vDir.dy, vDir.dx); // unit length

      final offsetFrac = (chord.offsetArcmin / rArc).clamp(-1.0, 1.0);
      final offsetPx = offsetFrac * rPx;
      lineCenter = center + nDir * (-offsetPx);

      if (chord.isTransit) {
        halfLenPx = (chord.chordArcmin / rArc) * rPx * 0.5;
      } else {
        halfLenPx = rPx * 1.2; // near-miss line length
      }

      pStart = lineCenter - vDir * halfLenPx;
      pEnd   = lineCenter + vDir * halfLenPx;

      final pathPaint = Paint()
        ..color = chord.isTransit ? Colors.lightBlueAccent : Colors.orangeAccent
        ..strokeWidth = mini ? 1.5 : 3
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(pStart, pEnd, pathPaint);

      if (showDirectionArrow) {
        // Arrow now replaces the previous satellite dot at the closest approach (lineCenter)
        final arrowHead = lineCenter; // tip at closest approach
        final arrowSize = mini ? 6.0 : 10.0;
        const headAngle = math.pi / 6; // 30°
        Offset rot(Offset a, double ang) => Offset(
          a.dx * math.cos(ang) - a.dy * math.sin(ang),
          a.dx * math.sin(ang) + a.dy * math.cos(ang),
        );
        // Build two side vectors pointing backwards from head along -vDir then rotated ±headAngle
        final back = -vDir; // direction opposite motion
        final b1 = rot(back, headAngle);
        final b2 = rot(back, -headAngle);
        final arrowPaint = Paint()
          ..color = Colors.black54
          ..style = PaintingStyle.stroke
          ..strokeWidth = mini ? 1 : 1.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        canvas.drawLine(arrowHead, arrowHead + b1 * arrowSize, arrowPaint);
        canvas.drawLine(arrowHead, arrowHead + b2 * arrowSize, arrowPaint);
      }
    }

    // Legend removed per updated requirement (no text overlay inside body)
    // ===== End new motion logic =====
  }

  @override
  bool shouldRepaint(covariant TransitPainter oldDelegate) =>
      oldDelegate.transit != transit ||
      oldDelegate.showLegend != showLegend ||
      oldDelegate.mini != mini ||
      oldDelegate.showDirectionArrow != showDirectionArrow ||
      // arrowRightward retained for backward API compatibility but no longer affects orientation
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
